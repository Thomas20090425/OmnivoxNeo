import SwiftUI

/// The assignment list, and the way back into Léa to hand one in.
///
/// Reading is native; submitting is not. Léa's upload form is a real ASP.NET
/// page with its own validation, file-type rules and confirmation, and a
/// re-implementation that got any of that subtly wrong would lose a student's
/// work. So the instructions page is shown in a web view, which is also the
/// only place the file picker can legitimately come from.
///
/// Each assignment states its own status in words — handed in, not handed in,
/// overdue — rather than leaving it to be inferred from a colour. Léa signals a
/// missed deadline by printing the date in red and nothing else, which is a
/// message no one gets who cannot see red.
struct LeaAssignmentsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: LeaStore
    let course: LeaCourse
    let onOpenSubmission: (LeaWebPage) -> Void
    let onOpenFile: (LeaOpenedFile) -> Void

    @State private var downloading: String?
    @State private var downloadError: String?
    @ObservedObject private var personalization = Personalization.shared

    private var state: LeaLoadable<[LeaAssignment]> {
        store.assignments[course.id] ?? .idle
    }

    private var identity: CourseIdentity { store.identity(for: course) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                switch state {
                case .idle, .loading:
                    LeaSkeleton(shape: .rows(3))

                case .failed(let message):
                    LeaFailureCard(message: message) { store.reloadAssignments(for: course) }

                case .loaded(let assignments):
                    if assignments.isEmpty {
                        ContentUnavailableView(
                            "No Assignments",
                            systemImage: "tray",
                            description: Text("Nothing has been assigned in this course yet.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        ForEach(grouped(assignments), id: \.0) { category, items in
                            group(named: category, items: items)
                        }
                    }
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(NeoBackground())
        .navigationTitle(Text("Assignments"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { store.loadAssignments(for: course) }
        .refreshable { store.reloadAssignments(for: course) }
        .alert(
            Text("Couldn’t open that"),
            isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })
        ) {
            Button("OK", role: .cancel) { downloadError = nil }
        } message: {
            if let downloadError { Text(downloadError) }
        }
    }

    private func grouped(_ assignments: [LeaAssignment]) -> [(String, [LeaAssignment])] {
        var order: [String] = []
        var buckets: [String: [LeaAssignment]] = [:]
        for assignment in assignments {
            let key = assignment.category ?? ""
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(assignment)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private func group(named category: String, items: [LeaAssignment]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !category.isEmpty {
                Text(category)
                    .font(.headline)
                    .padding(.leading, 2)
            }

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, assignment in
                    if index > 0 { Divider().padding(.leading, 16) }
                    row(assignment)
                }
            }
            .neoCard()
        }
    }

    private func row(_ assignment: LeaAssignment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if let url = assignment.instructionsURL {
                    onOpenSubmission(LeaWebPage(url: url, title: assignment.title))
                }
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: assignment.isHandedIn
                              ? "checkmark.circle.fill"
                              : "tray.and.arrow.up.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(assignment.isHandedIn ? .green : identity.start)
                            .frame(width: 38, height: 38)
                            .background(
                                (assignment.isHandedIn ? Color.green : identity.start).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )

                        if assignment.hasUnreadInstructions {
                            Circle()
                                .fill(.red)
                                .stroke(Neo.surface, lineWidth: 2)
                                .frame(width: 11, height: 11)
                                .offset(x: 4, y: -4)
                        }
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(assignment.title)
                            .font(.subheadline.weight(assignment.hasUnreadInstructions ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        if let due = assignment.dueText {
                            HStack(spacing: 5) {
                                Image(systemName: assignment.isOverdue
                                      ? "exclamationmark.triangle.fill"
                                      : "clock")
                                Text(due)
                                if let via = assignment.dueVia {
                                    Text(verbatim: "·")
                                    Text(via)
                                }
                            }
                            .font(.caption)
                            // Named as well as coloured: Léa's own signal for a
                            // missed deadline is the colour red and nothing else.
                            .foregroundStyle(assignment.isOverdue ? Color.red : Color.secondary)
                        }

                        statusLabel(assignment)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(LeaPressStyle())
            .disabled(assignment.instructionsURL == nil)
            .accessibilityElement(children: .combine)

            if assignment.correctedCopyURL != nil {
                Button {
                    downloadCorrected(assignment)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Marked copy")
                        if downloading == assignment.id {
                            LeaDownloadBar(progress: store.downloadProgress, tint: identity.start)
                                .frame(width: 60)
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(identity.start)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(identity.start.opacity(0.12), in: Capsule())
                }
                .buttonStyle(LeaPressStyle())
                .padding(.leading, 52)
            }
        }
        .padding(16)
    }

    /// What Léa records about this assignment, and nothing more.
    ///
    /// The old version of this said "Not handed in" whenever it could not find
    /// a deposit link, and "Overdue — not handed in" when the deadline had also
    /// passed. Neither is written anywhere on the page. Léa records uploads; it
    /// does not record the absence of one, and a teacher who collects work on
    /// paper, or who removed the deposit after marking, leaves exactly the same
    /// empty row as a student who did nothing. So a finished assignment was
    /// being accused of being late, in red, which is the worst thing this
    /// screen can get wrong.
    ///
    /// What replaces it is a statement about the record — "No upload recorded"
    /// — plus, separately, the one genuine "this is new" signal Léa does give:
    /// the star on instructions that have never been opened. That was already
    /// being read, but drawn only as a red dot inside an accessibility-hidden
    /// stack, so the single fact distinguishing a just-posted assignment from a
    /// finished one was visible to nobody who could not see it.
    @ViewBuilder
    private func statusLabel(_ assignment: LeaAssignment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if assignment.hasMarkedCopy {
                Label("Marked copy returned", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else if let submission = assignment.submissionText {
                Label(submission, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            } else if assignment.isHandedIn {
                // The link was there but Léa printed no words on it.
                Label("Handed in", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Label("No upload recorded", systemImage: "tray")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Red on the date is all Léa says about a missed deadline.
                // Said here in a word as well, because red is not a word.
                if assignment.isOverdue {
                    Label("Deadline passed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            if assignment.hasUnreadInstructions {
                Label("Instructions not opened yet", systemImage: "envelope.badge.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(identity.start)
            }
        }
    }

    /// Corrected copies are ordinary Léa files and take the same route as a
    /// distributed document: re-read from the page, fetched with the session.
    private func downloadCorrected(_ assignment: LeaAssignment) {
        guard downloading == nil else { return }
        downloading = assignment.id
        downloadError = nil
        Task {
            defer { downloading = nil }
            do {
                let local = try await store.downloadCorrectedCopy(for: assignment, in: course)
                onOpenFile(LeaOpenedFile(url: local, title: assignment.title))
            } catch {
                downloadError = (error as? LeaService.Failure)?.message ?? error.localizedDescription
            }
        }
    }
}
