import Combine
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Writing a message with formatting, and turning it into the HTML MIO keeps.
///
/// MIO's own editor is a Telerik control with six toolbars, and on a phone it
/// is unusable — a 2009 desktop widget in an iframe in a frameset. But what it
/// *offers* is not unreasonable for writing to a teacher: bold for the thing
/// that matters, a list for three questions, a colour for a correction. So the
/// features are kept and the control is not.
///
/// The output is deliberately plain HTML — `<b>`, `<li>`, `<div style="…">` —
/// rather than what `NSAttributedString`'s own HTML writer produces, which is a
/// stylesheet and a hundred generated class names. A teacher opening this in
/// MIO's web reader should see what was written, and so should the next person
/// who forwards it somewhere else.

// MARK: - Paragraph kinds

extension NSAttributedString.Key {
    /// "This paragraph is an item in a list", and which sort.
    static let neoListKind = NSAttributedString.Key("neoListKind")
    /// The bullet or number at the front of such a paragraph, which is real
    /// text — so it can be seen and measured — and is dropped on the way out.
    static let neoListMarker = NSAttributedString.Key("neoListMarker")
}

enum NeoListKind: String {
    case bullet
    case ordered
}

#if canImport(UIKit)

// MARK: - The editor

/// A text view that can be formatted, with the commands exposed to SwiftUI.
struct MioRichTextEditor: UIViewRepresentable {
    @Binding var text: NSAttributedString
    @ObservedObject var controller: RichTextController
    var placeholder: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        view.textContainer.lineFragmentPadding = 0
        view.font = RichTextController.defaultFont
        view.textColor = .label
        view.alwaysBounceVertical = true
        view.adjustsFontForContentSizeCategory = true
        view.typingAttributes = RichTextController.defaultAttributes
        view.attributedText = text

        // The placeholder is a label rather than a fake first line, so it can
        // never be typed over, selected, or sent by accident.
        let hint = UILabel()
        hint.text = placeholder
        hint.font = RichTextController.defaultFont
        hint.textColor = .tertiaryLabel
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12)
        ])
        context.coordinator.placeholder = hint
        hint.isHidden = !text.string.isEmpty

        controller.attach(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        controller.attach(view)
        context.coordinator.placeholder?.isHidden = !text.string.isEmpty

        // Only when the text came from somewhere other than this view.
        //
        // Assigning `attributedText` wipes `typingAttributes`, and SwiftUI runs
        // this again every time the controller publishes — which is after every
        // press of Bold. So pressing Bold set the attribute and then had it
        // erased a frame later, and nothing anybody typed came out bold. While
        // the view is being edited it is the source of truth; the binding only
        // fills it in beforehand, when a draft is opened.
        guard !view.isFirstResponder else { return }
        if view.attributedText != text {
            let selection = view.selectedRange
            view.attributedText = text
            view.selectedRange = NSRange(
                location: min(selection.location, text.length),
                length: 0
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, controller: controller)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<NSAttributedString>
        private let controller: RichTextController
        weak var placeholder: UILabel?

        init(text: Binding<NSAttributedString>, controller: RichTextController) {
            self.text = text
            self.controller = controller
        }

        func textViewDidChange(_ textView: UITextView) {
            // UITextView copies the attributes of the character before the
            // cursor onto whatever is typed next. Left alone, that means
            // everything typed after a bullet is *also* marked as the bullet —
            // and the marker is stripped on the way out, so the message would
            // arrive with the text of every list item missing.
            if textView.typingAttributes[.neoListMarker] != nil {
                textView.typingAttributes.removeValue(forKey: .neoListMarker)
            }
            controller.reapplyTypingOverride(to: textView, textChanged: true)
            text.wrappedValue = textView.attributedText ?? NSAttributedString(string: "")
            placeholder?.isHidden = !textView.text.isEmpty
            controller.readState(from: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            controller.reapplyTypingOverride(to: textView, textChanged: false)
            controller.readState(from: textView)
        }

        /// Return inside a list carries the list on, the way every editor does.
        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard replacement == "\n" else { return true }
            guard let kind = controller.listKind(at: range.location, in: textView) else { return true }
            controller.continueList(kind, at: range, in: textView)
            text.wrappedValue = textView.attributedText ?? NSAttributedString(string: "")
            placeholder?.isHidden = !textView.text.isEmpty
            return false
        }
    }
}

