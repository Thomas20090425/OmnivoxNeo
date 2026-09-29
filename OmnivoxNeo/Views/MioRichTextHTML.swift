import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Turns what was typed into the HTML MIO stores.
///
/// Written by hand rather than handed to `NSAttributedString`'s own HTML
/// writer, which emits a stylesheet and a run of generated class names for
/// every message. What comes out here is the markup a person would have
/// written: `<b>`, `<i>`, `<ul><li>`, and a `style` only where something was
/// actually chosen. That matters because the other end of this is a teacher
/// reading it in MIO's web reader, or forwarding it somewhere else again.
enum RichTextHTML {
    #if canImport(UIKit)

    static func html(from text: NSAttributedString) -> String {
        guard text.length > 0 else { return "" }

        var blocks: [String] = []
        var openList: (kind: NeoListKind, items: [String])?

        func closeList() {
            guard let list = openList else { return }
            let tag = list.kind == .bullet ? "ul" : "ol"
            blocks.append("<\(tag)>" + list.items.map { "<li>\($0)</li>" }.joined() + "</\(tag)>")
            openList = nil
        }

        for paragraph in paragraphs(of: text) {
            let kindRaw = paragraph.length > 0
                ? paragraph.attribute(.neoListKind, at: 0, effectiveRange: nil) as? String
                : nil
            let kind = kindRaw.flatMap(NeoListKind.init(rawValue:))
            let inner = runs(in: stripMarker(paragraph))

            if let kind {
                if openList?.kind != kind { closeList(); openList = (kind, []) }
                openList?.items.append(inner.isEmpty ? "<br>" : inner)
                continue
            }

            closeList()
            blocks.append("<div\(paragraphStyle(of: paragraph))>\(inner.isEmpty ? "<br>" : inner)</div>")
        }
        closeList()
        return blocks.joined()
    }

    // MARK: - Pieces

    private static func paragraphs(of text: NSAttributedString) -> [NSAttributedString] {
        let string = text.string as NSString
        var result: [NSAttributedString] = []
        var index = 0
        while index < string.length {
            let range = string.paragraphRange(for: NSRange(location: index, length: 0))
            var content = range
            // The newline belongs to the break between paragraphs, not to one.
            if content.length > 0, string.substring(with: content).hasSuffix("\n") {
                content.length -= 1
            }
            result.append(text.attributedSubstring(from: content))
            index = NSMaxRange(range)
            if range.length == 0 { break }
        }
        if string.length == 0 { result.append(text) }
        return result
    }

    /// Drops the bullet or number, which is drawn as text so it can be seen
    /// and is the list tag's job on the way out.
    private static func stripMarker(_ paragraph: NSAttributedString) -> NSAttributedString {
        guard paragraph.length > 0 else { return paragraph }
        var effective = NSRange(location: 0, length: 0)
        guard paragraph.attribute(
            .neoListMarker,
            at: 0,
            longestEffectiveRange: &effective,
            in: NSRange(location: 0, length: paragraph.length)
        ) != nil else { return paragraph }
        let rest = NSRange(location: effective.length, length: paragraph.length - effective.length)
        return paragraph.attributedSubstring(from: rest)
    }

    private static func paragraphStyle(of paragraph: NSAttributedString) -> String {
        guard paragraph.length > 0,
              let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
        else { return "" }

        var rules: [String] = []
        switch style.alignment {
        case .center: rules.append("text-align:center")
        case .right: rules.append("text-align:right")
        case .justified: rules.append("text-align:justify")
        default: break
        }
        if style.headIndent > 1 {
            rules.append("margin-left:\(Int(style.headIndent))px")
        }
        return rules.isEmpty ? "" : " style=\"\(rules.joined(separator: ";"))\""
    }

    private static func runs(in paragraph: NSAttributedString) -> String {
        guard paragraph.length > 0 else { return "" }
        var out = ""
        paragraph.enumerateAttributes(
            in: NSRange(location: 0, length: paragraph.length),
            options: []
        ) { attributes, range, _ in
            let piece = (paragraph.string as NSString).substring(with: range)
            out += wrap(escape(piece), in: attributes)
        }
        return out
    }

    private static func wrap(_ text: String, in attributes: [NSAttributedString.Key: Any]) -> String {
        guard !text.isEmpty else { return "" }
        var inner = text

        let font = attributes[.font] as? UIFont
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        let offset = attributes[.baselineOffset] as? CGFloat ?? 0

        var rules: [String] = []
        if let colour = attributes[.foregroundColor] as? UIColor, colour != .label {
            rules.append("color:\(hex(colour))")
        }
        if let background = attributes[.backgroundColor] as? UIColor {
            rules.append("background-color:\(hex(background))")
        }
        // Only when it is not the reader's own body size, and not when the
        // size is small merely because this is a superscript.
        if let font, offset == 0, abs(font.pointSize - UIFont.preferredFont(forTextStyle: .body).pointSize) > 0.5 {
            rules.append("font-size:\(Int(font.pointSize))px")
        }
        if let family = font?.familyName,
           family != UIFont.preferredFont(forTextStyle: .body).familyName {
            rules.append("font-family:\(family)")
        }
        if !rules.isEmpty {
            inner = "<span style=\"\(rules.joined(separator: ";"))\">\(inner)</span>"
        }

        if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { inner = "<s>\(inner)</s>" }
        if (attributes[.underlineStyle] as? Int ?? 0) != 0 { inner = "<u>\(inner)</u>" }
        if traits.contains(.traitItalic) { inner = "<i>\(inner)</i>" }
        if traits.contains(.traitBold) { inner = "<b>\(inner)</b>" }
        if offset > 0 { inner = "<sup>\(inner)</sup>" }
        if offset < 0 { inner = "<sub>\(inner)</sub>" }
        return inner
    }

