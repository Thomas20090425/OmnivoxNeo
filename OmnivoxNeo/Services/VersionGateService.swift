import Combine
import Foundation
import SwiftUI

/// Checks, before anything else runs, whether this build is still fit to use.
///
/// The shape of this is set by two rules that pull against each other. The
/// check has to happen *first* — a build with a critical fault should not get
/// as far as touching someone's account. But a student on a bad connection
/// outside a classroom must not be locked out of their own timetable by a file
/// they cannot reach. So the check is given five seconds at launch and then
/// gets out of the way, and keeps trying quietly in the background. If the
/// answer arrives late and the answer is "stop", it stops then — late is still
/// better than never.
@MainActor
final class VersionGateService: ObservableObject {
    /// Where the manifest lives.
    ///
    /// A raw file on GitHub rather than a server of our own: there is no
    /// backend to run, nothing to keep paid for, and the file can be corrected
    /// from a phone. The commit history doubles as a record of what every
    /// build was told and when.
    ///
    /// - Important: this is the only line that needs changing to point the app
    ///   at a different manifest. It must be the **raw** address — the
    ///   `github.com/.../blob/...` page is HTML and will not parse.
    static let manifestURL = URL(
        string: "https://raw.githubusercontent.com/REPLACE_ME/OmnivoxNeo/main/VersionManifest.plist"
    )!

    /// How long launch waits before giving up and letting the app through.
    static let launchGrace: Duration = .seconds(5)

    /// What to do right now. `nil` means the first check has not finished and
    /// its five seconds are not up either.
    @Published private(set) var decision: VersionGateDecision?

    /// Whether the app underneath may be built and run.
    ///
    /// True while the answer is still unknown and the grace period has passed:
    /// not knowing is not a reason to hold someone out.
    var allowsApp: Bool {
        decision?.allowsApp ?? hasPassedLaunchGrace
    }

    @Published private(set) var hasPassedLaunchGrace = false

    /// Dismissed for *this launch* — and deliberately not written down.
    ///
    /// "Ignore" on a recommended update is meant to last until the app is
    /// started fresh, which is exactly what an in-memory flag gives for free:
    /// it survives being backgrounded, because the process does, and it is
    /// gone on a cold start, because the process is. Persisting it would be
    /// more code and the wrong behaviour.
    @Published private(set) var isDismissedForThisLaunch = false

    private var pollingTask: Task<Void, Never>?
    private var hasManifest = false
    /// Whether one round trip has finished, successfully or not. Launch stops
    /// waiting on this rather than on the clock alone.
    @Published private(set) var hasFinishedAnAttempt = false
    private let session: URLSession
    private let version: String
    private let channel: AppRelease.Channel

    init(
        version: String = AppRelease.version,
        channel: AppRelease.Channel = AppRelease.channel
    ) {
        self.version = version
        self.channel = channel

        // Its own ephemeral configuration: no cookies, no credentials, and no
        // cache. A cached manifest is worse than none — it would answer with
        // whatever was true the last time the app ran, which is precisely the
        // question being asked.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    // MARK: - Running the check

    /// Starts the check and returns once the app is allowed to carry on —
    /// either because an answer arrived, or because the grace period ran out.
    func begin() async {
        #if DEBUG
        // Each state, on demand, without editing a file on GitHub and waiting
        // for a CDN. The states are rare by design and awkward to reach by
        // accident, which is exactly why they need a way to be looked at.
        if let forced = Self.forcedDecision() {
            decision = forced
            hasPassedLaunchGrace = true
            hasManifest = true
            return
        }
        #endif

        startPollingIfNeeded()

        // Races the first answer against the clock: whichever lands first ends
        // the wait. A continuous clock rather than a sleeping task because the
        // deadline has to hold across the app being suspended mid-launch.
        //
        // The failed-attempt check is what keeps this honest on a bad
        // connection. Five seconds is a cap on waiting for an answer, not a
        // penalty for not getting one: once an attempt has come back empty we
        // already know the policy is "carry on", and holding a student on the
        // launch screen for the remaining four seconds to prove it would undo
        // the instant open this app went to some trouble for.
        let deadline = ContinuousClock.now.advanced(by: Self.launchGrace)
        while decision == nil, !hasFinishedAnAttempt, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { break }
        }
        hasPassedLaunchGrace = true
    }

