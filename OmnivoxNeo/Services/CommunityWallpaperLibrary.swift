import Combine
import Foundation
import SwiftUI

/// One photograph in the shared library.
struct CommunityWallpaper: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let file: String
    /// The photographer, read out of the file's own metadata when the library
    /// was built. `nil` when the file carried no name.
    let author: String?
    let width: Int?
    let height: Int?
    let bytes: Int?
    /// When it was added to the repository. Decides the order.
    let addedAt: Date?
    let thumbnail: String?

    /// Who to credit, in words.
    var credit: String {
        author ?? "Unknown photographer"
    }

    /// "19.2 MB", for telling somebody what they are about to download.
    var downloadSize: String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 9.0 / 16.0 }
        return CGFloat(width) / CGFloat(height)
    }
}

struct CommunityWallpaperManifest: Codable, Sendable {
    static let supportedSchema = 1

    let schemaVersion: Int
    let wallpapers: [CommunityWallpaper]
}

/// The shared wallpapers, fetched from the project's own repository.
///
/// The photographs live in the repo rather than on a server, for the same
/// reason the roadmap does: there is no server, and a folder of files on
/// GitHub is already a static host with a CDN in front of it. Adding a
/// wallpaper is committing a file.
///
/// The originals are enormous — fifteen to twenty megabytes, because that is
/// what a photograph off a phone actually is, and downscaling them to save
/// bandwidth would defeat the point of sharing them. So the grid shows
/// thumbnails, the full file is fetched only when somebody picks one, and once
/// fetched it is kept. Nobody should pay for the same twenty megabytes twice.
@MainActor
final class CommunityWallpaperLibrary: ObservableObject {
    static let shared = CommunityWallpaperLibrary()

    private static let base =
        "https://raw.githubusercontent.com/Thomas20090425/OmnivoxNeo/main/NeoWallpaper"

    static let manifestURL = URL(string: "\(base)/manifest.json")!

    /// Where to send somebody who wants to contribute a photograph.
    static let submissionAddress = "yuecheng.ma@dawsoncollege.qc.ca"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    @Published private(set) var wallpapers: [CommunityWallpaper] = []
    @Published private(set) var state: LoadState = .idle
    /// Which wallpaper is downloading, and how far along, so the grid can say.
    @Published private(set) var downloading: [String: Double] = [:]
    /// Which wallpapers are already on the device.
    @Published private(set) var downloaded: Set<String> = []

    private let session: URLSession

    private init() {
        // Its own session, carrying nothing. Same reasoning as the roadmap: a
        // public file from a public host, and no reason for anything of the
        // student's to be anywhere near the request.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        // Generous, because twenty megabytes on college wifi is not quick.
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
        refreshDownloadedSet()
    }

    // MARK: - The list

    func loadIfNeeded() {
        guard state == .idle || state == .failed else { return }
        Task { await load() }
    }

    func load() async {
        state = wallpapers.isEmpty ? .loading : state
        do {
            var request = URLRequest(url: Self.manifestURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                state = wallpapers.isEmpty ? .failed : .loaded
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(CommunityWallpaperManifest.self, from: data)
            guard manifest.schemaVersion <= CommunityWallpaperManifest.supportedSchema else {
                // A newer library than this build understands. Showing nothing
                // is better than showing it wrong.
                state = .failed
                return
            }
            wallpapers = manifest.wallpapers
            state = .loaded
            refreshDownloadedSet()
        } catch {
            state = wallpapers.isEmpty ? .failed : .loaded
        }
    }

    // MARK: - Addresses

    func thumbnailURL(for wallpaper: CommunityWallpaper) -> URL? {
        guard let thumbnail = wallpaper.thumbnail else { return nil }
        return URL(string: "\(Self.base)/\(thumbnail)")
    }

    func fullSizeURL(for wallpaper: CommunityWallpaper) -> URL? {
        URL(string: "\(Self.base)/\(wallpaper.file)")
    }

    // MARK: - Keeping what has been downloaded

    /// Where downloaded originals live.
    ///
    /// Shared across accounts rather than scoped to one, because a photograph
    /// from a public library is not the student's information — and making two
    /// people sharing a phone each download the same twenty megabytes would be
    /// privacy theatre at their expense. The chosen wallpaper itself is still
    /// stored per profile, by `Personalization`.
    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("CommunityWallpapers", isDirectory: true)
    }

    private func cachedURL(for wallpaper: CommunityWallpaper) -> URL {
        cacheDirectory.appendingPathComponent(wallpaper.file)
    }

    func isDownloaded(_ wallpaper: CommunityWallpaper) -> Bool {
        FileManager.default.fileExists(atPath: cachedURL(for: wallpaper).path)
    }

    private func refreshDownloadedSet() {
        downloaded = Set(wallpapers.filter(isDownloaded).map(\.id))
    }

    /// The full photograph: from the device if it is there, from the network
    /// if it is not, and saved on the way through.
    func imageData(for wallpaper: CommunityWallpaper) async -> Data? {
        let destination = cachedURL(for: wallpaper)
        if let data = try? Data(contentsOf: destination), !data.isEmpty {
            return data
        }
        guard let url = fullSizeURL(for: wallpaper) else { return nil }

        downloading[wallpaper.id] = 0
        defer { downloading[wallpaper.id] = nil }

        do {
            // A download task, not `data(from:)` and not `bytes(from:)`.
            // `bytes` yields one byte at a time, which for twenty megabytes is
            // twenty million appends and takes longer than the download; a
            // download task streams to a file and reports progress properly,
            // which is the whole reason to want it.
            let reporter = WallpaperDownloadProgress { [weak self] fraction in
                Task { @MainActor in self?.downloading[wallpaper.id] = fraction }
            }
            let (temporaryURL, response) = try await session.download(
                from: url, delegate: reporter
            )
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                try? FileManager.default.removeItem(at: temporaryURL)
                return nil
            }

            try? FileManager.default.createDirectory(
                at: cacheDirectory, withIntermediateDirectories: true
            )
            // The temporary file is deleted the moment this returns, so it is
            // moved rather than copied-then-read.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)

            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = cacheDirectory
            try? directory.setResourceValues(values)

            refreshDownloadedSet()
            return try? Data(contentsOf: destination)
        } catch {
            return nil
        }
    }

    // MARK: - Taking it back off the device

    /// How much space the downloaded originals take.
    var cacheSize: Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return contents.reduce(into: Int64(0)) { total, url in
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    var cacheSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
    }

    /// Forget one downloaded photograph.
    func removeDownload(_ wallpaper: CommunityWallpaper) {
        try? FileManager.default.removeItem(at: cachedURL(for: wallpaper))
        refreshDownloadedSet()
    }

    /// Forget all of them.
    func removeAllDownloads() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        refreshDownloadedSet()
    }
}

/// Reports how far a download has got.
///
/// A class rather than a closure because `URLSession` wants a delegate, and
/// `@unchecked Sendable` because its one stored property is a `let` closure
/// that is itself `Sendable` — there is no mutable state here to protect.
private final class WallpaperDownloadProgress: NSObject, URLSessionDownloadDelegate,
                                               @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// Required by the protocol. The `async` form of `download` hands back the
    /// file itself, so there is nothing to do here.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
