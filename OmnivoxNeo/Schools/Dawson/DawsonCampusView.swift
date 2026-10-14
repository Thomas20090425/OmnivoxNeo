import SwiftUI

/// Dawson-only: makes sense of the room codes in a Dawson schedule.
///
/// This tab exists only because `Dawson.institution` declares
/// `.campusNavigation`. A student signed in to any other school never sees it,
/// and never loads this file's view.
struct DawsonCampusView: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    @ObservedObject var model: AppModel

    @State private var query = ""
    @FocusState private var queryIsFocused: Bool

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = model.institution.timeZone
        return calendar
    }

    /// Today's classes that actually carry a room, newest first.
    private var todaysRooms: [(meeting: CourseMeeting, code: DawsonRoomCode?)] {
        model.courses
            .filter { calendar.isDateInToday($0.start) }
            .sorted { $0.start < $1.start }
            .compactMap { meeting in
                guard let location = meeting.location, !location.isEmpty else { return nil }
                return (meeting, DawsonRoomCode.parse(location))
            }
    }

    private var parsedQuery: DawsonRoomCode? {
        DawsonRoomCode.parse(query)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("4H.15", text: $query)
                        .focused($queryIsFocused)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .font(.body.monospaced())

                    if let parsedQuery {
                        breakdown(for: parsedQuery)
                    } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Label(
                            "That isn't a Dawson room code. They look like 4H.15.",
                            systemImage: "questionmark.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Look Up a Room")
                } footer: {
                    Text("Dawson writes rooms as floor, wing, then room number.")
                }

                if !todaysRooms.isEmpty {
                    Section("Today’s Rooms") {
                        ForEach(todaysRooms, id: \.meeting.id) { entry in
                            Button {
                                query = entry.meeting.location ?? ""
                                queryIsFocused = false
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.meeting.title)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Text(entry.code.map(summary) ?? Loc.text("Room %@", entry.meeting.location ?? ""))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 8)

                                    Text(entry.meeting.location ?? "")
                                        .font(.subheadline.monospaced().weight(.semibold))
                                        .foregroundStyle(Neo.accent)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(NeoBackground())
            .navigationTitle("Campus")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .overlay {
                if todaysRooms.isEmpty, query.isEmpty {
                    ContentUnavailableView(
                        "No Rooms Today",
                        systemImage: "map",
                        description: Text("Room codes from your schedule show up here. You can still look one up above.")
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func breakdown(for code: DawsonRoomCode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            detailRow("Floor", code.floorLabel, systemImage: "building.2")
            detailRow("Wing", code.wingLabel, systemImage: "signpost.right")
            detailRow("Room", code.roomLabel, systemImage: "door.left.hand.closed")
        }
        .padding(.vertical, 4)
    }

    private func detailRow(_ title: LocalizedStringKey, _ value: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
    }

    private func summary(_ code: DawsonRoomCode) -> String {
        [code.floorLabel, code.wingLabel].joined(separator: " · ")
    }
}
