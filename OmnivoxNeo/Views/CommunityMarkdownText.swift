import SwiftUI

/// A reported issue, rendered the way it was written.
///
/// What people type into the feedback form is Markdown, because that is what
/// GitHub stores and what they see when they read their own report back on
/// github.com. Shown as plain text instead, a report comes out as a wall of
/// asterisks and backticks — and a student comparing the two would reasonably
/// conclude the app had mangled it.
///
/// This is not a complete Markdown engine and is not trying to be. It covers
/// what turns up in a bug report — paragraphs, headings, bullet and numbered
/// lists, fenced code, quotes, and inline emphasis, code and links — and
/// renders anything it does not recognise as the plain text it already was.
/// Nothing here can fail into a blank screen.
struct CommunityMarkdownText: View {
    let markdown: String
    var font: Font = .callout

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(font)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

        case .bulleted(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: Text(verbatim: "•"), text: item)
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(marker: Text(verbatim: "\(index + 1)."), text: item)
                }
            }

        case .code(let text):
            // Horizontally scrollable rather than wrapped: a wrapped stack
            // trace or a wrapped line of Swift is harder to read than one you
            // have to push sideways, and wrapping invents line breaks that
            // were never in what they pasted.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Neo.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .quote(let text):
            Text(Self.inline(text))
                .font(font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Neo.separator)
                        .frame(width: 3)
                }

        case .rule:
            Divider()
        }
    }

    private func listRow(marker: Text, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            marker
                .font(font)
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .trailing)
            Text(Self.inline(text))
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    /// Bold, italic, `code` and links, within one line.
    ///
    /// `inlineOnlyPreservingWhitespace` because the block structure is handled
    /// above; letting the parser take the whole document would collapse the
    /// line breaks this view has already made decisions about. The failure
    /// policy returns whatever parsed, so an unbalanced asterisk in the middle
    /// of somebody's sentence costs that one span rather than the paragraph.
    static func inline(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)

        // Inline code gets the face it is asking for. SwiftUI does not apply
        // one for `inlinePresentationIntent`, so without this `nil` reads as
        // an ordinary word in the middle of a sentence.
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .callout.monospaced()
        }
        return attributed
    }

    /// The same text flattened to a couple of lines, for a row in a list.
    ///
    /// A list row has no room for structure, so the structure is thrown away
    /// rather than drawn: the markers go, the lines join up, and code blocks
    /// are dropped entirely — a stack trace is never the sentence that tells
    /// you what an issue is about. The inline emphasis survives, because that
    /// is the part that would otherwise show as punctuation.
    static func preview(_ markdown: String) -> AttributedString {
        let flattened = MarkdownBlock.parse(markdown).compactMap { block -> String? in
            switch block {
            case .paragraph(let text), .quote(let text):
                return text
            case .heading(_, let text):
                return text
            case .bulleted(let items), .numbered(let items):
                return items.joined(separator: " · ")
            case .code, .rule:
                return nil
            }
        }
        .joined(separator: " ")
        .replacingOccurrences(of: "\n", with: " ")

        // Two lines of a list row is perhaps 120 characters; parsing the rest
        // of a long report only to clip it is work nobody sees.
        return inline(String(flattened.prefix(300)))
    }
}

/// The block structure of a Markdown document, to the depth this app needs.
enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bulleted([String])
    case numbered([String])
    case code(String)
    case quote(String)
    case rule

    /// Splits text into blocks.
    ///
    /// A hand-rolled line scanner rather than a parser: the input is a bug
    /// report, the failure mode that matters is losing somebody's words, and
    /// every branch here falls through to "treat it as a paragraph".
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code. Everything up to the closing fence is taken
            // verbatim — no inline parsing, no trimming of indentation.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var body: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                index += 1  // the closing fence, or the end of the text
                let code = body.joined(separator: "\n")
                    .trimmingCharacters(in: .newlines)
                if !code.isEmpty { blocks.append(.code(code)) }
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // A horizontal rule, which is three or more of the same mark and
            // nothing else. Checked before headings so `---` is not read as
            // one.
            if trimmed.count >= 3,
               Set(trimmed).count == 1,
               let mark = trimmed.first,
               "-*_".contains(mark) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            // ATX heading: one to six hashes, then a space.
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flushParagraph()
                let text = String(trimmed.dropFirst(hashes))
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { blocks.append(.heading(level: hashes, text: text)) }
                index += 1
                continue
            }

            if let item = bulletContent(trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                      let next = bulletContent(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.bulleted(items))
                continue
            }

            if let item = numberContent(trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                      let next = numberContent(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoted.append(
                        String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    /// `- item`, `* item` or `+ item`, and the text after it.
    private static func bulletContent(_ line: String) -> String? {
        guard let mark = line.first, "-*+".contains(mark) else { return nil }
        let rest = line.dropFirst()
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// `1. item`, and the text after it.
    private static func numberContent(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        var rest = line.dropFirst(digits.count)
        guard rest.first == "." || rest.first == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