    private static func hex(_ colour: UIColor) -> String {
        // Resolved against light, because the other end has no idea what
        // appearance this was written in and a colour has to mean one thing.
        let resolved = colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }

    #endif

    /// The escaping is not decoration: a student writing "marks < 60" would
    /// otherwise lose the rest of the sentence to an unclosed tag.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\u{00A0}", with: "&nbsp;")
    }

    /// Plain text as HTML, for the platforms without the rich editor.
    static func html(fromPlain text: String) -> String {
        escape(text)
            .components(separatedBy: .newlines)
            .map { $0.isEmpty ? "<div><br></div>" : "<div>\($0)</div>" }
            .joined()
    }
}

#if canImport(UIKit)

// MARK: - The toolbar

/// MIO's six toolbars, as one row you can reach with a thumb.
///
/// The same operations, chosen down to the ones that mean something in a
/// message to a teacher: emphasis, lists, alignment, size and colour. What is
/// deliberately absent is MIO's symbol palette and emoticon grid — the system
/// keyboard has both, and better ones.
struct MioFormattingBar: View {
    @ObservedObject var controller: RichTextController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                button("bold", on: controller.isBold, label: "Bold") { controller.toggleBold() }
                button("italic", on: controller.isItalic, label: "Italic") { controller.toggleItalic() }
                button("underline", on: controller.isUnderlined, label: "Underline") {
                    controller.toggleUnderline()
                }
                button("strikethrough", on: controller.isStruckThrough, label: "Strikethrough") {
                    controller.toggleStrikethrough()
                }

                divider

                button("list.bullet", on: controller.listKind == .bullet, label: "Bullet List") {
                    controller.toggleList(.bullet)
                }
                button("list.number", on: controller.listKind == .ordered, label: "Numbered List") {
                    controller.toggleList(.ordered)
                }
                button("decrease.indent", on: false, label: "Outdent") { controller.indent(by: -22) }
                button("increase.indent", on: false, label: "Indent") { controller.indent(by: 22) }

                divider

                button("text.alignleft", on: controller.alignment == .left || controller.alignment == .natural,
                       label: "Align Left") { controller.setAlignment(.left) }
                button("text.aligncenter", on: controller.alignment == .center, label: "Align Centre") {
                    controller.setAlignment(.center)
                }
                button("text.alignright", on: controller.alignment == .right, label: "Align Right") {
                    controller.setAlignment(.right)
                }
                button("text.justify", on: controller.alignment == .justified, label: "Justify") {
                    controller.setAlignment(.justified)
                }

                divider

                sizeMenu
                colourMenu
                button("textformat.superscript", on: controller.isSuperscript, label: "Superscript") {
                    controller.toggleSuperscript()
                }
                button("textformat.subscript", on: controller.isSubscript, label: "Subscript") {
                    controller.toggleSubscript()
                }

                divider

                button("arrow.uturn.backward", on: false, label: "Undo") { controller.undo() }
                button("arrow.uturn.forward", on: false, label: "Redo") { controller.redo() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(.ultraThinMaterial)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 5)
            .accessibilityHidden(true)
    }

    private func button(
        _ symbol: String,
        on: Bool,
        label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(on ? Neo.accent : Color.primary)
                .frame(width: 34, height: 30)
                .background(
                    on ? Neo.accent.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var sizeMenu: some View {
        Menu {
            ForEach(RichTextController.sizes, id: \.self) { size in
                Button("\(Int(size)) pt") { controller.setSize(size) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "textformat.size")
                Text("\(Int(controller.pointSize))")
                    .monospacedDigit()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.primary)
            .frame(height: 30)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Text Size"))
    }

    private var colourMenu: some View {
        Menu {
            ForEach(Array(RichTextController.colours.enumerated()), id: \.offset) { _, choice in
                Button {
                    controller.setColour(choice.colour)
                } label: {
                    Label {
                        Text(choice.name)
                    } icon: {
                        // Drawn as an image rather than tinted with
                        // `foregroundStyle`: a menu re-tints its own symbols
                        // with the app's accent, so every swatch came out
                        // brown and "red", "green" and "blue" were the same
                        // dot three times.
                        Image(uiImage: RichTextController.swatch(choice.colour))
                    }
                }
            }
            Divider()
            Button("Remove Highlight") { controller.setHighlight(nil) }
            ForEach(Array(RichTextController.colours.dropFirst().enumerated()), id: \.offset) { _, choice in
                Button {
                    controller.setHighlight(choice.colour)
                } label: {
                    Label {
                        Text(choice.name)
                    } icon: {
                        Image(uiImage: RichTextController.swatch(choice.colour))
                    }
                }
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(controller.colour == .primary ? Color.primary : controller.colour)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Text Colour"))
    }
}

#endif
