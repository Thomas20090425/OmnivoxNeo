import SwiftUI

/// The websites a teacher recommends for one course.
///
/// Reached from inside the course rather than from a directory of every
/// teacher in the term: a student looking for a reading is looking inside the
/// class it was set for, and the standalone list mostly showed rows saying a
/// teacher had recommended nothing. Grouped the way the teacher grouped them.
struct LeaTeacherSitesView: View {
    @ObservedObject var store: LeaStore
    let teacher: LeaTeacherSites

    @Environment(\.openURL) private var openURL
    @State private var pending: LeaSite?

    private var state: LeaLoadable<[LeaSiteCategory]> {
        store.sites[teacher.id] ?? .idle
    }

    private var identity: CourseIdentity {
        CourseIdentity.forCourse(code: teacher.courseCode, title: teacher.courseCode)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                Label(teacher.teacher, systemImage: "person.crop.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                switch state {
                case .idle, .loading:
                    LeaSkeleton(shape: .rows(3))

                case .failed(let message):
                    LeaFailureCard(message: message) { store.loadSites(for: teacher) }

                case .loaded(let categories):
                    ForEach(categories) { category in
                        VStack(alignment: .leading, spacing: 10) {
                            // A teacher who filed nothing under a heading still
                            // gets one, rather than their links appearing to
                            // belong to whatever heading came before them.
                            Text(category.name.isEmpty
                                 ? String(localized: "Other links")
                                 : category.name)
                                .font(.headline)
                                .padding(.leading, 2)

                            VStack(spacing: 0) {
                                ForEach(Array(category.sites.enumerated()), id: \.element.id) { index, site in
                                    if index > 0 { Divider().padding(.leading, 66) }
                                    Button { pending = site } label: {
                                        siteRow(site)
                                    }
                                    .buttonStyle(LeaPressStyle())
                                }
                            }
                            .neoCard()
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
        .navigationTitle(teacher.courseCode)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { store.loadSites(for: teacher) }
        .confirmationDialog(
            Text(pending?.title ?? ""),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Open in Browser") {
                if let site = pending { openURL(site.url) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if let site = pending {
                Text("This is a link to another website. It will open in your browser.\n\n\(site.url.host() ?? site.url.absoluteString)")
            }
        }
    }

    private func siteRow(_ site: LeaSite) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(identity.start)
                .frame(width: 38, height: 38)
                .background(
                    identity.start.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(site.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = site.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(site.url.host() ?? site.url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens in your browser"))
    }
}
