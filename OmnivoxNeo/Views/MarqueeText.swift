import SwiftUI

/// One line of text that walks itself along when it is too wide to fit.
///
/// For the few strings whose length is somebody's name. A greeting is the
/// first thing on the screen and it is addressed to the person reading it, so
/// truncating it — "Good Afternoon, Alexand…" — cuts off the one word that was
/// the point of the sentence. Everywhere else an ellipsis is the right answer
/// and this should not be used.
///
/// It only moves when it has to. Text that fits is laid out exactly as a plain
/// `Text` would be, with nothing animating behind it, and a phone set to
/// Reduce Motion gets that version too: a title that never stops moving at the
/// top of the screen is precisely what that setting is asking not to have.
struct MarqueeText: View {
    let text: String

    /// How fast it walks, in points per second. Slow enough to read at a
    /// glance rather than to chase.
    var speed: Double = 34
    /// How long it waits at the beginning — where the greeting is — before
    /// setting off, and again when it gets back.
    var restAtStart: Double = 2.5
    /// A shorter pause at the far end, which is only the tail of a name.
    var restAtEnd: Double = 1.2

    @State private var textSize: CGSize = .zero
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A `GeometryReader` rather than a measured `frame`, and the reason is
        // the whole of why the first attempt sat still.
        //
        // `fixedSize` is what stops the text truncating — it makes it take its
        // full width and hang off the end, which is the thing there is to
        // scroll. But that width then propagates *upward*: the stack around it
        // grew to the width of the name, so the "available" width measured the
        // same as the text, the overflow came out as zero, and it decided it
        // fitted. It also pushed the whole column out of its own padding,
        // which is why the greeting began at the very edge of the screen.
        //
        // A `GeometryReader` takes the width it is offered and reports nothing
        // back up, so the two measurements stay independent.
        GeometryReader { proxy in
            let available = proxy.size.width
            let overflow = max(0, textSize.width - available)
            let travel = max(0.01, Double(overflow) / speed)

            Text(text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { textSize = $0 }
                .offset(x: offset)
                .frame(width: available, alignment: .leading)
                .clipped()
                // The whole line is one thing to VoiceOver, which reads it in
                // full and never had the problem this solves.
                .accessibilityElement()
                .accessibilityLabel(Text(text))
                // Restarted whenever the sentence or the room for it changes —
                // a rotation, a different name, a new time of day.
                .task(id: MarqueeKey(text: text, overflow: overflow)) {
                    offset = 0
                    guard !reduceMotion, overflow > 1 else { return }

                    while !Task.isCancelled {
                        // Sit at the greeting long enough to be read as one.
                        try? await Task.sleep(for: .seconds(restAtStart))
                        guard !Task.isCancelled else { return }

                        withAnimation(.linear(duration: travel)) { offset = -overflow }
                        try? await Task.sleep(for: .seconds(travel + restAtEnd))
                        guard !Task.isCancelled else { return }

                        withAnimation(.linear(duration: travel)) { offset = 0 }
                        try? await Task.sleep(for: .seconds(travel))
                    }
                }
        }
        // The reader has no height of its own, so it borrows the text's.
        .frame(height: textSize.height)
    }
}

/// What a change of has to restart the walk.
private struct MarqueeKey: Equatable {
    let text: String
    let overflow: CGFloat
}
