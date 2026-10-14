//
//  SecuritySetupGuidanceView.swift
//  OmnivoxNeo
//
//  Explains the app's relationship with official OmniVox Mobile
//

import SwiftUI

struct SecuritySetupGuidanceView: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    @ObservedObject var model: AppModel
    @State private var currentPage = 0
    @State private var hasReadAllPages = false

    private let pages: [GuidancePage] = [
        GuidancePage(
            icon: "checkmark.shield.fill",
            iconColor: .mint,
            title: "Welcome to OmniVox Neo",
            message: "You've successfully signed in! Before we continue, there are a few important things to know about how this app works."
        ),
        GuidancePage(
            icon: "app.badge",
            iconColor: .blue,
            title: "Two Ways to Verify",
            message: "Neo offers a built-in authenticator that generates verification codes right in the app. Or, you can keep using the official OmniVox Mobile app for codes—both options work great!"
        ),
        GuidancePage(
            icon: "key.fill",
            iconColor: .cyan,
            title: "How Sign-In Works",
            message: "Neo uses a secure sign-in method. When verification is needed, you can either use Neo's built-in authenticator or get codes from the official OmniVox Mobile app."
        ),
        GuidancePage(
            icon: "number.circle.fill",
            iconColor: Color.orange,
            title: "Built-in Authenticator",
            message: "You can set up Neo's built-in authenticator in App Settings. It generates 6-digit codes automatically—no need to switch apps or check notifications."
        ),
        GuidancePage(
            icon: "iphone.gen3.badge.play",
            iconColor: .blue,
            title: "Using OmniVox Mobile Instead",
            message: "Prefer the official app? No problem! Keep OmniVox Mobile installed and Neo will detect codes from its notifications, making it easy to copy them when needed."
        ),
        GuidancePage(
            icon: "lightbulb.fill",
            iconColor: Color.orange,
            title: "Quick Summary",
            message: "Choose what works for you: Neo's built-in authenticator for convenience, or the official OmniVox Mobile app. Both methods make verification quick and easy!"
        )
    ]

    var body: some View {
        ZStack {
            NeoBackground()

            VStack(spacing: 0) {
                // Progress indicator
                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Circle()
                            .fill(index <= currentPage ? Neo.accent : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .animation(.easeInOut(duration: 0.2), value: currentPage)
                    }
                }
                .padding(.top, 30)
                .padding(.bottom, 20)

                // The paged style exists only on iOS, and all it adds is the
                // swipe — the dots above and the buttons below are this view's
                // own. So the Mac shows the current page directly rather than
                // falling back to a `TabView` that would draw a second, real
                // tab bar across the middle of the screen.
                #if os(iOS)
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        GuidancePageView(page: pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: currentPage) { _, newPage in
                    if newPage == pages.count - 1 {
                        hasReadAllPages = true
                    }
                }
                #else
                GuidancePageView(page: pages[min(currentPage, pages.count - 1)])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: currentPage) { _, newPage in
                        if newPage == pages.count - 1 {
                            hasReadAllPages = true
                        }
                    }
                #endif

                // Navigation buttons
                VStack(spacing: 15) {
                    if currentPage < pages.count - 1 {
                        Button {
                            withAnimation {
                                currentPage += 1
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Text("Continue")
                                Image(systemName: "arrow.right")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        Button("Skip") {
                            withAnimation {
                                currentPage = pages.count - 1
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Neo.accent)
                    } else {
                        Button {
                            continueToSecuritySetup()
                        } label: {
                            HStack(spacing: 9) {
                                Text("Got It!")
                                Image(systemName: "checkmark")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!hasReadAllPages)
                        .opacity(hasReadAllPages ? 1 : 0.6)
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 22)
                .padding(.bottom, 30)
            }
        }
        .tint(Neo.accent)
    }

    private func continueToSecuritySetup() {
        // Scoped to the account: a second student gets their own introduction
        // rather than inheriting the first one's "already seen it".
        if let profileID = model.activeProfileID {
            UserDefaults.standard.set(
                true,
                forKey: AppModel.securityGuidanceKey(for: profileID)
            )
        }
        model.proceedToSecuritySetup()
    }
}

/// `LocalizedStringKey`, not `String`: a plain String sends `Text` to its
/// verbatim initializer, which would have shipped these six pages in English
/// forever. As keys they are extracted into the catalog and resolved against
/// the environment's locale, so they follow the language setting live.
private struct GuidancePage {
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    let message: LocalizedStringKey
}

private struct GuidancePageView: View {
    let page: GuidancePage

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer()
                    .frame(height: 20)

                ZStack {
                    Circle()
                        .fill(page.iconColor.opacity(0.12))
                        .frame(width: 100, height: 100)

                    Image(systemName: page.icon)
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(page.iconColor)
                }

                VStack(spacing: 12) {
                    Text(page.title)
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)

                    Text(page.message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 30)
        }
        .scrollIndicators(.hidden)
    }
}

#Preview {
    SecuritySetupGuidanceView(model: AppModel(startsAutomatically: false))
}
