import Foundation
import WebKit

/// Fetches a file out of the portal using the session that is already signed in.
///
/// Shared by Léa and by MIO, because both make the same promise and break it
/// the same way. It was Léa's alone until MIO's attachments were wired up with
/// a `URLSession` and cookies — the exact mistake described below — and every
/// attachment in a message came back unopenable.
///
/// The obvious way to do this — copy the cookies into a `URLSession` and fetch
/// — does not work, and fails in the worst possible way. Léa hands back a
/// perfectly ordinary 200 response whose body is an HTML page titled "End of
/// session", which then gets written to disk under the teacher's filename. The
/// app saves `Class_1.pdf`, PDFKit opens it, finds no PDF, and shows a blank
/// page with no error anywhere. Every "the PDF viewer doesn't work" report
/// traces back to this; Word and PowerPoint failed the same way.
///
/// Sharing the cookie jar with a second web view is not enough either, which is
/// the part that is easy to get wrong twice. A Léa document link carries a
/// one-shot token minted by the page it was printed on, and Léa retires that
/// token as soon as the session asks for anything else — so a link scraped a
/// minute ago, or scraped before the app went on to read the grades page, comes
/// back as *Quitter*, the sign-out page. The download therefore runs on the
/// scraper's own web view, immediately after that view has re-loaded the page
/// the link lives on. Same session, same page, token still warm.
@MainActor
final class PortalDownloader: NSObject {
    private let webView: WKWebView
    private var jobs: [ObjectIdentifier: Job] = [:]

    /// How far along the download in flight is, 0…1, or nil when the server
    /// did not say how big the file is.
    ///
    /// Reported rather than left to a spinner: these are lecture slides, and
    /// several of them run past three megabytes on a phone connection. A
    /// turning circle says "something is happening"; a bar says how much longer.
    var onProgress: ((Double?) -> Void)?

    /// One download in flight: where it is being written, and who is waiting.
    private final class Job {
        var destination: URL
        var continuation: CheckedContinuation<URL, Error>?
        /// Held so KVO on the download's byte count stays alive.
        var observer: NSKeyValueObservation?

        init(destination: URL, continuation: CheckedContinuation<URL, Error>) {
            self.destination = destination
            self.continuation = continuation
        }

        func finish(_ result: Result<URL, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    /// - Parameter webView: the scraper's own view, already signed in and
    ///   sitting on the page the link came from.
    init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    /// Downloads `url`, saving it under `preferredName` when Léa offers no
    /// name of its own, and returns where it landed.
    ///
    /// - Parameter referer: the Léa page the link was found on. Sent because
    ///   some of Léa's document handlers refuse a request that did not come
    ///   from one of their own pages.
    func download(
        from url: URL,
        preferredName: String?,
        referer: URL?
    ) async throws -> URL {
        var request = URLRequest(url: url)
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lea", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        return try await withCheckedThrowingContinuation { continuation in
            webView.startDownload(using: request) { [weak self] download in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // The name is settled in the destination callback, where Léa's
                // own `Content-Disposition` is finally known; this is only the
                // fallback for when it does not send one.
                let fallback = folder.appendingPathComponent(
                    Self.safeName(preferredName ?? url.lastPathComponent)
                )
                let job = Job(destination: fallback, continuation: continuation)
                // `Progress.fractionCompleted` is 0 until the total is known,
                // so an unknown length is reported as nil rather than as a bar
                // sitting convincingly at zero.
                job.observer = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                    Task { @MainActor in
                        self?.onProgress?(progress.totalUnitCount > 0 ? progress.fractionCompleted : nil)
                    }
                }
                jobs[ObjectIdentifier(download)] = job
                onProgress?(0)
                download.delegate = self
            }
        }
    }

    /// Strips what a file name may not contain, and refuses to be empty.
    static func safeName(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "document" : cleaned
    }
}

// MARK: - WKDownloadDelegate

extension PortalDownloader: WKDownloadDelegate {
    nonisolated func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        Task { @MainActor in
            guard let job = jobs[ObjectIdentifier(download)] else {
                completionHandler(nil)
                return
            }

            // Léa's own name wins when it sent one, because it carries the
            // extension the file actually is — and that extension is what
            // decides whether this opens in the PDF reader or in Quick Look.
            let offered = Self.safeName(suggestedFilename)
            if !URL(fileURLWithPath: offered).pathExtension.isEmpty {
                job.destination = job.destination.deletingLastPathComponent()
                    .appendingPathComponent(offered)
            }

            // WebKit refuses to write over a file that is already there, and
            // the same handout gets opened more than once in a term.
            try? FileManager.default.removeItem(at: job.destination)
            completionHandler(job.destination)
        }
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in
            guard let job = jobs.removeValue(forKey: ObjectIdentifier(download)) else { return }
            onProgress?(1)
            job.finish(.success(job.destination))
        }
    }

    nonisolated func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        Task { @MainActor in
            guard let job = jobs.removeValue(forKey: ObjectIdentifier(download)) else { return }
            onProgress?(nil)
            job.finish(.failure(error))
        }
    }
}
