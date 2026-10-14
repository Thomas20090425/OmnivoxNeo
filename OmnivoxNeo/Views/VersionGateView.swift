import SwiftUI

/// What the student sees when the manifest has something to say.
///
/// Drawn over the app rather than instead of it, for everything except a
/// required update — an announcement is a note, not a destination, and the app
/// behind it should already be there when the note goes away. A required
/// update is the exception: there is nothing behind it, because nothing behind
/// it was allowed to start.
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

    private var isRequired: Bool {
        if case .requireUpdate = decision { return true }
        return false
    }

    var body: some View {
        ZStack {
            // Heavier behind a required update: there is no way past it, and
            // the app should not look momentarily available underneath.
            Rectangle()
                .fill(.black.opacity(isRequired ? 0.55 : 0.32))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    NeoLogo(size: 46)

                    Text(title)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)

                    // The state said in words rather than with a coloured dot
                    // or a pill: the sentence is the thing that has to survive
                    // being read quickly, and type carries it better.
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
        // Nothing underneath a required update may be reached — not by a tap
        // that lands outside the card, not by a VoiceOver swipe past it.
        .accessibilityAddTraits(.isModal)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
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

            if let decision = visibleDecision {
                VersionGateNotice(
                    decision: decision,
                    onUpdate: { service.openUpdateDestination() },
                    onDismiss: { service.dismissForThisLaunch() }
                )
            }
        }
        .animation(.easeInOut(duration: 0.22), value: visibleDecision)
        .animation(.easeInOut(duration: 0.22), value: service.allowsApp)
        .task {
            await service.begin()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { service.applicationBecameActive() }
        }
    }
}
