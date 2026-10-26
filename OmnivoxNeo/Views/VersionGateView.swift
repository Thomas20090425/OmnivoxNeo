import SwiftUI

/// What the student sees when the manifest has something to say.
///
/// Presented over the app in a system sheet, except that a required update
/// keeps the guarded app from starting until the version check allows it.
struct VersionGateNotice: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    let decision: VersionGateDecision
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    private var title: LocalizedStringKey {
        switch decision {
        case .announce(let title, _): return LocalizedStringKey(title)
        case .recommendUpdate: return "Update Recommended"
        case .requireUpdate: return "Update Required"
        case .proceed: return ""
        }
    }

    private var message: String {
        switch decision {
        case .announce(_, let message): return message
        case .recommendUpdate(let message, _): return message
        case .requireUpdate(let message, _, _): return message
        case .proceed: return ""
        }
    }

    /// Whether there is anywhere for an Update button to go. A manifest with
    /// no usable link still gets to say its piece — it just cannot promise a
    /// door that is not there.
    private var hasDestination: Bool {
        switch decision {
        case .recommendUpdate(_, let url), .requireUpdate(_, let url, _):
            return url != nil
        case .announce, .proceed:
            return false
        }
    }

    var body: some View {
        // Presented in a system sheet so its contents move away from Duo's
        // folding region and cameras as the display changes pose.
        GeometryReader { geometry in
            ScrollView {
                noticeCard
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(NeoBackground())
        // Nothing underneath a required update may be reached — not by a tap
        // that lands outside the sheet, not by a VoiceOver swipe past it.
        .accessibilityAddTraits(.isModal)
    }

    private var noticeCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                NeoLogo(size: 46)

                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(AppRelease.version)
                    .font(.footnote.italic())
                    .fontDesign(.serif)
                    .foregroundStyle(.secondary)

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 26)
            .padding(.top, 30)
            .padding(.bottom, 24)

            Divider()

            buttons
        }
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.white.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
        .padding(28)
    }

    @ViewBuilder
    private var buttons: some View {
        switch decision {
        case .announce:
            gateButton("OK", prominent: true, action: onDismiss)

        case .recommendUpdate:
            HStack(spacing: 0) {
                gateButton("Ignore", prominent: false, action: onDismiss)
                Divider()
                gateButton("Update", prominent: true, action: onUpdate)
                    .disabled(!hasDestination)
            }
            .frame(height: 50)

        case .requireUpdate:
            // One way out, and it is forward. No Ignore, no Later, and no
            // swipe-to-dismiss: a build that corrupts someone's account is
            // not something to be talked out of.
            gateButton("Update", prominent: true, action: onUpdate)
                .disabled(!hasDestination)

        case .proceed:
            EmptyView()
        }
    }

    private func gateButton(
        _ label: LocalizedStringKey,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.body.weight(prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Neo.accent : Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: 50)
    }
}

/// Stands in front of the app until the version check has had its say.
///
/// A modifier rather than a wrapper view so the thing it guards is still
/// written plainly at the call site.
struct VersionGate<Guarded: View>: View {
    @StateObject private var service = VersionGateService()
    @Environment(\.scenePhase) private var scenePhase

    let guarded: () -> Guarded

    private var visibleDecision: VersionGateDecision? {
        guard let decision = service.decision else { return nil }
        switch decision {
        case .proceed:
            return nil
        case .announce, .recommendUpdate:
            // Spoken once per launch. "Ignore" and "OK" are the same promise:
            // not again until the app is started fresh.
            return service.isDismissedForThisLaunch ? nil : decision
        case .requireUpdate:
            return decision
        }
    }

    private var requiresUpdate: Bool {
        if case .requireUpdate = visibleDecision { return true }
        return false
    }

    var body: some View {
        ZStack {
            NeoBackground()

            // Nothing is constructed until the check allows it. That is the
            // point of the whole file: a build told to stop must not get as
            // far as building an AppModel, opening a web view, or touching
            // somebody's saved session.
            if service.allowsApp {
                guarded()
            } else {
                LaunchingView()
            }
        }
        .sheet(isPresented: Binding(
            get: { visibleDecision != nil },
            set: { presented in
                if !presented && !requiresUpdate {
                    service.dismissForThisLaunch()
                }
            }
        )) {
            if let decision = visibleDecision {
                VersionGateNotice(
                    decision: decision,
                    onUpdate: { service.openUpdateDestination() },
                    onDismiss: { service.dismissForThisLaunch() }
                )
                .interactiveDismissDisabled(requiresUpdate)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: service.allowsApp)
        .task {
            await service.begin()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { service.applicationBecameActive() }
        }
    }
}
