//
//  ProfileSwitcherView.swift
//  OmnivoxNeo
//
//  Multi-account switching across institutions.
//

import SwiftUI

struct ProfileSwitcherView: View {
    @ObservedObject var profileStore: PortalProfileStore
    @Environment(\.dismiss) private var dismiss

    /// The profile whose session is on screen right now. Distinct from the
    /// store's active ID while a switch is still being applied.
    let currentProfileID: UUID?

    @State private var pendingRemoval: PortalProfile?
    @State private var isWorking = false
    @State private var institutionForNewAccount: Institution?

    private var orderedProfiles: [PortalProfile] {
        profileStore.profiles.sorted { left, right in
            if left.id == currentProfileID { return true }
            if right.id == currentProfileID { return false }
            return left.lastUsedAt > right.lastUsedAt
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(orderedProfiles) { profile in
                        row(for: profile)
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Switching keeps every account signed in. An account that is logged out keeps its saved authenticator, so signing back in only needs the password.")
                }

                Section {
                    if Institution.all.count == 1, let only = Institution.all.first {
                        Button {
                            addAccount(at: only)
                        } label: {
                            Label("Add Account", systemImage: "plus.circle.fill")
                        }
                    } else {
                        Menu {
                            ForEach(Institution.all) { institution in
                                Button(institution.displayName) {
                                    addAccount(at: institution)
                                }
                            }
                        } label: {
                            Label("Add Account", systemImage: "plus.circle.fill")
                        }
                    }
                } footer: {
                    Text("A new account starts at the sign-in screen with nothing carried over.")
                }
            }
            .disabled(isWorking)
            .navigationTitle("Accounts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                removalTitle,
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let profile = pendingRemoval {
                    Button("Log Out, Keep Account") {
                        Task { await signOut(profile) }
                    }
                    Button("Delete Account", role: .destructive) {
                        Task { await erase(profile) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } message: {
                Text("Logging out keeps this account on the device with its saved authenticator. Deleting removes it completely — the next sign-in starts fresh.")
            }
        }
    }

    private var removalTitle: String {
        guard let profile = pendingRemoval else { return Loc.text("Remove Account") }
        return Loc.text("Remove %@?", profile.accountLabel)
    }

    @ViewBuilder
    private func row(for profile: PortalProfile) -> some View {
        let isCurrent = profile.id == currentProfileID

        Button {
            guard !isCurrent else { return }
            profileStore.switchTo(profile.id)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                avatar(for: profile, isCurrent: isCurrent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.accountLabel)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(profile.identityLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let status = profile.statusLabel {
                        Text(status)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(profile.isSignedOut ? .orange : .secondary)
                    }
                }

                Spacer(minLength: 8)

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Neo.accent)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingRemoval = profile
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .accessibilityHint(isCurrent ? "Current account" : "Switches to this account")
    }

    private func avatar(for profile: PortalProfile, isCurrent: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isCurrent ? Neo.accent : Neo.inset)
                .frame(width: 44, height: 44)

            Text(profile.monogram)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isCurrent ? .white : .secondary)
        }
        // A logged-out account still looks like itself, just dimmed, so the
        // list reads as "your accounts" rather than "some accounts are broken".
        .opacity(profile.isSignedOut ? 0.45 : 1)
        .overlay(alignment: .bottomTrailing) {
            if profile.isSignedOut {
                Image(systemName: "moon.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.orange, in: Circle())
                    .offset(x: 3, y: 3)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    private func addAccount(at institution: Institution) {
        profileStore.beginAddingAccount(at: institution.id)
        dismiss()
    }

    private func signOut(_ profile: PortalProfile) async {
        isWorking = true
        defer { isWorking = false }

        await ProfileEraser.signOut(profile)
        profileStore.markSignedOut(profile.id)
        pendingRemoval = nil

        if profile.id == currentProfileID {
            profileStore.finishAccountRemoval(removed: profile, wasDeleted: false)
            dismiss()
        }
    }

    private func erase(_ profile: PortalProfile) async {
        isWorking = true
        defer { isWorking = false }

        let wasCurrent = profile.id == currentProfileID
        await ProfileEraser.erase(profile)
        profileStore.forgetProfile(profile.id)
        pendingRemoval = nil

        if wasCurrent {
            profileStore.finishAccountRemoval(removed: profile, wasDeleted: true)
            dismiss()
        }
    }
}

#Preview {
    ProfileSwitcherView(
        profileStore: PortalProfileStore.shared,
        currentProfileID: PortalProfileStore.shared.activeProfileID
    )
}
