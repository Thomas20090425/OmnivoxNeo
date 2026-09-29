//
//  TOTPCodeView.swift
//  OmnivoxNeo
//
//  Displays rotating TOTP code with countdown timer
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct TOTPCodeView: View {
    let secret: TOTPSecret
    @State private var currentCode = TOTPCodeView.placeholderCode
    @State private var remainingSeconds = 30
    @State private var progress: Double = 0.0
    @State private var timer: Timer?
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    private var hasCode: Bool { currentCode != Self.placeholderCode }

    var body: some View {
        VStack(spacing: 16) {
            Text("Built-in Authenticator")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 8) {
                // The whole code is one target rather than six: nobody wants to
                // hit a single digit, and six separate buttons would read as six
                // separate controls to VoiceOver.
                Button(action: copyCode) {
                    HStack(spacing: 4) {
                        ForEach(Array(currentCode.enumerated()), id: \.offset) { _, char in
                            Text(String(char))
                                .font(.largeTitle.weight(.bold))
                                .foregroundStyle(Neo.accent)
                                .frame(width: 36)
                                .padding(.vertical, 12)
                                .background(Neo.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!hasCode)
                .accessibilityLabel(accessibleCode)
                .accessibilityHint("Copies the code")

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 6)

                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(remainingSeconds <= 5 ? Color.orange : Neo.accent)
                            .frame(width: geometry.size.width * (1.0 - progress), height: 6)
                            .animation(.linear(duration: 0.1), value: progress)
                    }
                }
                .frame(height: 6)

                // Both states occupy the same space, so confirming a copy never
                // nudges the layout underneath it.
                ZStack {
                    Text("\(remainingSeconds)s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .opacity(didCopy ? 0 : 1)

                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Neo.accent)
                        .opacity(didCopy ? 1 : 0)
                }
                .font(.caption)
                .animation(.snappy(duration: 0.2), value: didCopy)
            }

            Text("This code refreshes automatically and can be used for OmniVox verification. Tap it to copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sensoryFeedback(trigger: didCopy) { _, copied in
            copied ? .success : nil
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Neo.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Neo.separator, lineWidth: 1)
        }
        .onAppear {
            startTimer()
        }
        .onDisappear {
            stopTimer()
            copyResetTask?.cancel()
        }
    }

    // MARK: - Copying

    private static let placeholderCode = "------"

    private func copyCode() {
        guard hasCode else { return }

        Pasteboard.copy(currentCode)

        // A second tap restarts the confirmation rather than letting the first
        // one's timer cut it short.
        copyResetTask?.cancel()
        didCopy = true
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }

    /// Spelled out digit by digit. Read as a number, "418302" becomes "four
    /// hundred eighteen thousand…", which is useless for typing into a field.
    private var accessibleCode: String {
        guard hasCode else { return Loc.text("Code unavailable") }
        return Loc.text("Verification code, %@", currentCode.map(String.init).joined(separator: " "))
    }

    private func startTimer() {
        updateCode()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            updateCode()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateCode() {
        do {
            let generator = try TOTPGenerator(secret: secret.secret)
            currentCode = generator.generateCode()
            remainingSeconds = generator.remainingSeconds()
            progress = generator.progress()
        } catch {
            currentCode = Self.placeholderCode
        }
    }
}

#Preview {
    TOTPCodeView(secret: TOTPSecret(
        profileID: UUID(),
        secret: "JBSWY3DPEHPK3PXP",
        enrolledAt: Date()
    ))
    .padding()
}
