import SwiftUI

/// Which build this is, in two quiet lines under everything else.
///
/// Distributable builds use the shape of `MARKETING_VERSION` for their channel.
/// Internal builds use the Debug configuration instead of a fourth version
/// component, which App Store Connect does not accept. `CURRENT_PROJECT_VERSION`
/// is the separate build number and does not change the channel.
enum AppRelease {
    /// How a distributable build's marketing version is read.
    ///
    /// | version | channel             |
    /// |---------|---------------------|
    /// | `1.0`   | alpha               |
    /// | `0.0.6` | beta (TestFlight)   |
    ///
    /// Debug builds are internal regardless of the marketing version.
    enum Channel {
        case alpha
        case beta
        case internalBuild

        /// The marketing version signals the channel for distributable builds.
        /// A third dot cannot be used to mark an internal build: it would make
        /// the version invalid for App Store Connect.
        init(version: String) {
            switch version.filter({ $0 == "." }).count {
            case 0, 1: self = .alpha
            default: self = .beta
            }
        }

        var label: LocalizedStringKey {
            switch self {
            case .alpha: "Alpha Build"
            case .beta: "Beta (TestFlight) Build"
            // Left exactly as written. It is addressed to whoever is holding a
            // build that was never given to anybody.
            case .internalBuild: "Internal (How the fuck did you get this) build"
            }
        }
    }

    /// Whatever `MARKETING_VERSION` was set to, straight from the bundle.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var channel: Channel {
        #if DEBUG
        .internalBuild
        #else
        Channel(version: version)
        #endif
    }
}

struct AppVersionFooter: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("App version: \(AppRelease.version)")
            Text(AppRelease.channel.label)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }
}
