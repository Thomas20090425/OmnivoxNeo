import SwiftUI
#if os(iOS)
import PhotosUI
#endif

/// Colour and wallpaper, scoped to the signed-in account.
struct PersonalizationSettingsView: View {
    @ObservedObject private var personalization = Personalization.shared

    #if os(iOS)
    @State private var photoSelection: PhotosPickerItem?
    @State private var pendingCrop: PendingCrop?
    #endif
    @State private var photoError: String?
    @State private var isLoadingPhoto = false

    private let columns = [GridItem(.adaptive(minimum: 58, maximum: 76), spacing: 14)]

    var body: some View {
        List {
            Section {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AccentChoice.allCases) { choice in
                        swatch(for: choice)
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Accent Colour")
            } footer: {
                Text("Used for buttons, links and the selected tab. Every colour here stays readable in both light and dark appearance.")
            }

            Section {
                wallpaperRow(
                    title: Loc.text("None"),
                    isSelected: personalization.wallpaper == .none
                ) {
                    Neo.canvas
                        .overlay {
                            Image(systemName: "slash.circle")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                } action: {
                    personalization.setWallpaper(.none)
                }

                ForEach(BuiltInWallpaper.all) { wallpaper in
                    wallpaperRow(
                        title: Loc.text(wallpaper.title),
                        isSelected: personalization.wallpaper == .builtIn(wallpaper.id)
                    ) {
                        wallpaper.gradient
                    } action: {
                        personalization.setWallpaper(.builtIn(wallpaper.id))
                    }
                }

                #if os(iOS)
                // A photo is a wallpaper, so it belongs in the same list as the
                // other wallpapers rather than in a section of its own.
                PhotosPicker(
                    selection: $photoSelection,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 14) {
                        Group {
                            if let photo = personalization.wallpaperPhoto {
                                photo.resizable().scaledToFill()
                            } else {
                                Neo.inset.overlay {
                                    Image(systemName: "photo")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(width: 44, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Neo.separator)
                        }

                        Text(personalization.hasWallpaperPhoto ? "Your Photo" : "Choose a Photo")
                            .foregroundStyle(.primary)

                        Spacer(minLength: 8)

                        if isLoadingPhoto {
                            ProgressView().controlSize(.small)
                        } else if personalization.wallpaper == .photo {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(Neo.accent)
                        }
                    }
                }
                .disabled(isLoadingPhoto)

                // Photographs other students took, as an alternative to one of
                // your own. Its own row rather than a mode inside the picker
                // above, because "a picture from my camera roll" and "a
                // picture somebody else made" are different enough decisions
                // that merging them into one button would be a riddle.
                NavigationLink {
                    CommunityWallpaperView()
                } label: {
                    HStack(spacing: 14) {
                        Neo.inset
                            .overlay {
                                Image(systemName: "photo.stack")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 44, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Neo.separator)
                            }

                        Text("Community Wallpapers")
                            .foregroundStyle(.primary)
                    }
                }

                if personalization.hasWallpaperPhoto {
                    Button(role: .destructive) {
                        personalization.clearWallpaperPhoto()
                    } label: {
                        Label("Remove Photo", systemImage: "trash")
                    }
                }
                #endif
            } header: {
                Text("Wallpaper")
            } footer: {
                if let photoError {
                    Text(photoError).foregroundStyle(.red)
                } else {
                    Text("Sits behind your schedule and settings. Cards stay solid so everything remains readable. A photo you choose is stored with this account only.")
                }
            }

            Section {
                Picker(
                    selection: Binding(
                        get: { personalization.gradeChartScale },
                        set: { personalization.setGradeChartScale($0) }
                    )
                ) {
                    ForEach(GradeChartScale.allCases) { scale in
                        Text(scale.title).tag(scale)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemImage: "chart.xyaxis.line", tint: Neo.accent)
                        Text("Chart Scale")
                            .foregroundStyle(.primary)
                    }
                }
            } header: {
                Text("Grades")
            } footer: {
                Text("Fit to your marks shows small changes clearly. Always 0–100% keeps the scale honest, but flattens the line.")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
        .fullScreenCover(item: $pendingCrop) { pending in
            WallpaperCropView(image: pending.image) {
                pendingCrop = nil
            } onConfirm: { cropped in
                pendingCrop = nil
                if let data = cropped.jpegData(compressionQuality: 0.9),
                   !personalization.setWallpaperPhoto(data: data) {
                    photoError = Loc.text("That photo couldn’t be saved. Try another one.")
                }
            }
        }
        #endif
        .scrollContentBackground(.hidden)
        .background(NeoBackground())
        .navigationTitle("Personalization")
    }

    private func swatch(for choice: AccentChoice) -> some View {
        let isSelected = personalization.accent == choice

        return Button {
            personalization.setAccent(choice)
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(choice.color)
                    .frame(width: 44, height: 44)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(Color.primary.opacity(isSelected ? 0.5 : 0), lineWidth: 2)
                            .padding(-4)
                    }

                Text(Loc.text(choice.title))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Loc.text(choice.title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// `title` arrives already localized: `AccentChoice` and `BuiltInWallpaper`
    /// are shared with the widget extension, which has no access to `Loc`, so
    /// their names are translated here at the call site instead.
    private func wallpaperRow<Preview: View>(
        title: String,
        isSelected: Bool,
        @ViewBuilder preview: () -> Preview,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                preview()
                    .frame(width: 44, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Neo.separator)
                    }

                Text(title)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Neo.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    #if os(iOS)
    private func load(_ item: PhotosPickerItem) async {
        isLoadingPhoto = true
        photoError = nil
        defer {
            isLoadingPhoto = false
            photoSelection = nil
        }

        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else {
            photoError = Loc.text("That photo couldn’t be loaded. Try another one.")
            return
        }
        pendingCrop = PendingCrop(image: image)
    }

    struct PendingCrop: Identifiable {
        let id = UUID()
        let image: UIImage
    }
    #endif
}

extension GradeChartScale {
    /// Named next to the screen that shows them, so the model stays free of
    /// wording and the catalog picks the strings up from a `Text` literal.
    var title: LocalizedStringKey {
        switch self {
        case .dynamic: "Fit to your marks"
        case .fromZero: "Always 0–100%"
        }
    }
}
