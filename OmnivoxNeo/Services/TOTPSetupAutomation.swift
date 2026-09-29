//
//  TOTPSetupAutomation.swift
//  OmnivoxNeo
//
//  Automates TOTP authenticator registration with OmniVox
//

import Foundation
import WebKit

@MainActor
final class TOTPSetupAutomation {

    enum SetupError: Error {
        case navigationFailed
        case secretExtractionFailed
        case validationFailed
        case alreadyExists
        case userCancelled
    }

    enum SetupStep {
        case checkingExisting
        case deletingOld
        case navigatingToCreate
        case extractingSecret
        case validatingCode
        case completed
    }

    private let webView: WKWebView
    private let institution: Institution
    private let studentID: String
    private var currentStep: SetupStep = .checkingExisting
    private var extractedSecret: String?

    var onProgress: ((SetupStep) -> Void)?

    init(webView: WKWebView, institution: Institution, studentID: String) {
        self.webView = webView
        self.institution = institution
        self.studentID = studentID
    }

    /// Execute the full TOTP setup flow
    func execute() async throws -> String {
        // Step 1: Check if TOTP already exists
        currentStep = .checkingExisting
        onProgress?(.checkingExisting)

        let hasExisting = try await checkExistingTOTP()

        if hasExisting {
            // Ask user if they want to replace it
            throw SetupError.alreadyExists
        }

        // Step 2: Navigate to TOTP creation page
        currentStep = .navigatingToCreate
        onProgress?(.navigatingToCreate)

        try await navigateToTOTPCreate()

        // Step 3: Extract the secret
        currentStep = .extractingSecret
        onProgress?(.extractingSecret)

        let secret = try await extractTOTPSecret()
        self.extractedSecret = secret

        // Step 4: Generate and validate code
        currentStep = .validatingCode
        onProgress?(.validatingCode)

        try await validateTOTPCode(secret: secret)

        // Step 5: Complete
        currentStep = .completed
        onProgress?(.completed)

        return secret
    }

    /// Delete existing TOTP authenticator
    func deleteExistingTOTP() async throws {
        currentStep = .deletingOld
        onProgress?(.deletingOld)

        // Navigate to validation methods page
        let url = institution.baseURL.appendingPathComponent(institution.conventions.mfaSettingsPath)
        try await loadPage(url)

        // Find and click the TOTP menu button
        let clickMenuScript = """
        const items = Array.from(document.querySelectorAll('.MuiListItem-root'));
        const totpItem = items.find(item =>
            item.textContent.includes('Authentication application') ||
            item.textContent.includes('Application d\\'authentification')
        );

        if (!totpItem) return false;

        const menuButton = totpItem.querySelector('button[aria-haspopup="true"]');
        if (!menuButton) return false;

        menuButton.click();
        return true;
        """

        let menuClicked = try await executeScript(clickMenuScript) as? Bool
        guard menuClicked == true else {
            throw SetupError.navigationFailed
        }

        // Wait for menu to appear
        try await Task.sleep(for: .milliseconds(300))

        // Click delete in menu
        // Compared in lower case against the school's own vocabulary: the
        // portal styles these labels uppercase in CSS, so the text in the DOM
        // is whatever the page author typed and not what the student reads.
        let deleteLabels = institution.conventions.deleteAuthenticatorLabels
            .map { $0.lowercased() }
            .javascriptArrayLiteral

        let clickDeleteScript = """
        const labels = \(deleteLabels);
        const menuItems = Array.from(document.querySelectorAll('.MuiMenuItem-root'));
        const deleteItem = menuItems.find(item =>
            labels.some(label => (item.textContent || '').toLowerCase().includes(label))
        );

        if (!deleteItem) return false;
        deleteItem.click();
        return true;
        """

        let deleteClicked = try await executeScript(clickDeleteScript) as? Bool
        guard deleteClicked == true else {
            throw SetupError.navigationFailed
        }

        // Wait for confirmation dialog
        try await Task.sleep(for: .milliseconds(300))

        // Confirm deletion
        let confirmScript = """
        const labels = \(deleteLabels);
        // Scoped to the dialog when there is one. Searching the whole document
        // could otherwise find the delete control on the list behind the modal
        // and click that instead — on a screen whose every button destroys the
        // student's authenticator.
        const dialog = document.querySelector('[role="dialog"], .MuiDialog-root');
        const scope = dialog || document;
        const buttons = Array.from(scope.querySelectorAll('button'));
        const confirmButton = buttons.find(btn =>
            labels.some(label => (btn.textContent || '').toLowerCase().includes(label))
        );

        if (!confirmButton) return false;
        confirmButton.click();
        return true;
        """

        let confirmed = try await executeScript(confirmScript) as? Bool
        guard confirmed == true else {
            throw SetupError.navigationFailed
        }

        // Wait for deletion to complete
        try await Task.sleep(for: .milliseconds(500))
    }

