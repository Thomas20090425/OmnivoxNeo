import AppKit
import Foundation
import WebKit

// Run from the repository root:
// xcrun swiftc OmnivoxNeo/Services/PortalVerificationScript.swift Tests/VerificationRegression.swift \
//   -framework AppKit -framework WebKit -o /tmp/omnivox-verification-regression
// /tmp/omnivox-verification-regression
// Every page is synthetic and uses a nonpersistent WebKit store. No credentials
// or network requests are used.

@MainActor
private final class VerificationRegression: NSObject, WKNavigationDelegate {
    private struct Scenario {
        let name: String
        let controls: String
        var setup = ""
        var expectedTrust: Bool? = true
        var expectedTrustClicks = 1
        var expectedSubmission = true
    }

    private let webView: WKWebView
    private var navigation: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func run() async -> Int32 {
        let scenarios: [Scenario] = [
            Scenario(
                name: "English trust is checked before Validate",
                controls: "<label><input id='trust' type='checkbox'>Trusted device</label><button id='validate'>Validate</button>"
            ),
            Scenario(
                name: "Optional checkbox absent still submits",
                controls: "<button id='validate'>Validate</button>",
                expectedTrust: nil,
                expectedTrustClicks: 0
            ),
            Scenario(
                name: "Already trusted checkbox is never toggled",
                controls: "<input id='trust' type='checkbox' checked><label for='trust'>Trusted device</label><button id='validate'>Validate</button>",
                expectedTrustClicks: 0
            ),
            Scenario(
                name: "Delayed checkbox and disabled Validate recover",
                controls: "<span id='deferred'></span><button id='validate' disabled>Validate</button>",
                setup: """
                setTimeout(() => {
                    document.getElementById('deferred').innerHTML = '<label><input id="trust" type="checkbox" disabled>Trusted device</label>';
                }, 250);
                setTimeout(() => { document.getElementById('trust').disabled = false; }, 450);
                setTimeout(() => { document.getElementById('validate').disabled = false; }, 1000);
                """
            ),
            Scenario(
                name: "Unrelated checkbox remains untouched",
                controls: "<h1>Trusted device</h1><label><input id='unrelated' type='checkbox'>Email me updates</label><button id='validate'>Validate</button>",
                expectedTrust: nil,
                expectedTrustClicks: 0
            ),
            Scenario(
                name: "French trust label and Valider work",
                controls: "<label><input id='trust' type='checkbox'>Cet appareil est un appareil de confiance</label><button id='validate'>Valider</button>"
            ),
            Scenario(
                name: "Accessible trust label is recognized",
                controls: "<span id='trust-label'>Trusted device</span><input id='trust' type='checkbox' aria-labelledby='trust-label'><button id='validate'>Validate</button>"
            ),
            Scenario(
                name: "Permanently disabled Validate is not clicked",
                controls: "<label><input id='trust' type='checkbox'>Trusted device</label><button id='validate' disabled>Validate</button>",
                expectedSubmission: false
            )
        ]

        var failures = 0
        for scenario in scenarios {
            do {
                try await exercise(scenario)
                print("PASS: \(scenario.name)")
            } catch {
                failures += 1
                print("FAIL: \(scenario.name): \(error.localizedDescription)")
            }
        }
        print("\(scenarios.count - failures)/\(scenarios.count) WebKit verification scenarios passed.")
        return failures == 0 ? 0 : 1
    }

    private func exercise(_ scenario: Scenario) async throws {
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'">
        </head><body>
        <input id="code" maxlength="6" autocomplete="one-time-code">
        \(scenario.controls)
        <script>
        window.observed = {
            validations: 0, trustClicks: 0, unrelatedClicks: 0,
            codeAtValidation: null, trustAtValidation: null,
            inputEvents: 0, changeEvents: 0, events: []
        };
        document.addEventListener('click', event => {
            const node = event.target;
            if (node.id === 'trust') {
                observed.trustClicks++;
                observed.events.push('trust:' + node.checked);
            }
            if (node.id === 'unrelated') observed.unrelatedClicks++;
            if (node.id === 'validate') {
                observed.validations++;
                observed.codeAtValidation = document.getElementById('code').value;
                observed.trustAtValidation = document.getElementById('trust')?.checked ?? null;
                observed.events.push('validate');
            }
        });
        document.getElementById('code').addEventListener('input', () => { observed.inputEvents++; });
        document.getElementById('code').addEventListener('change', () => { observed.changeEvents++; });
        \(scenario.setup)
        </script></body></html>
        """

        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        let result = try await webView.callAsyncJavaScript(
            PortalVerificationScript.submit,
            arguments: ["code": "012345"],
            in: nil,
            contentWorld: .page
        )
        // Observe briefly after completion to catch any delayed duplicate click.
        try await Task.sleep(for: .milliseconds(200))
        let raw = try await webView.callAsyncJavaScript(
            """
            return JSON.stringify({
                ...observed,
                finalCode: document.getElementById('code').value,
                finalTrust: document.getElementById('trust')?.checked ?? null,
                finalUnrelated: document.getElementById('unrelated')?.checked ?? null
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw failure("Could not inspect the fixture after submission")
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw failure("\(message); observed \(json)") }
        }

        try require(result as? Bool == scenario.expectedSubmission, "Unexpected submission result")
        try require(state["validations"] as? Int == (scenario.expectedSubmission ? 1 : 0), "Validate click count was incorrect")
        try require(state["trustClicks"] as? Int == scenario.expectedTrustClicks, "Trust checkbox toggled incorrectly")
        try require(state["unrelatedClicks"] as? Int == 0, "Unrelated checkbox was clicked")
        try require(state["finalUnrelated"] as? Bool != true, "Unrelated checkbox was selected")
        try require(state["finalCode"] as? String == "012345", "Leading-zero code changed")
        try require(state["inputEvents"] as? Int == 1, "Input event did not fire exactly once")
        try require(state["changeEvents"] as? Int == 1, "Change event did not fire exactly once")
        try require(state["finalTrust"] as? Bool == scenario.expectedTrust, "Final trust state was incorrect")
        if scenario.expectedSubmission {
            try require(state["codeAtValidation"] as? String == "012345", "Validate did not receive the intact code")
            try require(state["trustAtValidation"] as? Bool == scenario.expectedTrust, "Trust was not selected before Validate")
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "VerificationRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation?.resume()
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: error)
        self.navigation = nil
    }
}

@main
private struct RegressionMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let runner = VerificationRegression()
        Task { @MainActor in
            exit(await runner.run())
        }
        application.run()
    }
}
