import SwiftUI
#if os(iOS)
import UIKit

/// Position a photo the way iOS does when you set a wallpaper: pinch to zoom,
/// drag to move, and what you see inside the phone-shaped frame is what gets
/// saved.
///
/// The image is always clamped so it covers the frame — you can never drag a
/// blank edge into view, which is the difference between this feeling like a
/// wallpaper picker and feeling like a free-floating image.
struct WallpaperCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onConfirm: (UIImage) -> Void

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    /// The crop frame matches the screen it will sit behind.
    private var screenAspect: CGFloat {
        let size = UIScreen.main.bounds.size
        return size.width / size.height
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let frame = cropFrame(in: geometry.size)

                ZStack {
                    Color.black.ignoresSafeArea()
                        .onAppear { cropFrameWidth = frame.width }
                        .onChange(of: frame.width) { _, width in cropFrameWidth = width }

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: frame.width, height: frame.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: frame.width, height: frame.height)
                        .clipped()
                        .overlay {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(.white.opacity(0.7), lineWidth: 2)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .gesture(
                            SimultaneousGesture(
                                MagnifyGesture()
                                    .onChanged { value in
                                        scale = clampedScale(committedScale * value.magnification)
                                        offset = clampedOffset(offset, in: frame)
                                    }
                                    .onEnded { _ in
                                        committedScale = scale
                                        committedOffset = offset
                                    },
                                DragGesture()
                                    .onChanged { value in
                                        offset = clampedOffset(
                                            CGSize(
                                                width: committedOffset.width + value.translation.width,
                                                height: committedOffset.height + value.translation.height
                                            ),
                                            in: frame
                                        )
                                    }
                                    .onEnded { _ in committedOffset = offset }
                            )
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    VStack {
                        Spacer()
                        Text("Pinch to zoom · Drag to move")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.bottom, 12)
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Move and Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { confirm() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Geometry

    private func cropFrame(in available: CGSize) -> CGSize {
        let inset: CGFloat = 32
        let maxWidth = available.width - inset * 2
        let maxHeight = available.height - inset * 2

        // Fit the phone-shaped frame inside whatever room we have.
        let byWidth = CGSize(width: maxWidth, height: maxWidth / screenAspect)
        return byWidth.height <= maxHeight
            ? byWidth
            : CGSize(width: maxHeight * screenAspect, height: maxHeight)
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 1), 5)
    }

    /// Keeps the image covering the frame, so no empty edge can be dragged in.
    private func clampedOffset(_ proposed: CGSize, in frame: CGSize) -> CGSize {
        let slackX = max(0, (frame.width * scale - frame.width) / 2)
        let slackY = max(0, (frame.height * scale - frame.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -slackX), slackX),
            height: min(max(proposed.height, -slackY), slackY)
        )
    }

    // MARK: - Rendering

    private func confirm() {
        onConfirm(renderCrop())
    }

    /// Reproduces what the frame showed, at wallpaper resolution.
    ///
    /// The on-screen frame and the output share an aspect ratio, so the visible
    /// region maps across by a single scale factor.
    private func renderCrop() -> UIImage {
        let output = CGSize(width: 1170, height: 1170 / screenAspect)
        let renderer = UIGraphicsImageRenderer(size: output)

        return renderer.image { _ in
            // `scaledToFill` inside the frame, then the user's zoom on top.
            let imageAspect = image.size.width / image.size.height
            let fillScale = imageAspect > screenAspect
                ? output.height / image.size.height
                : output.width / image.size.width
            let drawScale = fillScale * scale

            let drawSize = CGSize(
                width: image.size.width * drawScale,
                height: image.size.height * drawScale
            )

            // The gesture offset is in frame points; convert to output pixels.
            let frameToOutput = output.width / cropFrameWidth
            let origin = CGPoint(
                x: (output.width - drawSize.width) / 2 + offset.width * frameToOutput,
                y: (output.height - drawSize.height) / 2 + offset.height * frameToOutput
            )

            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }

    /// The frame width the gestures were measured against, captured at layout
    /// so the render can undo the same scaling.
    @State private var cropFrameWidth: CGFloat = 1
}
#endif
