import Foundation

enum PortalVerificationScript {
    /// Run only in response to submitting the user's code, never during page
    /// inspection.
    ///
    /// Built from the school's conventions rather than held as a constant. The
    /// code field's selector in particular had drifted: this file matched
    /// `maxlength` in lower case while the conventions — and therefore the
    /// probe that decides the page is *readable* — accept both casings, so a
    /// portal build emitting `maxLength` produced a screen the app could read
    /// and could not submit.
    static func submit(_ conventions: PortalConventions) -> String {
        #"""
        const pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
        const initialURL = location.href;
        const codeInput = () => Array.from(
            document.querySelectorAll(\#(conventions.verificationCodeFieldSelector.javascriptStringLiteral))
        ).find(input => !input.disabled);
        const trustedCheckbox = () => {
            const pattern = new RegExp(\#(conventions.trustedDevicePattern.javascriptStringLiteral), 'i');
            return Array.from(document.querySelectorAll('input[type="checkbox"]')).find(input => {
                const labels = Array.from(input.labels || []);
                const labelledBy = (input.getAttribute('aria-labelledby') || '').split(/\s+/)
                    .map(id => document.getElementById(id)?.textContent || '').join(' ');
                const text = labels.map(label => label.textContent || '').join(' ')
                    + ' ' + (input.getAttribute('aria-label') || '') + ' ' + labelledBy;
                return pattern.test(text);
            });
        };

        // React may still be hydrating or replacing controls. Use timers because
        // requestAnimationFrame may be suspended in an offscreen WKWebView.
        for (let attempt = 0; attempt < 8; attempt++) {
            if (location.href !== initialURL) return false;
            const checkbox = trustedCheckbox();
            if (codeInput() && checkbox && !checkbox.disabled) break;
            await pause(100);
        }
        if (location.href !== initialURL) return false;

        const input = codeInput();
        if (!input) return false;
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
        if (setter) setter.call(input, code);
        else input.value = code;
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        await pause(100);

        // Use a real click to update React's state, then reacquire the element.
        // Never make the optional trust setting a prerequisite for verification.
        for (let attempt = 0; attempt < 2; attempt++) {
            if (location.href !== initialURL) return false;
            const checkbox = trustedCheckbox();
            if (!checkbox || checkbox.disabled || checkbox.checked) break;
            checkbox.click();
            await pause(120);
        }

        for (let attempt = 0; attempt < 8; attempt++) {
            if (location.href !== initialURL) return false;
            const buttons = Array.from(document.querySelectorAll('button'));
            const validatePattern = new RegExp(\#(conventions.validateButtonPattern.javascriptStringLiteral), 'i');
            const resendPattern = new RegExp(\#(conventions.resendCodePattern.javascriptStringLiteral), 'i');
            const validate = buttons.find(button =>
                validatePattern.test((button.textContent || '').trim())
            ) || buttons.find(button =>
                button.classList.contains('MuiButton-containedPrimary') &&
                !resendPattern.test(button.textContent || '')
            );
            if (validate && !validate.disabled && validate.getAttribute('aria-disabled') !== 'true') {
                validate.click();
                return true;
            }
            await pause(100);
        }
        return false;
        """#
    }
}
