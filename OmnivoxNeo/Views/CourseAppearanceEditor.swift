import SwiftUI

/// Lets a student choose what one of their courses looks like.
///
/// The app's guess is usually right, and when it is wrong it is wrong in a way
/// only the student can see — a course whose code means nothing here, or one
/// they simply think of as something else. Rather than adding more guessing,
/// this hands over the two things the guess produces: the symbol and the
/// colour. Either can be changed without the other, and either can be put back.
struct CourseAppearanceEditor: View {
    let code: String
    let title: String

    @ObservedObject private var personalization = Personalization.shared
    @Environment(\.dismiss) private var dismiss

    private var chosen: CourseAppearance {
        personalization.courseAppearance(for: code) ?? CourseAppearance()
    }

    private var identity: CourseIdentity {
        CourseIdentity.resolve(code: code, title: title, override: chosen)
    }

    /// What the app would have picked on its own, for the "Reset" comparison.
    private var automatic: CourseIdentity {
        CourseIdentity.resolve(code: code, title: title)
    }

    private let columns = [GridItem(.adaptive(minimum: 58, maximum: 78), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    preview
                    symbolSection
                    colourSection

                    if !chosen.isEmpty {
                        Button(role: .destructive) {
                            personalization.setCourseAppearance(CourseAppearance(), for: code)
                        } label: {
                            Label("Use the Suggested Look", systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: 620)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .background(NeoBackground())
            .navigationTitle(Text("Course Icon"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Pieces

    private var preview: some View {
        HStack(spacing: 14) {
            Image(systemName: identity.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(code)
                    .font(.caption.weight(.bold))
                    .monospaced()
                    .foregroundStyle(.white.opacity(0.92))
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(identity.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Preview"))
    }

    private var symbolSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Icon")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(CourseCatalog.symbols, id: \.self) { symbol in
                    let isChosen = identity.symbol == symbol
                    Button {
                        var next = chosen
                        // Tapping the one already in use puts the guess back,
                        // rather than making "no choice" unreachable.
                        next.symbol = (chosen.symbol == symbol) ? nil : symbol
                        personalization.setCourseAppearance(next, for: code)
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isChosen ? .white : identity.start)
                            .frame(width: 58, height: 58)
                            .background(
                                isChosen ? AnyShapeStyle(identity.start) : AnyShapeStyle(Neo.surface),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(symbol))
                    .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    private var colourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Colour")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(CourseCatalog.palettes) { palette in
                    let isChosen = chosen.paletteID == palette.id
                        || (chosen.paletteID == nil && automatic.start == palette.start)
                    Button {
                        var next = chosen
                        next.paletteID = (chosen.paletteID == palette.id) ? nil : palette.id
                        personalization.setCourseAppearance(next, for: code)
                    } label: {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(palette.gradient)
                            .frame(height: 58)
                            .overlay {
                                // A tick, not just a ring: the selected swatch
                                // has to be findable without comparing borders.
                                if isChosen {
                                    Image(systemName: "checkmark")
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(palette.id))
                    .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }
}