    private func checkExistingTOTP() async throws -> Bool {
        let url = institution.baseURL.appendingPathComponent(institution.conventions.mfaSettingsPath)
        try await loadPage(url)

        // Wait for elements to appear
        let checkScript = """
        (function() {
            return new Promise((resolve) => {
                let attempts = 0;
                const maxAttempts = 20;

                const check = () => {
                    const items = document.querySelectorAll('.MuiListItem-root');
                    if (items.length > 0) {
                        const hasTotp = Array.from(items).some(item =>
                            item.textContent.includes('Authentication application') ||
                            item.textContent.includes('Application d\\'authentification')
                        );
                        resolve(hasTotp);
                    } else {
                        attempts++;
                        if (attempts >= maxAttempts) {
                            resolve(false);
                        } else {
                            setTimeout(check, 200);
                        }
                    }
                };

                check();
            });
        })();
        """

        return try await executeScript(checkScript) as? Bool ?? false
    }

    private func navigateToTOTPCreate() async throws {
        let url = institution.baseURL.appendingPathComponent(institution.conventions.totpCreatePath)
        try await loadPage(url)

        // Wait for and click "I cannot scan this code"
        let clickRevealScript = """
        (function() {
            return new Promise((resolve) => {
                let attempts = 0;
                const maxAttempts = 20;

                const tryClick = () => {
                    const link = Array.from(document.querySelectorAll('button, a')).find(el =>
                        el.textContent.includes('unable to scan') ||
                        el.textContent.includes('ne peux pas scanner') ||
                        el.textContent.includes('I am unable')
                    );

                    if (link) {
                        link.click();
                        resolve(true);
                    } else {
                        attempts++;
                        if (attempts >= maxAttempts) {
                            resolve(false);
                        } else {
                            setTimeout(tryClick, 200);
                        }
                    }
                };

                tryClick();
            });
        })();
        """

        let revealed = try await executeScript(clickRevealScript) as? Bool
        guard revealed == true else {
            throw SetupError.secretExtractionFailed
        }

        // Wait for secret to appear
        try await Task.sleep(for: .milliseconds(1000))
    }

    private func extractTOTPSecret() async throws -> String {
        let extractScript = """
        (function() {
            return new Promise((resolve) => {
                let attempts = 0;
                const maxAttempts = 20;

                const tryExtract = () => {
                    const secretElement = document.querySelector('\(institution.conventions.totpSecretSelector)');
                    if (secretElement && secretElement.textContent.trim()) {
                        resolve(secretElement.textContent.trim());
                    } else {
                        attempts++;
                        if (attempts >= maxAttempts) {
                            resolve(null);
                        } else {
                            setTimeout(tryExtract, 200);
                        }
                    }
                };

                tryExtract();
            });
        })();
        """

        guard let secret = try await executeScript(extractScript) as? String,
              !secret.isEmpty else {
            throw SetupError.secretExtractionFailed
        }

        return secret
    }

