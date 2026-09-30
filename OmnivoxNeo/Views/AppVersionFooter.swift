import SwiftUI

/// Which build this is, in two quiet lines under everything else.
///
/// The channel is not stored anywhere and not compiled in — it is **read out
/// of the version number itself**, by counting the dots. That is deliberate:
/// a flag saying "this is a beta" and a version number saying `0.0.3.5` can
/// disagree, and when they do the flag is the one that lies. One number, set
/// in one place (`MARKETING_VERSION`), and the label follows from it.
enum AppRelease {
    /// How the number is read.
    ///
    /// | dots | example   | what it is                |
    /// |------|-----------|---------------------------|
    /// | 1    | `1.0`     | shipped to people          |
    /// | 2    | `0.0.5`   | handed out through TestFlight |
    /// | 3    | `0.0.3.5` | never left this machine    |
    enum Channel {
        case alpha
        case beta
        case internalBuild

        /// Counting the separators rather than parsing the parts, because the
        /// parts carry no meaning here — the *shape* of the number is the
        /// whole signal.
        init(version: String) {
            switch version.filter({ $0 == "." }).count {
            case 0, 1: self = .alpha
            case 2: self = .beta
            default: self = .internalBuild
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
        Channel(version: version)
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