// MARK: - The commands

/// Everything the toolbar can do, and what is currently true at the cursor.
///
/// A separate object rather than methods on the view because the toolbar lives
/// outside it: the buttons have to reach the text view, and the text view has
/// to be able to tell the buttons which of them are lit.
@MainActor
final class RichTextController: ObservableObject {
    /// Which marks apply where the cursor is, so the buttons can show it.
    @Published private(set) var isBold = false
    @Published private(set) var isItalic = false
    @Published private(set) var isUnderlined = false
    @Published private(set) var isStruckThrough = false
    @Published private(set) var isSuperscript = false
    @Published private(set) var isSubscript = false
    @Published private(set) var alignment: NSTextAlignment = .natural
    @Published private(set) var listKind: NeoListKind?
    @Published private(set) var pointSize: CGFloat = RichTextController.defaultFont.pointSize
    @Published private(set) var colour: Color = .primary

    private weak var textView: UITextView?

    /// What the toolbar last chose, held until the cursor is moved by hand.
    ///
    /// `UITextView` rebuilds `typingAttributes` from the character before the
    /// cursor after every insertion, so a choice made in the toolbar survived
    /// exactly one keystroke — turn a highlight off, type, and it came back.
    /// This is re-applied for as long as the student is still typing.
    private var typingOverride: [NSAttributedString.Key: Any]?
    private var lastLength = 0

    static var defaultFont: UIFont { UIFont.preferredFont(forTextStyle: .body) }

    static var defaultAttributes: [NSAttributedString.Key: Any] {
        [.font: defaultFont, .foregroundColor: UIColor.label]
    }

    func attach(_ view: UITextView) {
        textView = view
    }