    private func validateTOTPCode(secret: String) async throws {
        // Generate current TOTP code
        let generator = try TOTPGenerator(secret: secret)
        let code = generator.generateCode()

        // Click "Following" button to proceed to validation
        let clickNextScript = """
        const buttons = Array.from(document.querySelectorAll('button'));
        const nextButton = buttons.find(btn =>
            btn.textContent.includes('Following') ||
            btn.textContent.includes('Suivant')
        );

        if (!nextButton) return false;
        nextButton.click();
        return true;
        """

        let clicked = try await executeScript(clickNextScript) as? Bool
        guard clicked == true else {
            throw SetupError.navigationFailed
        }

        // Wait for validation page
        try await Task.sleep(for: .milliseconds(500))

        // Enter the code
        let enterCodeScript = """
        const input = document.querySelector('input[maxlength="6"]');
        if (!input) return false;

        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
        if (setter) {
            setter.call(input, '\(code)');
        } else {
            input.value = '\(code)';
        }

        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
        """

        let entered = try await executeScript(enterCodeScript) as? Bool
        guard entered == true else {
            throw SetupError.validationFailed
        }

        // Click validate button
        let validateScript = """
        const buttons = Array.from(document.querySelectorAll('button'));
        const validateButton = buttons.find(btn =>
            btn.textContent.includes('To validate') ||
            btn.textContent.includes('Valider')
        );

        if (!validateButton) return false;
        validateButton.click();
        return true;
        """

        let validated = try await executeScript(validateScript) as? Bool
        guard validated == true else {
            throw SetupError.validationFailed
        }

        // Wait for validation to complete
        try await Task.sleep(for: .milliseconds(1000))
    }

    private func loadPage(_ url: URL) async throws {
        print("🔐 TOTP Setup: Loading page: \(url.absoluteString)")

        // Check cookies before navigating
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        print("🔐 TOTP Setup: Available cookies: \(cookies.count)")
        let sessionCookies = cookies.filter {
            $0.domain.contains(institution.conventions.portalDomainSuffix)
        }
        print("🔐 TOTP Setup: OmniVox cookies: \(sessionCookies.map { $0.name }.joined(separator: ", "))")

        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let request = URLRequest(url: url)

            // Create a navigation delegate to detect when page loads
            class LoadDelegate: NSObject, WKNavigationDelegate {
                let continuation: CheckedContinuation<Bool, Never>
                var hasResumed = false

                init(continuation: CheckedContinuation<Bool, Never>) {
                    self.continuation = continuation
                }

                func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                    print("🔐 TOTP Setup: Page loaded successfully: \(webView.url?.absoluteString ?? "unknown")")
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(returning: true)
                    }
                }

                func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
                    print("🔐 TOTP Setup: Page load failed: \(error.localizedDescription)")
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(returning: false)
                    }
                }

                func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
                    print("🔐 TOTP Setup: Provisional navigation failed: \(error.localizedDescription)")
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(returning: false)
                    }
                }
            }

            let delegate = LoadDelegate(continuation: continuation)
            objc_setAssociatedObject(webView, "tempDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.navigationDelegate = delegate
            webView.load(request)

            // Timeout after 10 seconds
            Task {
                try? await Task.sleep(for: .seconds(10))
                if !delegate.hasResumed {
                    delegate.hasResumed = true
                    continuation.resume(returning: false)
                }
            }
        }

        guard loaded else {
            throw SetupError.navigationFailed
        }

        // Give the page extra time to render React components
        try await Task.sleep(for: .milliseconds(1500))
    }

    private func executeScript(_ script: String) async throws -> Any? {
        do {
            return try await webView.evaluateJavaScript(script)
        } catch {
            print("❌ JavaScript execution failed: \(error.localizedDescription)")
            print("Script was: \(script.prefix(200))...")
            throw error
        }
    }
}

extension Institution {
    var baseURL: URL {
        URL(string: "https://\(host)")!
    }
}
