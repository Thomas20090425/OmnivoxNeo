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
    /// Which one is currently the wallpaper, so the feed can say so.
    @State private var applied: String?
    @State private var failed: String?
    @State private var suggestedAccent: AccentChoice?
    @State private var showsRemoveDownloads = false
    /// The width the grid actually got, which is what tile height is worked
    /// out from.
    @State private var gridWidth: CGFloat = 0
    /// The width of the window the page is in.
    @State private var containerWidth: CGFloat = 0

    /// How wide the page is allowed to be: the window, capped so the feed does
    /// not stretch into two enormous columns on a Mac.
    private var pageWidth: CGFloat? {
        guard containerWidth > 0 else { return nil }
        return min(containerWidth, 700)
    }

    /// Two across, and no more.
    ///
    /// A wallpaper is chosen by looking at it, and three to a row on a phone
    /// makes each one a stamp — too small to tell one green field from
    /// another, which is the only question being asked. Two is wide enough
    /// that the picture is actually legible, and a feed that scrolls is a
    /// better shape for browsing than a dense grid that does not.
    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: Self.gutter), GridItem(.flexible(), spacing: Self.gutter)]
    }

    private static let gutter: CGFloat = 14
    /// A phone's own proportions, so a tile previews what the photograph will
    /// look like filling the screen rather than whatever shape it happens to
    /// be.
    private static let tileRatio: CGFloat = 0.56

    /// How tall a tile is, from the width the grid actually got.
    private var tileHeight: CGFloat {
        guard gridWidth > 0 else { return 240 }
        return ((gridWidth - Self.gutter) / 2) / Self.tileRatio
    }

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
            // An exact width taken from the window, not a maximum.
            //
            // `frame(maxWidth:)` is a ceiling on a width the children still
            // get to ask for, and one child asking for more than the screen
            // makes the whole page wider than the screen — which a scroll view
            // then centres, pushing everything sideways and cutting off the
            // back button. Stating the width outright means no child can do
            // that, whatever it reports.
            .frame(width: pageWidth)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            containerWidth = width
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
        LazyVGrid(columns: columns, spacing: Self.gutter) {
            ForEach(library.wallpapers) { wallpaper in
                tile(wallpaper)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            gridWidth = width
        }
    }

    private func tile(_ wallpaper: CommunityWallpaper) -> some View {
        let isDownloaded = library.downloaded.contains(wallpaper.id)
        let isApplied = applied == wallpaper.id
        let progress = library.downloading[wallpaper.id]

        return Button {
            Task { await choose(wallpaper) }
        } label: {
            // An explicit height, worked out from the measured width of the
            // grid, rather than an aspect ratio.
            //
            // `aspectRatio` needs a proposal in both directions to resolve
            // against, and inside a scrolling grid the height proposal is
            // unbounded — so it resolved against the wrong axis and the tiles
            // came out wider than the screen, dragging the whole view
            // sideways. A number computed from a width that was actually
            // measured cannot do that.
            tileContents(wallpaper, isDownloaded: isDownloaded, progress: progress)
                // Both axes pinned, and clipped.
                //
                // `scaledToFill` deliberately reports a size *larger* than
                // what it was offered — that is how it fills — and a ZStack
                // takes its size from its biggest child. Fixing only the
                // height left the width free, so once a thumbnail loaded the
                // tile grew wider than its column and pushed the whole screen
                // sideways. Fixing the width too, and clipping, keeps the
                // overflow where it belongs: inside the tile.
                .frame(maxWidth: .infinity)
                .frame(height: tileHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isApplied ? Neo.accent : Color.black.opacity(0.08),
                        lineWidth: isApplied ? 3 : 0.5
                    )
            }
            .overlay(alignment: .topTrailing) {
                badge(isApplied: isApplied, isDownloaded: isDownloaded)
            }
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
        .buttonStyle(LeaPressStyle())
        .disabled(applying != nil || progress != nil)
        .contextMenu {
            if isDownloaded {
                Button(role: .destructive) {
                    library.removeDownload(wallpaper)
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel(Text(Loc.text("Wallpaper by %@", wallpaper.credit)))
        .accessibilityAddTraits(isApplied ? [.isSelected] : [])
    }

    /// The photograph, its credit and whatever is happening to it.
    @ViewBuilder
    private func tileContents(
        _ wallpaper: CommunityWallpaper,
        isDownloaded: Bool,
        progress: Double?
    ) -> some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Neo.inset)

            if let url = library.thumbnailURL(for: wallpaper) {
                AsyncImage(
                    url: url,
                    transaction: Transaction(animation: .easeOut(duration: 0.2))
                ) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    default:
                        ProgressView().controlSize(.small)
                    }
                }
            }

            // The credit rides on the picture rather than under it, so a row
            // of tiles is a row of photographs instead of alternating bands of
            // image and caption. A gradient rather than a bar, because a name
            // has to be readable over a bright sky and a dark one without
            // putting a slab across the bottom of every photo.
            LinearGradient(
                colors: [.clear, .black.opacity(0.1), .black.opacity(0.6)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: wallpaper.credit)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if !isDownloaded, let size = wallpaper.downloadSize {
                    Text(verbatim: size)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .padding(10)

            if let progress {
                Rectangle().fill(.black.opacity(0.5))
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 18)
            } else if applying == wallpaper.id {
                Rectangle().fill(.black.opacity(0.5))
                ProgressView().controlSize(.small).tint(.white)
            }
        }
    }

    /// Which one is in use, and which are already on the device.
    ///
    /// Two different facts, so two different marks — and the one in use also
    /// carries an accent border, because a small glyph in a corner is not
    /// enough to answer "which of these am I looking at right now" at a
    /// glance.
    @ViewBuilder
    private func badge(isApplied: Bool, isDownloaded: Bool) -> some View {
        if isApplied {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(5)
                .background(Neo.accent, in: Circle())
                .padding(8)
                .accessibilityLabel(Text("In use"))
        } else if isDownloaded {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.white, .black.opacity(0.35))
                .padding(8)
                .accessibilityLabel(Text("Already downloaded"))
        }
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
        withAnimation(.easeInOut(duration: 0.2)) { applied = wallpaper.id }
        // Offered, never applied on its own. Somebody who chose their colour
        // deliberately should not find it changed because they liked a
        // photograph.
        withAnimation(.easeInOut(duration: 0.25)) {
            suggestedAccent = WallpaperAccentSuggestion.accent(for: data)
        }
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