    /// A filled dot in an actual colour, kept as an image so a menu cannot
    /// re-tint it with the app's accent.
    static func swatch(_ colour: Color) -> UIImage {
        let side: CGFloat = 16
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            let resolved = colour == .primary ? UIColor.label : UIColor(colour)
            resolved.setFill()
            context.cgContext.fillEllipse(
                in: CGRect(x: 1, y: 1, width: side - 2, height: side - 2)
            )
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// The sizes offered. MIO's own list is in pixels; these are the text
    /// sizes that actually mean something beside the reader's chosen one.
    static let sizes: [CGFloat] = [12, 14, 16, 18, 22, 28, 34]

    static let colours: [(name: LocalizedStringKey, colour: Color)] = [
        ("Black", .primary),
        ("Red", .red),
        ("Orange", .orange),
        ("Green", .green),
        ("Blue", .blue),
        ("Purple", .purple)
    ]

    // MARK: Reading the cursor

    /// Puts the toolbar's last choice back after a keystroke, and forgets it
    /// once the cursor has been moved somewhere else on purpose.
    func reapplyTypingOverride(to view: UITextView, textChanged: Bool) {
        guard let typingOverride else {
            lastLength = view.attributedText.length
            return
        }
        if textChanged {
            view.typingAttributes = typingOverride
        } else if view.attributedText.length == lastLength {
            // The selection moved without the text changing: the cursor was
            // put somewhere by hand, and the choice was about where it was.
            self.typingOverride = nil
        }
        lastLength = view.attributedText.length
    }

    func readState(from view: UITextView) {
        let attributes: [NSAttributedString.Key: Any]
        if view.selectedRange.length > 0 {
            attributes = view.attributedText.attributes(at: view.selectedRange.location, effectiveRange: nil)
        } else {
            attributes = view.typingAttributes
        }

        let font = attributes[.font] as? UIFont ?? Self.defaultFont
        isBold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
        isItalic = font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        pointSize = font.pointSize
        isUnderlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
        isStruckThrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        let offset = attributes[.baselineOffset] as? CGFloat ?? 0
        isSuperscript = offset > 0
        isSubscript = offset < 0
        let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
        alignment = paragraph?.alignment ?? .natural
        if let raw = attributes[.neoListKind] as? String {
            listKind = NeoListKind(rawValue: raw)
        } else {
            listKind = nil
        }
        if let colour = attributes[.foregroundColor] as? UIColor, colour != .label {
            self.colour = Color(uiColor: colour)
        } else {
            self.colour = .primary
        }
    }

    // MARK: Character marks

    func toggleBold() { toggleTrait(.traitBold) }
    func toggleItalic() { toggleTrait(.traitItalic) }

    func toggleUnderline() {
        toggleNumber(.underlineStyle, on: NSUnderlineStyle.single.rawValue)
    }

    func toggleStrikethrough() {
        toggleNumber(.strikethroughStyle, on: NSUnderlineStyle.single.rawValue)
    }

    func toggleSuperscript() { toggleBaseline(up: true) }
    func toggleSubscript() { toggleBaseline(up: false) }

    func setSize(_ size: CGFloat) {
        applyToFont { font in
            UIFont(descriptor: font.fontDescriptor, size: size)
        }
    }

    func setColour(_ colour: Color) {
        let resolved = colour == .primary ? UIColor.label : UIColor(colour)
        apply { attributes in
            attributes[.foregroundColor] = resolved
        }
    }

    func setHighlight(_ colour: Color?) {
        apply { attributes in
            if let colour {
                attributes[.backgroundColor] = UIColor(colour).withAlphaComponent(0.3)
            } else {
                attributes[.backgroundColor] = nil
            }
        }
    }

    // MARK: Paragraph shape

    func setAlignment(_ alignment: NSTextAlignment) {
        applyToParagraphs { style in
            style.alignment = alignment
        }
    }

    func indent(by amount: CGFloat) {
        applyToParagraphs { style in
            let next = max(0, style.headIndent + amount)
            style.headIndent = next
            style.firstLineHeadIndent = next
        }
    }

    func undo() { textView?.undoManager?.undo() }
    func redo() { textView?.undoManager?.redo() }

    // MARK: Lists

    func listKind(at location: Int, in view: UITextView) -> NeoListKind? {
        let text = view.attributedText ?? NSAttributedString(string: "")
        guard text.length > 0 else { return nil }
        let index = min(max(0, location - 1), text.length - 1)
        guard let raw = text.attribute(.neoListKind, at: index, effectiveRange: nil) as? String else {
            return nil
        }
        return NeoListKind(rawValue: raw)
    }

    /// Turns the paragraphs under the selection into a list, or back again.
    func toggleList(_ kind: NeoListKind) {
        guard let view = textView else { return }
        let storage = view.textStorage
        let selection = view.selectedRange

        let ranges = paragraphRanges(in: storage, covering: selection)
        // Read the attribute only where there is a character to read it from.
        // A cursor sitting after the final newline is a real paragraph with a
        // location of exactly `length`, and asking for an attribute there is
        // out of bounds — which is a crash, not an empty answer.
        let alreadyThisKind = !ranges.isEmpty && ranges.allSatisfy { range in
            guard range.location < storage.length else { return false }
            return (storage.attribute(.neoListKind, at: range.location, effectiveRange: nil) as? String)
                == kind.rawValue
        }

        storage.beginEditing()
        // Backwards, so taking a marker off never moves a range still to come.
        for range in ranges.reversed() {
            stripMarker(in: storage, paragraph: range)
        }
        storage.endEditing()

        var cursor = min(selection.location, storage.length)
        var typing = Self.defaultAttributes

        if !alreadyThisKind {
            let target = paragraphRanges(
                in: storage,
                covering: NSRange(location: cursor, length: 0)
            )
            let style = NSMutableParagraphStyle()
            style.headIndent = 22
            style.firstLineHeadIndent = 0
            typing[.neoListKind] = kind.rawValue
            typing[.paragraphStyle] = style

            storage.beginEditing()
            var shift = 0
            var number = 1
            // Forwards, tracking how far everything after each insertion has
            // moved — including the cursor, which otherwise ends up *before*
            // the bullet and everything typed next goes in front of it.
            for range in target {
                let moved = NSRange(location: range.location + shift, length: range.length)
                let added = insertMarker(kind, number: number, in: storage, paragraph: moved)
                if moved.location <= cursor + shift { cursor += added }
                shift += added
                number += 1
            }
            storage.endEditing()
        }

        view.selectedRange = NSRange(location: min(cursor, storage.length), length: 0)
        view.typingAttributes = typing
        readState(from: view)
    }

    /// Pressing Return inside a list: a new item, or the end of the list when
    /// the current item is empty — which is how everyone expects to get out.
    func continueList(_ kind: NeoListKind, at range: NSRange, in view: UITextView) {
        let storage = view.textStorage
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
        let markerLength = markerLength(in: storage, paragraph: paragraph)
        let contentLength = max(0, paragraph.length - markerLength)
            - ((storage.string as NSString).substring(with: paragraph).hasSuffix("\n") ? 1 : 0)

        storage.beginEditing()
        if contentLength <= 0 {
            // An empty item: take the marker off and leave the list.
            stripMarker(in: storage, paragraph: paragraph)
            storage.endEditing()
            view.selectedRange = NSRange(location: paragraph.location, length: 0)
            view.typingAttributes = Self.defaultAttributes
            readState(from: view)
            return
        }

        let number = nextNumber(in: storage, before: paragraph)
        let marker = Self.markerText(kind, number: number)
        var attributes = Self.defaultAttributes
        attributes[.neoListKind] = kind.rawValue
        let style = NSMutableParagraphStyle()
        style.headIndent = 22
        style.firstLineHeadIndent = 0
        attributes[.paragraphStyle] = style

        var markerAttributes = attributes
        markerAttributes[.neoListMarker] = true

        let inserted = NSMutableAttributedString(string: "\n", attributes: attributes)
        inserted.append(NSAttributedString(string: marker, attributes: markerAttributes))
        storage.replaceCharacters(in: range, with: inserted)
        storage.endEditing()

        view.selectedRange = NSRange(location: range.location + inserted.length, length: 0)
        view.typingAttributes = attributes
        readState(from: view)
    }

    // MARK: - Plumbing

    private func paragraphRanges(in storage: NSTextStorage, covering range: NSRange) -> [NSRange] {
        let string = storage.string as NSString
        guard string.length > 0 else { return [NSRange(location: 0, length: 0)] }
        let clamped = NSRange(
            location: min(range.location, string.length),
            length: min(range.length, string.length - min(range.location, string.length))
        )
        var ranges: [NSRange] = []
        var index = clamped.location
        repeat {
            let paragraph = string.paragraphRange(for: NSRange(location: index, length: 0))
            ranges.append(paragraph)
            index = NSMaxRange(paragraph)
        } while index < NSMaxRange(clamped)
        return ranges
    }

    private func markerLength(in storage: NSTextStorage, paragraph: NSRange) -> Int {
        guard paragraph.length > 0,
              paragraph.location < storage.length,
              NSMaxRange(paragraph) <= storage.length
        else { return 0 }
        var effective = NSRange(location: 0, length: 0)
        guard storage.attribute(
            .neoListMarker,
            at: paragraph.location,
            longestEffectiveRange: &effective,
            in: paragraph
        ) != nil else { return 0 }
        return effective.length
    }

    private func stripMarker(in storage: NSTextStorage, paragraph: NSRange) {
        let length = markerLength(in: storage, paragraph: paragraph)
        if length > 0 {
            storage.replaceCharacters(in: NSRange(location: paragraph.location, length: length), with: "")
        }
        guard storage.length > 0 else { return }
        let remaining = (storage.string as NSString)
            .paragraphRange(for: NSRange(location: min(paragraph.location, storage.length - 1), length: 0))
        guard remaining.length > 0, NSMaxRange(remaining) <= storage.length else { return }
        storage.removeAttribute(.neoListKind, range: remaining)
        storage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: remaining)
    }

