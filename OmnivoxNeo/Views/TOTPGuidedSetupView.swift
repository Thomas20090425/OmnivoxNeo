//
//  TOTPGuidedSetupView.swift
//  OmnivoxNeo
//
//  Split-screen guided TOTP setup with embedded WebView
//

import SwiftUI

/// Debug-only logging for the guided two-factor setup.
///
/// This flow reads the system clipboard on a timer to catch the secret the
/// portal puts there, which means it sees whatever else the student had
/// copied — another app's password, a message. None of that belongs in a log
/// on a device anybody is actually using, and the secret itself belongs there
/// least of all, so what survives is lengths and outcomes rather than values.
private func devLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[2FA setup] " + message())
    #endif
}

import WebKit
import Combine

struct TOTPGuidedSetupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var coordinator: SetupCoordinator

    init(model: AppModel) {
        self.model = model
        _coordinator = StateObject(wrappedValue: SetupCoordinator(institution: model.institution))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Guide Section (Top)
            guideSection
                .frame(maxWidth: .infinity)
                .padding()
                .background(Neo.surface)

            Divider()

            // WebView Section (Bottom)
            GuidedWebView(
                coordinator: coordinator,
                institution: model.institution,
                dataStore: model.webView.configuration.websiteDataStore
            )
        }
        .interactiveDismissDisabled(coordinator.capturedSecret != nil)
        .onAppear {
            // Clear clipboard when setup starts
            Pasteboard.clear()
            devLog("🗑️ Cleared clipboard on setup start")
        }
        .onChange(of: coordinator.currentStep) { _, newStep in
            // Only save when setup is completed successfully
            if newStep == .completed {
                if let secret = coordinator.capturedSecret {
                    saveSecret(secret)
                    // Dismiss after a brief moment
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var guideSection: some View {
        VStack(spacing: 16) {
            HStack {
                // Only show Cancel button if secret hasn't been captured yet
                if coordinator.capturedSecret == nil {
                    Button("Cancel") {
                        dismiss()
                    }
                } else {
                    // Empty space to maintain layout
                    Color.clear.frame(width: 60, height: 20)
                }
                Spacer()
            }

            switch coordinator.currentStep {
            case .checkExisting:
                checkExistingGuide
            case .deleteExisting:
                deleteExistingGuide
            case .createNew:
                createNewGuide
            case .revealSecret:
                revealSecretGuide
            case .copySecret:
                copySecretGuide
            case .enterCode:
                enterCodeGuide
            case .completed:
                completedGuide
            }
        }
    }

    private var checkExistingGuide: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(Neo.accent)

            Text("Check for Existing Authenticator")
                .font(.headline)

            Text("Look below to see if \"Authentication application\" is already listed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if coordinator.isDetectingAuth {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for existing authenticator...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } else if coordinator.hasExistingAuth {
                Text("✓ Found existing authenticator")
                    .foregroundStyle(Neo.live)

                Button("Next") {
                    coordinator.currentStep = .deleteExisting
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Button("No Authenticator Found - Continue") {
                    coordinator.currentStep = .createNew
                    coordinator.navigateToCreate()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var deleteExistingGuide: some View {
        VStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("Delete Existing Authenticator")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("1. Find \"Authentication application\"")
                    Spacer()
                }
                HStack {
                    Text("2. Tap the")
                    Text("⋮")
                        .font(.title2.bold())
                    Text("button")
                    Spacer()
                }
                HStack {
                    Text("3. Tap \"DELETE\"")
                    Spacer()
                }
                HStack {
                    Text("4. Confirm deletion")
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                coordinator.deletionError ? Color.red.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .foregroundStyle(coordinator.deletionError ? .red : .primary)

            Button("I've Deleted It - Continue") {
                coordinator.checkIfDeleted()
            }
            .buttonStyle(PrimaryButtonStyle())
            .alert("PLEASE READ INSTRUCTIONS", isPresented: $coordinator.deletionError) {
                Button("OK", role: .cancel) {
                    coordinator.deletionError = false
                }
            } message: {
                Text("You cannot proceed until existing authenticator app has been deleted")
            }
        }
    }

    private var createNewGuide: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)

            Text("Navigating to Setup...")
                .foregroundStyle(.secondary)
        }
    }

    private var revealSecretGuide: some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode")
                .font(.largeTitle)
                .foregroundStyle(Neo.accent)

            Text("Reveal the Secret Code")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("1. Tap **\"I cannot scan this code\"** below")
                Text("2. Then tap the **Copy** button next to the long code")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Neo.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var copySecretGuide: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("Copy the Secret Code")
                .font(.headline)

            Text("Tap the **Copy** button next to the long code below.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                // Status indicator with checkmark
                HStack(spacing: 8) {
                    Image(systemName: coordinator.capturedSecret != nil ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(coordinator.capturedSecret != nil ? Neo.live : Color.secondary.opacity(0.3))
                        .font(.title2)

                    Text(coordinator.capturedSecret != nil ? "Code Detected" : "Waiting...")
                        .font(.subheadline)
                        .foregroundStyle(coordinator.capturedSecret != nil ? Neo.live : .secondary)
                }

                Spacer()

                // Check clipboard again button (always visible as fallback)
                Button {
                    coordinator.recheckClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                        Text("Check Again")
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Neo.surface, in: RoundedRectangle(cornerRadius: 12))

            if coordinator.capturedSecret != nil {
                Text("✓ Secret copied! Click Next below to continue.")
                    .font(.callout)
                    .foregroundStyle(Neo.live)
                    .padding(.top, 4)
            }
        }
    }

    private var enterCodeGuide: some View {
        VStack(spacing: 12) {
            if let secret = coordinator.capturedSecret {
                TOTPCodeDisplay(secret: secret)

                Text("Enter this code below and tap \"Validate\"")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("The code refreshes every 30 seconds")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if coordinator.isDetectingAuth {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Verifying setup completion...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private var completedGuide: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(Neo.live)

            Text("Setup Complete!")
                .font(.title2.bold())

            Text("Your built-in authenticator is ready to use.")
                .foregroundStyle(.secondary)

            Button("Done") {
                dismiss()
            }
        }
    }

    private func saveSecret(_ secret: String) {
        guard let profileID = PortalProfileStore.shared.activeProfileID else {
            devLog("❌ No active profile found")
            return
        }

        let totpSecret = TOTPSecret(
            profileID: profileID,
            secret: secret,
            enrolledAt: Date()
        )

        let vault = TOTPVault(profileID: profileID)
        vault.save(totpSecret)
    }
}

// MARK: - Setup Coordinator

@MainActor
class SetupCoordinator: NSObject, ObservableObject {
    enum Step {
        case checkExisting
        case deleteExisting
        case createNew
        case revealSecret
        case copySecret
        case enterCode
        case completed
    }

    @Published var currentStep: Step = .checkExisting
    @Published var hasExistingAuth = false
    @Published var capturedSecret: String?
    @Published var isMonitoringClipboard = false
    @Published var isDetectingAuth = true // Start as true to show loading initially
    @Published var deletionError: Bool = false

    weak var webView: WKWebView?
    private var clipboardTimer: Timer?
    private var lastClipboardContent: String?
    var nextButtonUnhidden = false
    var totpUpdateTimer: Timer?
    let institution: Institution

    init(institution: Institution) {
        self.institution = institution
        super.init()
    }

    func recheckClipboard() {
        devLog("🔄 Manually rechecking clipboard...")

        if let content = Pasteboard.text {
            let cleaned = content.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\t", with: "")
                .uppercased()

            devLog("Clipboard holds \(cleaned.count) usable characters")

            let isValidLength = cleaned.count >= 16 && cleaned.count <= 52
            let isBase32 = cleaned.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567=".contains($0) }

            devLog("📋 Valid length: \(isValidLength), Is Base32: \(isBase32)")

            if isValidLength && isBase32 {
                devLog("✅ Valid TOTP secret found in clipboard!")
                capturedSecret = cleaned
                // Taken off the clipboard the moment it is in hand. This is a
                // two-factor seed: left sitting there it is readable by every
                // other app on the device, and with Universal Clipboard on it
                // travels to the student's other Apple devices through Apple's
                // servers. Clearing it at setup start was never enough — that
                // is before the secret arrives.
                Pasteboard.clear()
            } else {
                devLog("❌ Clipboard does not contain valid TOTP secret")
            }
        } else {
            devLog("❌ Clipboard is empty")
        }
    }

    func recheckSecretVisibility() {
        guard let webView = webView else { return }
        devLog("🔄 Manually rechecking secret visibility...")

        webView.evaluateJavaScript("""
        (function() {
            const secretEl = document.querySelector('.MuiTypography-button');
            console.log('Recheck - Secret element:', secretEl);
            console.log('Recheck - Secret text:', secretEl ? secretEl.textContent : 'not found');
            return secretEl !== null && secretEl.textContent.trim().length > 0;
        })();
        """) { [weak self] result, error in
            if let error = error {
                devLog("❌ Recheck error: \(error)")
            }

            if let isVisible = result as? Bool {
                devLog("📄 Recheck - Secret visible: \(isVisible)")
                if isVisible {
                    devLog("✅ Secret NOW visible - starting clipboard monitoring")
                    self?.currentStep = .copySecret
                    self?.startMonitoringClipboard()
                } else {
                    devLog("❌ Secret still not visible")
                }
            }
        }
    }

    func checkIfDeleted() {
        // Check if authentication app still exists
        webView?.evaluateJavaScript("""
        (function() {
            const items = document.querySelectorAll('[data-testid="SystemSecurityUpdateGoodIcon"]');
            return items.length > 0;
        })();
        """) { [weak self] result, _ in
            if let exists = result as? Bool {
                if !exists {
                    // Actually deleted, proceed
                    self?.deletionError = false
                    self?.currentStep = .createNew
                    self?.navigateToCreate()
                } else {
                    // Still exists, show error
                    self?.deletionError = true
                    devLog("⚠️ User tried to proceed without deleting authenticator")
                }
            }
        }
    }

    /// Reveals the portal's own Next button once the secret is captured.
    ///
    /// The button is hidden by a rule in the injected stylesheet, so it is
    /// revealed by rewriting that rule — not by setting an inline style on the
    /// button. OmniVox re-creates the node on re-render, which discards any
    /// inline style and leaves the student stuck with no way forward.
    func revealNextButton() {
        nextButtonUnhidden = true
        guard let webView else {
            devLog("❌ WebView is nil, cannot reveal the Next button")
            return
        }

        let script = """
        (function() {
            var style = document.getElementById('neo-hide-style');
            if (!style) {
                style = document.createElement('style');
                style.id = 'neo-hide-style';
                document.head.appendChild(style);
            }
            style.textContent = style.textContent.replace(
                /\\.MuiButton-containedPrimary\\s*\\{[^}]*\\}/g, ''
            ) + `
            .MuiButton-containedPrimary {
                display: inline-flex !important;
                visibility: visible !important;
                opacity: 1 !important;
            }
            `;
            var buttons = document.querySelectorAll('.MuiButton-containedPrimary');
            buttons.forEach(function(button) {
                button.style.removeProperty('display'); 
                button.style.removeProperty('visibility');
            });
            return buttons.length;
        })();
        """

        webView.evaluateJavaScript(script) { result, error in
            if let error {
                devLog("❌ Failed to reveal the Next button: \(error)")
            } else {
                devLog("✅ Next button revealed (\(result ?? 0) present)")
            }
        }
    }

    func navigateToCreate() {
        guard let webView = webView else { return }
        let url = institution.origin
            .appending(path: institution.conventions.totpCreatePath)
        webView.load(URLRequest(url: url))
    }

    func startMonitoringClipboard() {
        isMonitoringClipboard = true

        devLog("🔍 Started monitoring clipboard")

        // Check immediately if clipboard already has a valid secret
        if let content = Pasteboard.text {
            let cleaned = content.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\t", with: "")
                .uppercased()

            let isValidLength = cleaned.count >= 16 && cleaned.count <= 52
            let isBase32 = cleaned.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567=".contains($0) }

            if isValidLength && isBase32 {
                devLog("✅ Clipboard already contains valid TOTP secret!")
                capturedSecret = cleaned
                // Taken off the clipboard the moment it is in hand. This is a
                // two-factor seed: left sitting there it is readable by every
                // other app on the device, and with Universal Clipboard on it
                // travels to the student's other Apple devices through Apple's
                // servers. Clearing it at setup start was never enough — that
                // is before the secret arrives.
                Pasteboard.clear()
                currentStep = .enterCode
                revealNextButton()
                return
            }
        }

        lastClipboardContent = Pasteboard.text

        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    func navigateToValidation() {
        guard let webView = webView,
              let currentURL = webView.url,
              currentURL.path.contains("/totp/") else {
            devLog("❌ Cannot navigate - invalid URL")
            return
        }

        // Extract the ID from URL like /totp/WLP7RyVfwEsFWM2ugEmbyQ?mode=update
        let pathComponents = currentURL.pathComponents
        if let totpIndex = pathComponents.firstIndex(of: "totp"),
           totpIndex + 1 < pathComponents.count {
            let id = pathComponents[totpIndex + 1]

            // Build validation URL: /apps/mfa/validation-methods/{id}/validate?mode=validation
            // Built from the school's own origin rather than the page's host: a
            // redirect elsewhere must not send a validation request there.
            let validationURL = institution.origin
                .appending(path: institution.conventions.mfaSettingsPath)
                .appending(path: "\(id)/validate")
                .appending(queryItems: [URLQueryItem(name: "mode", value: "validation")])
                .absoluteString

            devLog("🔄 Navigating to validation page: \(validationURL)")

            if let url = URL(string: validationURL) {
                webView.load(URLRequest(url: url))
            }
        }
    }

    private func checkClipboard() {
        let content = Pasteboard.text

        devLog("📋 Checking clipboard...")
        devLog("Clipboard: \(content?.count ?? 0) chars, previously \(lastClipboardContent?.count ?? 0)")

        guard let content = content else {
            devLog("📋 No clipboard content")
            return
        }

        guard content != lastClipboardContent else {
            devLog("📋 Content unchanged")
            return
        }

        devLog("Clipboard changed (\(content.count) chars)")

        // Check if it's a TOTP secret (base32, 16-52 chars)
        let cleaned = content.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .uppercased()

        devLog("After cleaning: \(cleaned.count) chars")

        let isValidLength = cleaned.count >= 16 && cleaned.count <= 52
        devLog("📋 Valid length (16-52): \(isValidLength)")

        let isBase32 = cleaned.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567=".contains($0) }
        devLog("📋 Is Base32: \(isBase32)")

        if isValidLength && isBase32 {
            devLog("✅✅✅ Valid TOTP secret detected!")
            clipboardTimer?.invalidate()
            clipboardTimer = nil
            isMonitoringClipboard = false
            capturedSecret = cleaned
            // Taken off the clipboard the moment it is in hand. This is a
            // two-factor seed: left sitting there it is readable by every
            // other app on the device, and with Universal Clipboard on it
            // travels to the student's other Apple devices through Apple's
            // servers. Clearing it at setup start was never enough — that
            // is before the secret arrives.
            Pasteboard.clear()

            // Switch to enterCode step to show TOTP code at top
            DispatchQueue.main.async { [weak self] in
                self?.currentStep = .enterCode
                devLog("✅ Step changed to enterCode - showing TOTP code")
            }

            DispatchQueue.main.async { [weak self] in
                self?.revealNextButton()
            }
        } else {
            devLog("❌ Not a valid TOTP secret")
        }

        lastClipboardContent = content
    }

    deinit {
        clipboardTimer?.invalidate()
    }
}

// MARK: - Guided WebView

struct GuidedWebView: PlatformViewRepresentable {
    @ObservedObject var coordinator: SetupCoordinator
    let institution: Institution
    let dataStore: WKWebsiteDataStore

    // `WKWebView` is the same class on both platforms; only the two hooks
    // SwiftUI calls it through are named differently. One implementation,
    // forwarded from whichever pair of names this platform expects.
    #if canImport(UIKit)
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ webView: WKWebView, context: Context) { updateWebView(webView, context: context) }
    #else
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ webView: WKWebView, context: Context) { updateWebView(webView, context: context) }
    #endif

    private func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = "OmnivoxNeo/1.0"

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        coordinator.webView = webView

        let url = institution.origin
            .appending(path: institution.conventions.mfaSettingsPath)
        devLog("🔐 TOTP Setup: Loading initial URL: \(url.absoluteString)")
        webView.load(URLRequest(url: url))

        return webView
    }

    private func updateWebView(_ webView: WKWebView, context: Context) {
        // Inject CSS to hide elements after a short delay to ensure page is loaded
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            context.coordinator.injectHideStyles(webView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(setupCoordinator: coordinator, institution: institution)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let setupCoordinator: SetupCoordinator
        let institution: Institution

        init(setupCoordinator: SetupCoordinator, institution: Institution) {
            self.setupCoordinator = setupCoordinator
            self.institution = institution
        }

        func injectHideStyles(_ webView: WKWebView) {
            // Always re-assert the stylesheet, including after the secret is
            // captured. The Next button's visibility is a CSS rule, not a patch
            // applied to particular nodes: OmniVox is React, so the button is
            // re-created on re-render and any inline style we set is lost. Only
            // rewriting this rule keeps the reveal stable.
            let nextButtonRule = setupCoordinator.nextButtonUnhidden
                ? """
                /* Secret captured - Next is the way forward. */
                .MuiButton-containedPrimary {
                    display: inline-flex !important;
                    visibility: visible !important;
                    opacity: 1 !important;
                }
                """
                : """
                /* Hide Next until we have the secret, so it can't be skipped. */
                .MuiButton-containedPrimary {
                    display: none !important;
                }
                """

            let hideCSS = """
            header.MuiAppBar-root,
            header.MuiPaper-elevation,
            .MuiAppBar-colorPrimary {
                display: none !important;
                height: 0 !important;
                overflow: hidden !important;
            }

            .MuiBox-root.css-1bvc4cc {
                display: none !important;
            }

            button:has(svg[data-testid="AddIcon"]) {
                display: none !important;
            }

            img[alt*="QR"],
            img[alt*="Code QR"] {
                display: none !important;
            }

            a[href^="otpauth://"] {
                display: none !important;
            }

            a[href="/apps/mfa/validation-methods"] {
                display: none !important;
            }

            a[href="/apps/mfa/help"],
            a[aria-label*="dépannage"],
            a[aria-label*="Troubleshooting"],
            .MuiFab-root[href="/apps/mfa/help"] {
                display: none !important;
            }

            /* Hide ALL back buttons */
            .css-14f6bz4 {
                display: none !important;
            }

            \(nextButtonRule)
            """

            let script = """
            (function() {
                var style = document.getElementById('neo-hide-style');
                if (!style) {
                    style = document.createElement('style');
                    style.id = 'neo-hide-style';
                    document.head.appendChild(style);
                }
                style.textContent = `\(hideCSS)`;

                console.log('Neo: CSS injected to hide buttons');
            })();
            """

            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    devLog("❌ Failed to inject CSS: \(error)")
                } else {
                    devLog("✅ CSS injected successfully")
                }
            }
        }

        func unhideNextButton(_ webView: WKWebView) {
            devLog("🔓 Unhiding Next button...")
            setupCoordinator.nextButtonUnhidden = true
            injectHideStyles(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Check current page and update step
            webView.url.map { url in
                devLog("📍 Current page: \(url.path)")

                if url.path.contains("/validation-methods/totp/create") {
                    // On TOTP create page - inject CSS and handle secret detection
                    injectHideStyles(webView)
                    handleCreatePage(webView)
                } else if url.path.contains("/validate") {
                    // On validation page - inject CSS to hide back button
                    devLog("📄 On validation page - injecting CSS")
                    injectValidationPageCSS(webView)
                    setupCoordinator.currentStep = .enterCode
                } else if url.path == institution.conventions.mfaSettingsPath {
                    // Check for auth BEFORE hiding elements, then hide after detection
                    handleMethodsPage(webView)
                    // Also inject CSS to hide elements on the success page
                    injectHideStyles(webView)
                } else {
                    // The stylesheet is phase-aware, so it is always safe to
                    // re-assert it on a fresh page.
                    injectHideStyles(webView)
                }
            }
        }

        private func injectValidationPageCSS(_ webView: WKWebView) {
            let hideCSS = """
            header.MuiAppBar-root,
            header.MuiPaper-elevation,
            .MuiAppBar-colorPrimary {
                display: none !important;
                height: 0 !important;
                overflow: hidden !important;
            }

            /* Hide back button on validation page */
            .css-14f6bz4,
            a[href*="/totp/"] {
                display: none !important;
            }

            a[href="/apps/mfa/help"],
            a[aria-label*="dépannage"],
            a[aria-label*="Troubleshooting"],
            .MuiFab-root[href="/apps/mfa/help"] {
                display: none !important;
            }
            """

            let script = """
            (function() {
                var style = document.getElementById('neo-validation-style');
                if (!style) {
                    style = document.createElement('style');
                    style.id = 'neo-validation-style';
                    document.head.appendChild(style);
                }
                style.textContent = `\(hideCSS)`;
                console.log('Neo: Validation page CSS injected');
            })();
            """

            webView.evaluateJavaScript(script) { [weak self] _, error in
                if let error = error {
                    devLog("❌ Failed to inject validation CSS: \(error)")
                } else {
                    devLog("✅ Validation page CSS injected successfully")

                    // Auto-fill TOTP code after CSS injection
                    self?.autoFillTOTPCode(webView)
                }
            }
        }

        private func autoFillTOTPCode(_ webView: WKWebView) {
            guard let secret = setupCoordinator.capturedSecret else {
                devLog("❌ No captured secret to generate TOTP")
                return
            }

            // Generate TOTP code
            guard let generator = try? TOTPGenerator(secret: secret) else {
                devLog("❌ Failed to generate TOTP code")
                return
            }
            let totp = generator.generateCode()
            devLog("Auto-filling the current code")

            // Wait a bit for the page to fully loadayou
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let script = """
                (function() {
                    console.log('Neo: Looking for input field...');
                    const input = document.querySelector('input[maxlength="6"]');
                    console.log('Neo: Input found:', input);

                    if (!input) {
                        return { success: false, error: 'Input not found' };
                    }

                    // Set value and trigger React's onChange
                    const nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
                    nativeInputValueSetter.call(input, '\(totp)');

                    // Trigger input event for React
                    const event = new Event('input', { bubbles: true });
                    input.dispatchEvent(event);

                    // Make it readonly (not disabled - disabled breaks form submission)
                    input.readOnly = true;

                    // Style it to look disabled
                    input.style.backgroundColor = '#e0e0e0';
                    input.style.cursor = 'not-allowed';
                    input.style.color = '#666';

                    // Block keyboard input
                    input.addEventListener('keydown', function(e) {
                        e.preventDefault();
                        e.stopPropagation();
                        return false;
                    }, true);

                    console.log('Neo: Set value to:', input.value);
                    console.log('Neo: Input is readonly:', input.readOnly);

                    return { success: true, value: input.value, readonly: input.readOnly };
                })();
                """

                webView.evaluateJavaScript(script) { [weak self] result, error in
                    if let error = error {
                        devLog("❌ Failed to auto-fill TOTP: \(error)")
                        return
                    }

                    if let dict = result as? [String: Any] {
                        devLog("📊 Auto-fill result: \(dict)")
                        if let success = dict["success"] as? Bool, success {
                            devLog("✅ TOTP code auto-filled and input blocked")
                            // Start update timer
                            self?.startTOTPUpdateTimer(webView)
                        } else {
                            devLog("❌ Failed: \(dict["error"] ?? "unknown")")
                        }
                    }
                }
            }
        }

        private func startTOTPUpdateTimer(_ webView: WKWebView) {
            setupCoordinator.totpUpdateTimer?.invalidate()

            devLog("⏱️ Starting TOTP auto-update timer (every 2 seconds)")

            setupCoordinator.totpUpdateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let secret = self?.setupCoordinator.capturedSecret,
                      let generator = try? TOTPGenerator(secret: secret) else {
                    return
                }

                let newCode = generator.generateCode()

                let updateScript = """
                (function() {
                    const input = document.querySelector('input[maxlength="6"]');
                    if (!input) return { success: false, reason: 'no input' };

                    const oldValue = input.value;
                    const newValue = '\(newCode)';

                    if (oldValue !== newValue) {
                        // Update using React's way
                        const nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
                        nativeInputValueSetter.call(input, newValue);

                        // Trigger input event for React
                        const event = new Event('input', { bubbles: true });
                        input.dispatchEvent(event);

                        console.log('Neo: Updated code from', oldValue, 'to', newValue);
                        return { success: true, updated: true, old: oldValue, new: newValue };
                    }

                    return { success: true, updated: false, value: oldValue };
                })();
                """

                webView.evaluateJavaScript(updateScript) { result, _ in
                    if let dict = result as? [String: Any] {
                        if let updated = dict["updated"] as? Bool, updated {
                            devLog("Code rolled over")
                        }
                        if let success = dict["success"] as? Bool, !success {
                            devLog("⏹️ Stopping timer - input no longer exists")
                            self?.setupCoordinator.totpUpdateTimer?.invalidate()
                            self?.setupCoordinator.totpUpdateTimer = nil
                        }
                    }
                }
            }
        }

        private func handleMethodsPage(_ webView: WKWebView) {
            // Set loading state
            setupCoordinator.isDetectingAuth = true
            devLog("🔄 Starting auth detection...")

            // Wait for page to fully render before checking
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                // Check if auth app exists (successful setup indicator)
                webView.evaluateJavaScript("""
                (function() {
                    console.log('Neo: Checking for auth app...');

                    // Look for ALL svg elements with data-testid
                    const allSvgs = document.querySelectorAll('svg[data-testid]');
                    console.log('Neo: All SVG testids:', Array.from(allSvgs).map(s => s.getAttribute('data-testid')));

                    // Look for the specific icons
                    const securityIcons = document.querySelectorAll('svg[data-testid="SystemSecurityUpdateGoodIcon"]');
                    const verifiedIcons = document.querySelectorAll('svg[data-testid="VerifiedUserIcon"]');

                    // Look for text "Application d'authentification"
                    const bodyText = document.body.textContent;
                    const hasAuthAppText = bodyText.includes('Application d\\'authentification') ||
                                           bodyText.includes('Authenticator app');

                    // Look for the confirmation text
                    const hasConfirmed = bodyText.includes('Confirmé') || bodyText.includes('Confirmed');

                    console.log('Neo: Security icons:', securityIcons.length);
                    console.log('Neo: Verified icons:', verifiedIcons.length);
                    console.log('Neo: Has auth app text:', hasAuthAppText);
                    console.log('Neo: Has confirmed text:', hasConfirmed);

                    // If we see both auth app text AND confirmed text, it exists
                    const exists = (securityIcons.length > 0) ||
                                   (verifiedIcons.length > 0) ||
                                   (hasAuthAppText && hasConfirmed);

                    return {
                        exists: exists,
                        securityIcons: securityIcons.length,
                        verifiedIcons: verifiedIcons.length,
                        hasAuthAppText: hasAuthAppText,
                        hasConfirmed: hasConfirmed,
                        allTestIds: Array.from(allSvgs).map(s => s.getAttribute('data-testid'))
                    };
                })();
                """) { [weak self] result, error in
                    // Clear loading state
                    DispatchQueue.main.async {
                        self?.setupCoordinator.isDetectingAuth = false
                    }

                    if let error = error {
                        devLog("❌ Error detecting auth: \(error)")
                        return
                    }

                    if let dict = result as? [String: Any] {
                        devLog("📊 Auth detection result: \(dict)")

                        if let exists = dict["exists"] as? Bool {
                            self?.setupCoordinator.hasExistingAuth = exists
                            devLog("🔍 Has existing auth: \(exists)")

                            // If we have a captured secret and auth now exists, setup was successful
                            if exists && self?.setupCoordinator.capturedSecret != nil {
                                devLog("✅ TOTP setup completed successfully!")

                                // Stop update timer
                                self?.setupCoordinator.totpUpdateTimer?.invalidate()
                                self?.setupCoordinator.totpUpdateTimer = nil

                                // Mark as completed
                                DispatchQueue.main.async {
                                    self?.setupCoordinator.currentStep = .completed
                                }
                            } else if !exists && self?.setupCoordinator.capturedSecret == nil {
                                // Only show "not detected" if we weren't just setting up
                                devLog("⚠️ No auth app detected on methods page")
                            }
                        }
                    }
                }
            }
        }

        private func handleCreatePage(_ webView: WKWebView) {
            // Check if secret is visible
            webView.evaluateJavaScript("""
            (function() {
                const secretEl = document.querySelector('.MuiTypography-button');
                console.log('Secret element:', secretEl);
                console.log('Secret text:', secretEl ? secretEl.textContent : 'not found');
                return secretEl !== null && secretEl.textContent.trim().length > 0;
            })();
            """) { [weak self] result, error in
                devLog("🔍 Checking for secret visibility...")
                if let error = error {
                    devLog("❌ Error checking secret: \(error)")
                }

                if let isVisible = result as? Bool {
                    devLog("📄 Secret visible: \(isVisible)")
                    if isVisible {
                        devLog("✅ Secret is visible - starting clipboard monitoring")
                        self?.setupCoordinator.currentStep = .copySecret
                        self?.setupCoordinator.startMonitoringClipboard()
                    } else {
                        devLog("⏳ Secret not yet visible - showing reveal guide")
                        self?.setupCoordinator.currentStep = .revealSecret

                        // Poll every second to check if secret becomes visible
                        self?.startPollingForSecret(webView)
                    }
                } else {
                    devLog("⚠️ Could not determine secret visibility")
                    self?.setupCoordinator.currentStep = .revealSecret
                    self?.startPollingForSecret(webView)
                }
            }
        }

        private func startPollingForSecret(_ webView: WKWebView) {
            // Poll every second for up to 30 seconds
            var attempts = 0
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                attempts += 1

                if attempts > 30 {
                    devLog("⏱️ Stopped polling for secret after 30 seconds")
                    timer.invalidate()
                    return
                }

                // Stop polling if we've moved past the reveal step
                if self?.setupCoordinator.currentStep != .revealSecret {
                    timer.invalidate()
                    return
                }

                devLog("🔄 Auto-checking for secret (attempt \(attempts))...")

                webView.evaluateJavaScript("""
                (function() {
                    const secretEl = document.querySelector('.MuiTypography-button');
                    return secretEl !== null && secretEl.textContent.trim().length > 0;
                })();
                """) { result, _ in
                    if let isVisible = result as? Bool, isVisible {
                        devLog("✅ Secret auto-detected! Starting clipboard monitoring")
                        timer.invalidate()
                        self?.setupCoordinator.currentStep = .copySecret
                        self?.setupCoordinator.startMonitoringClipboard()
                    }
                }
            }
        }
    }
}

// MARK: - TOTP Code Display (Simplified)

struct TOTPCodeDisplay: View {
    let secret: String
    @State private var code = "------"
    @State private var remainingSeconds = 30

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(code.enumerated()), id: \.offset) { _, char in
                    Text(String(char))
                        .font(.title.weight(.bold))
                        .foregroundStyle(Neo.accent)
                        .frame(width: 32)
                        .padding(.vertical, 8)
                        .background(Neo.inset, in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Text("\(remainingSeconds)s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .task {
            updateCode()
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                updateCode()
            }
        }
    }

    private func updateCode() {
        do {
            let generator = try TOTPGenerator(secret: secret)
            code = generator.generateCode()
            remainingSeconds = generator.remainingSeconds()
        } catch {
            code = "------"
        }
    }
}
