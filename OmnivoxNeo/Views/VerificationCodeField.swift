//
//  VerificationCodeField.swift
//  OmnivoxNeo
//
//  Native UITextField wrapper for proper one-time code AutoFill support
//

import SwiftUI

#if os(iOS)
import UIKit

struct VerificationCodeField: UIViewRepresentable {
    @Binding var text: String
    /// Two-way: UIKit owns the real first-responder state, so the field reports
    /// focus back up. A one-way flag goes stale the moment the user taps the
    /// field themselves, and the next keystroke resigns the keyboard.
    @Binding var isFocused: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()

        // Appearance
        textField.font = UIFont.monospacedSystemFont(ofSize: 22, weight: .semibold)
        textField.textAlignment = .center
        textField.placeholder = "000000"
        textField.backgroundColor = .clear

        // Input traits for one-time codes
        textField.keyboardType = .numberPad
        textField.textContentType = .oneTimeCode
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no

        // Enable AutoFill from notifications
        if #available(iOS 12.0, *) {
            textField.textContentType = .oneTimeCode
        }

        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textFieldDidChange(_:)),
            for: .editingChanged
        )

        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        // Refresh the coordinator's view so its bindings and onSubmit closure
        // never point at a stale copy.
        context.coordinator.parent = self

        // Only write the text when it actually differs: assigning unconditionally
        // moves the caret to the end on every re-render.
        if textField.text != text {
            textField.text = text
        }

        if isFocused, !textField.isFirstResponder {
            DispatchQueue.main.async {
                textField.becomeFirstResponder()
            }
        } else if !isFocused, textField.isFirstResponder {
            textField.resignFirstResponder()
        }
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: VerificationCodeField

        init(_ parent: VerificationCodeField) {
            self.parent = parent
        }

        @objc func textFieldDidChange(_ textField: UITextField) {
            let normalized = AppModel.normalizedVerificationCode(textField.text ?? "")
            if normalized != textField.text {
                textField.text = normalized
            }
            parent.text = normalized
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            guard !parent.isFocused else { return }
            // Deferred: SwiftUI forbids mutating state during a view update.
            DispatchQueue.main.async { [parent] in
                parent.isFocused = true
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            guard parent.isFocused else { return }
            DispatchQueue.main.async { [parent] in
                parent.isFocused = false
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let currentText = textField.text ?? ""
            guard let stringRange = Range(range, in: currentText) else { return false }
            let updatedText = currentText.replacingCharacters(in: stringRange, with: string)
            let normalized = AppModel.normalizedVerificationCode(updatedText)
            return normalized.count <= 6
        }
    }
}

#else

// macOS fallback - use standard TextField
struct VerificationCodeField: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    var onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        TextField("000000", text: $text)
            .font(.system(.title2, design: .monospaced, weight: .semibold))
            .multilineTextAlignment(.center)
            .textContentType(.oneTimeCode)
            .focused($focused)
            .onSubmit(onSubmit)
            .onAppear { focused = isFocused }
            .onChange(of: isFocused) { _, newValue in
                if focused != newValue { focused = newValue }
            }
            .onChange(of: focused) { _, newValue in
                if isFocused != newValue { isFocused = newValue }
            }
    }
}

#endif