    /// Puts the bullet or number on, and says how many characters that added.
    @discardableResult
    private func insertMarker(
        _ kind: NeoListKind,
        number: Int,
        in storage: NSTextStorage,
        paragraph: NSRange
    ) -> Int {
        let style = NSMutableParagraphStyle()
        style.headIndent = 22
        style.firstLineHeadIndent = 0

        var attributes = Self.defaultAttributes
        attributes[.neoListKind] = kind.rawValue
        attributes[.paragraphStyle] = style
        var markerAttributes = attributes
        markerAttributes[.neoListMarker] = true

        guard paragraph.location <= storage.length else { return 0 }
        let marker = NSAttributedString(
            string: Self.markerText(kind, number: number),
            attributes: markerAttributes
        )
        storage.insert(marker, at: paragraph.location)
        let available = storage.length - paragraph.location
        guard available > 0 else { return marker.length }
        let grown = NSRange(
            location: paragraph.location,
            length: min(paragraph.length + marker.length, available)
        )
        storage.addAttributes(
            [.neoListKind: kind.rawValue, .paragraphStyle: style],
            range: grown
        )
        return marker.length
    }

    /// The number the next item in this list should carry.
    private func nextNumber(in storage: NSTextStorage, before paragraph: NSRange) -> Int {
        let text = (storage.string as NSString).substring(with: paragraph)
        var digits = ""
        for character in text {
            if character.isNumber { digits.append(character) } else { break }
        }
        return (Int(digits) ?? 0) + 1
    }

