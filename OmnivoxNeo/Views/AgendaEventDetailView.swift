import SwiftUI

/// One agenda entry, in full.
///
/// Mirrors what the portal shows when you tap an event — type, title, date,
/// time, place, description — with one addition: the links buried in the
/// description text become real, tappable destinations.
struct AgendaEventDetailView: View {
    let event: PortalCalendarEvent
    let institution: Institution

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var unsupportedLink: PortalLink?

    private var conventions: PortalConventions { institution.conventions }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = institution.timeZone
        return calendar
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heading
                    facts

                    if let detail = event.detail, !detail.isEmpty, detail != event.subtitle {
                        Divider()

                        Text(detail)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    linksSection
                    communitySection
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .background(NeoBackground())
            .navigationTitle("Event")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Not Supported Yet",
                isPresented: Binding(
                    get: { unsupportedLink != nil },
                    set: { if !$0 { unsupportedLink = nil } }
                )
            ) {
                Button("OK", role: .cancel) { unsupportedLink = nil }
            } message: {
                Text("This link opens a page inside OmniVox, which Omnivox Neo cannot show yet. Open it in a browser and sign in there for now.")
            }
        }
        .frame(minWidth: 340, minHeight: 400)
    }

    // MARK: - Sections

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: event.category.systemImage)
                    .font(.caption)

                event.category.label(conventions)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(event.category.tint)

            Text(event.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 12) {
            fact("calendar", AgendaFormat.fullDate(event.start, timeZone: institution.timeZone))
            fact("clock", timeText)

            if let location = event.location, !location.isEmpty {
                fact("mappin.and.ellipse", location)
            }

            if let subtitle = event.subtitle, subtitle != event.title {
                fact("book.closed", subtitle)
            }
        }
    }

    private func fact(_ symbol: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var linksSection: some View {
        if !event.links.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Links")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(Array(event.links.enumerated()), id: \.element.id) { offset, link in
                        if offset > 0 { Divider().padding(.leading, 44) }
                        LinkRow(
                            link: link,
                            domainSuffix: conventions.portalDomainSuffix,
                            onOpen: open
                        )
                    }
                }
                .neoCard()
            }
        }
    }

    @ViewBuilder
    private var communitySection: some View {
        if let community = event.community {
            VStack(alignment: .leading, spacing: 8) {
                Text("Posted By")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                LinkRow(
                    link: community,
                    domainSuffix: conventions.portalDomainSuffix,
                    onOpen: open
                )
                .neoCard()
            }
        }
    }

    // MARK: - Opening

    /// Anything pointing back into OmniVox needs a signed-in session, which
    /// Safari does not have — so it is stopped here with an explanation rather
    /// than handed over to land on a login wall. Everything else is the open
    /// web and goes to the browser, where the student can judge it themselves.
    private func open(_ link: PortalLink) {
        guard !link.isPortalInternal(domainSuffix: conventions.portalDomainSuffix) else {
            unsupportedLink = link
            return
        }
        openURL(link.url)
    }

    private var timeText: String {
        if event.isAllDay {
            guard let end = event.end else { return Loc.text("All day") }
            let lastMoment = end.addingTimeInterval(-1)
            guard !calendar.isDate(event.start, inSameDayAs: lastMoment) else {
                return Loc.text("All day")
            }
            let from = AgendaFormat.shortDate(event.start, timeZone: institution.timeZone)
            let to = AgendaFormat.shortDate(lastMoment, timeZone: institution.timeZone)
            return "\(from) – \(to)"
        }

        let start = AgendaFormat.time(event.start, timeZone: institution.timeZone)
        guard let end = event.end else { return start }
        return "\(start) – \(AgendaFormat.time(end, timeZone: institution.timeZone))"
    }
}

/// One link, and an honest statement of what tapping it will do.
private struct LinkRow: View {
    let link: PortalLink
    let domainSuffix: String
    let onOpen: (PortalLink) -> Void

    private var isPortalInternal: Bool {
        link.isPortalInternal(domainSuffix: domainSuffix)
    }

    var body: some View {
        Button {
            onOpen(link)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isPortalInternal ? "lock.fill" : "safari")
                    .font(.footnote)
                    .foregroundStyle(isPortalInternal ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Neo.accent))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(link.displayTitle)
                        .font(.subheadline)
                        // Accented and underlined: a link that looks like body
                        // text is a link nobody taps.
                        .foregroundStyle(isPortalInternal ? .secondary : Neo.accent)
                        .underline(!isPortalInternal)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // Resolved through `Loc` rather than left as a ternary
                    // inside `Text`: mixing a literal with a runtime host name
                    // makes the whole expression a `String`, which sends `Text`
                    // to its verbatim initializer and never translates.
                    Text(isPortalInternal
                        ? Loc.text("Opens in OmniVox · not supported yet")
                        : (link.url.host() ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if !isPortalInternal {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isPortalInternal ? "Not supported yet" : "Opens in your browser")
    }
}
