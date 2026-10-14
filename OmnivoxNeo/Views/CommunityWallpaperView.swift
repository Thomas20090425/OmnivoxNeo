import SwiftUI

/// Wallpapers other people photographed.
///
/// The photographs are full-size — fifteen to twenty megabytes each, because
/// that is what a photograph off a phone is, and shrinking them to save
/// bandwidth would defeat the point of sharing them. So the grid is
/// thumbnails, the real file is fetched only when somebody picks one, and once
/// fetched it stays. The size is printed on the button beforehand: nobody
/// should spend twenty megabytes of a data plan without being told first.
struct CommunityWallpaperView: View {
    @StateObject private var library = CommunityWallpaperLibrary.shared
    @ObservedObject private var personalization = Personalization.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var applying: String?
    @State private var failed: String?
    @State private var suggestedAccent: AccentChoice?
    @State private var showsRemoveDownloads = false

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch library.state {
                case .loading where library.wallpapers.isEmpty:
                    loading
                case .failed where library.wallpapers.isEmpty:
                    unavailable
                default:
                    grid
                }

                if let suggestedAccent {
                    accentSuggestion(suggestedAccent)
                }

                submission
                storage
            }
            .padding(16)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(NeoBackground())
        .navigationTitle("Community Wallpapers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { library.loadIfNeeded() }
        .refreshable { await library.load() }
        .alert(
            "That Wallpaper Could Not Be Downloaded",
            isPresented: Binding(
                get: { failed != nil },
                set: { if !$0 { failed = nil } }
            )
        ) {
            Button("OK") { failed = nil }
        } message: {
            Text("It needs a connection, and these files are large. Try again on wifi.")
        }
        .confirmationDialog(
            Text("Remove Downloaded Wallpapers?"),
            isPresented: $showsRemoveDownloads,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { library.removeAllDownloads() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The wallpaper you are using now stays. Anything else will be downloaded again next time you pick it.")
        }
    }

    // MARK: - The grid

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(library.wallpapers) { wallpaper in
                tile(wallpaper)
            }
        }
    }

    private func tile(_ wallpaper: CommunityWallpaper) -> some View {
        Button {
            Task { await choose(wallpaper) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Neo.inset)

                    if let url = library.thumbnailURL(for: wallpaper) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure:
                                Image(systemName: "photo")
                                    .foregroundStyle(.tertiary)
                            default:
                                ProgressView().controlSize(.small)
                            }
                        }
                    }

                    if let fraction = library.downloading[wallpaper.id] {
                        Rectangle().fill(.black.opacity(0.45))
                        ProgressView(value: fraction)
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else if applying == wallpaper.id {
                        Rectangle().fill(.black.opacity(0.45))
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .aspectRatio(wallpaper.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if library.downloaded.contains(wallpaper.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white, .black.opacity(0.4))
                            .padding(5)
                            .accessibilityLabel(Text("Already downloaded"))
                    }
                }

                // The photographer, always. It is the only thing anybody who
                // contributed a photograph gets back for it.
                Text(verbatim: wallpaper.credit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !library.downloaded.contains(wallpaper.id), let size = wallpaper.downloadSize {
                    Text(verbatim: size)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(applying != nil || library.downloading[wallpaper.id] != nil)
        .contextMenu {
            if library.downloaded.contains(wallpaper.id) {
                Button(role: .destructive) {
                    library.removeDownload(wallpaper)
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel(Text(Loc.text("Wallpaper by %@", wallpaper.credit)))
    }

    // MARK: - Choosing one

    private func choose(_ wallpaper: CommunityWallpaper) async {
        applying = wallpaper.id
        defer { applying = nil }

        guard let data = await library.imageData(for: wallpaper) else {
            failed = wallpaper.id
            return
        }
        guard personalization.setWallpaperPhoto(data: data) else {
            failed = wallpaper.id
            return
        }
        // Offered, never applied on its own. Somebody who chose their colour
        // deliberately should not find it changed because they liked a
        // photograph.
        suggestedAccent = WallpaperAccentSuggestion.accent(for: data)
    }

    // MARK: - The colour that goes with it

    private func accentSuggestion(_ accent: AccentChoice) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(accent.color)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text("A colour from this photo")
                    .font(.subheadline.weight(.medium))
                Text(LocalizedStringKey(accent.title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Use It") {
                personalization.setAccent(accent)
                suggestedAccent = nil
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                suggestedAccent = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
        .transition(.opacity)
    }

    // MARK: - Contributing one

    private var submission: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add your own")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text("Email a photo to \(CommunityWallpaperLibrary.submissionAddress) and it may end up here. Say what name you would like on it — leave that out and it goes up without one. Names that are not names will be treated as though you left it blank. You will get a reply either way.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                let address = CommunityWallpaperLibrary.submissionAddress
                let subject = "Omnivox Neo wallpaper submission"
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let url = URL(string: "mailto:\(address)?subject=\(subject)") {
                    openURL(url)
                }
            } label: {
                Label("Email a Photo", systemImage: "envelope")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
    }

    // MARK: - What is on the device

    @ViewBuilder
    private var storage: some View {
        if !library.downloaded.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloaded")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(Loc.text(
                    "%@ of wallpapers are saved on this device so they do not have to be downloaded again.",
                    library.cacheSizeDescription
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button(role: .destructive) {
                    showsRemoveDownloads = true
                } label: {
                    Label("Remove Downloads", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neoCard()
        }
    }

    // MARK: - Before there is anything to show

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading the wallpapers…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Wallpapers Unavailable")
                .font(.headline)
            Text("These are downloaded from the project's repository, so they need a connection.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") {
                Task { await library.load() }
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}