    /// Keeps asking until the file is in hand, then stops.
    private func startPollingIfNeeded() {
        guard pollingTask == nil, !hasManifest else { return }
        pollingTask = Task { [weak self] in
            // Backs off rather than hammering: a student with no signal should
            // not have their battery spent on a file that is not coming.
            let waits: [Duration] = [
                .seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)
            ]
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                if await self.attemptFetch() { return }
                let wait = waits[min(attempt, waits.count - 1)]
                attempt += 1
                try? await Task.sleep(for: wait)
            }
        }
    }

    /// One attempt. Returns true once there is nothing left to ask for.
    private func attemptFetch() async -> Bool {
        var request = URLRequest(url: Self.manifestURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpMethod = "GET"
        defer { hasFinishedAnAttempt = true }

        do {
            let (data, response) = try await session.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                // A 404 is a real answer — the file is not there — but it is
                // not a reason to lock anybody out, and it may well be a
                // deploy in progress. Treated like any other failure: wait,
                // ask again.
                return false
            }
            let manifest = try PropertyListDecoder().decode(VersionManifest.self, from: data)
            apply(manifest)
            return true
        } catch is CancellationError {
            return true
        } catch {
            // Unreachable, malformed, truncated, HTML instead of a plist — all
            // the same. Nothing is published, so nothing changes, and the app
            // carries on as normal.
            return false
        }
    }

    private func apply(_ manifest: VersionManifest) {
        hasManifest = true
        let resolved = VersionGateDecision.make(
            manifest: manifest,
            version: version,
            channel: channel
        )
        // A late "stop" still stops. Whatever the student was in the middle of,
        // a build with a critical fault should not keep running — and the
        // decision publishing is what pulls the blocker over the top of it.
        if case .requireUpdate = resolved {
            isDismissedForThisLaunch = false
        }
        decision = resolved
    }

    // MARK: - Answers

    /// OK on an announcement, or Ignore on a recommendation. Lasts this launch.
    func dismissForThisLaunch() {
        guard decision?.allowsApp == true else { return }
        isDismissedForThisLaunch = true
    }

    /// Hands them to the store, and on a required update gets out of the way
    /// afterwards if the manifest asked for that.
    func openUpdateDestination() {
        guard let decision else { return }
        let destination: URL?
        var terminates = false
        switch decision {
        case .recommendUpdate(_, let url):
            destination = url
        case .requireUpdate(_, let url, let shouldTerminate):
            destination = url
            terminates = shouldTerminate
        case .proceed, .announce:
            return
        }

        if let destination {
            #if os(iOS)
            UIApplication.shared.open(destination)
            #elseif os(macOS)
            NSWorkspace.shared.open(destination)
            #endif
        }

        guard terminates else { return }
        // Given a moment so the store is actually on screen before this one
        // goes away. On the Mac quitting is ordinary; on iOS it is not, which
        // is why the manifest has to ask for it explicitly and the blocking
        // screen stands on its own without it.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            #if os(macOS)
            NSApplication.shared.terminate(nil)
            #else
            exit(0)
            #endif
        }
    }

    /// Re-checks when the app comes back to the foreground, so a build that
    /// was fine this morning can still be stopped this afternoon.
    func applicationBecameActive() {
        guard !hasManifest else { return }
        startPollingIfNeeded()
    }

    #if DEBUG
    private static func forcedDecision() -> VersionGateDecision? {
        let arguments = ProcessInfo.processInfo.arguments
        let store = URL(string: "https://apps.apple.com/ca/app/omnivox-neo/id0000000000")
        let flight = URL(string: "https://testflight.apple.com/join/REPLACE_ME")

        if arguments.contains("--demo-version-announce") {
            return .announce(
                title: "One Thing To Know",
                message: "Removing the last person from a MIO message does not work on this "
                    + "build — Omnivox ignores it. Add the new recipient first, then remove "
                    + "the old one. A fix is in review."
            )
        }
        if arguments.contains("--demo-version-recommended") {
            return .recommendUpdate(
                message: "Grades now read correctly for teachers who do not group their "
                    + "assessments, MIO messages can be swiped to file or flag, and the "
                    + "schedule opens straight away instead of waiting for the sign-in.",
                destination: flight
            )
        }
        if arguments.contains("--demo-version-required") {
            return .requireUpdate(
                message: [
                    VersionGateDecision.requiredUpdatePreamble,
                    "This build signs you out at random and cannot refresh your timetable "
                        + "after midnight."
                ].joined(separator: "\n\n"),
                destination: flight,
                terminates: false
            )
        }
        if arguments.contains("--demo-version-required-appstore") {
            return .requireUpdate(
                message: VersionGateDecision.requiredUpdatePreamble,
                destination: store,
                terminates: false
            )
        }
        return nil
    }
    #endif
}