    private static func markerText(_ kind: NeoListKind, number: Int) -> String {
        switch kind {
        case .bullet: "•\u{00A0}"
        case .ordered: "\(number).\u{00A0}"
        }
    }

    private func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        applyToFont { font in
            var traits = font.fontDescriptor.symbolicTraits
            if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
    }

    private func toggleNumber(_ key: NSAttributedString.Key, on value: Int) {
        apply { attributes in
            let current = attributes[key] as? Int ?? 0
            attributes[key] = current == 0 ? value : 0
        }
    }

    private func toggleBaseline(up: Bool) {
        apply { attributes in
            let current = attributes[.baselineOffset] as? CGFloat ?? 0
            let wanted: CGFloat = up ? 6 : -4
            let font = attributes[.font] as? UIFont ?? Self.defaultFont
            if current == wanted {
                attributes[.baselineOffset] = 0
                attributes[.font] = UIFont(descriptor: font.fontDescriptor, size: Self.defaultFont.pointSize)
            } else {
                attributes[.baselineOffset] = wanted
                attributes[.font] = UIFont(
                    descriptor: font.fontDescriptor,
                    size: Self.defaultFont.pointSize * 0.72
                )
            }
        }
    }

    private func applyToFont(_ change: (UIFont) -> UIFont) {
        apply { attributes in
            let font = attributes[.font] as? UIFont ?? Self.defaultFont
            attributes[.font] = change(font)
        }
    }

    /// Applies to the selection, or to what is typed next when there isn't one.
    private func apply(_ change: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let view = textView else { return }
        let selection = view.selectedRange

        if selection.length == 0 {
            var attributes = view.typingAttributes
            change(&attributes)
            attributes.removeValue(forKey: .neoListMarker)
            view.typingAttributes = attributes
            typingOverride = attributes
            lastLength = view.attributedText.length
            readState(from: view)
            return
        }

        let storage = view.textStorage
        storage.beginEditing()
        storage.enumerateAttributes(in: selection, options: []) { attributes, range, _ in
            var copy = attributes
            change(&copy)
            storage.setAttributes(copy, range: range)
        }
        storage.endEditing()
        view.selectedRange = selection
        readState(from: view)
    }

    private func applyToParagraphs(_ change: (NSMutableParagraphStyle) -> Void) {
        guard let view = textView else { return }
        let storage = view.textStorage
        let ranges = paragraphRanges(in: storage, covering: view.selectedRange)
        let selection = view.selectedRange

        storage.beginEditing()
        for range in ranges where range.length > 0 {
            let existing = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle
            let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            change(style)
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        storage.endEditing()
        view.selectedRange = selection

        var typing = view.typingAttributes
        let style = (typing[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        change(style)
        typing[.paragraphStyle] = style
        view.typingAttributes = typing
        readState(from: view)
    }
}

#endif
