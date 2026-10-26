import SwiftUI
#if os(iOS)
import UIKit

/// Position a photo the way iOS does when you set a wallpaper: pinch to zoom,
/// drag to move, and what you see inside the frame is what gets saved.
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

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                // The outer display, inner display, and a Split View window can
                // all have different proportions during this one presentation.
                // Derive the crop from this view, never from a global screen.
                let aspect = geometry.size.width / max(geometry.size.height, 1)
                let frame = cropFrame(in: geometry.size, aspect: aspect)

                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 12) {
                        Spacer(minLength: 0)

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

                        Text("Pinch to zoom · Drag to move")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .onChange(of: frame) { oldFrame, newFrame in
                    // Retain the same relative photo position when the window
                    // resizes as iPhone Duo opens, closes, or enters Split View.
                    guard oldFrame.width > 0, oldFrame.height > 0 else { return }
                    offset = clampedOffset(
                        CGSize(
                            width: offset.width * newFrame.width / oldFrame.width,
                            height: offset.height * newFrame.height / oldFrame.height
                        ),
                        in: newFrame
                    )
                    committedOffset = offset
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: onCancel) {
                            Label("Cancel", systemImage: "xmark")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            onConfirm(renderCrop(in: frame))
                        } label: {
                            Label("Set", systemImage: "checkmark")
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .navigationTitle("Move and Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Geometry

    private func cropFrame(in available: CGSize, aspect: CGFloat) -> CGSize {
        let inset: CGFloat = 32
        let maxWidth = max(1, available.width - inset * 2)
        // Reserve a line below the image for the gesture instructions.
        let maxHeight = max(1, available.height - inset * 2 - 52)

        let byWidth = CGSize(width: maxWidth, height: maxWidth / aspect)
        return byWidth.height <= maxHeight
            ? byWidth
            : CGSize(width: maxHeight * aspect, height: maxHeight)
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 1), 5)
    }

    /// Keeps the image covering the frame, so no empty edge can be dragged in.
    private func clampedOffset(_ proposed: CGSize, in frame: CGSize) -> CGSize {
        let fillScale = max(frame.width / image.size.width, frame.height / image.size.height)
        let drawnWidth = image.size.width * fillScale * scale
        let drawnHeight = image.size.height * fillScale * scale
        let slackX = max(0, (drawnWidth - frame.width) / 2)
        let slackY = max(0, (drawnHeight - frame.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -slackX), slackX),
            height: min(max(proposed.height, -slackY), slackY)
        )
    }

    // MARK: - Rendering

    /// Reproduces what the frame showed, at wallpaper resolution.
    ///
    /// The on-screen frame and the output share an aspect ratio, so the visible
    /// region maps across by a single scale factor.
    private func renderCrop(in frame: CGSize) -> UIImage {
        let aspect = frame.width / frame.height
        let outputScale = 2000 / max(frame.width, frame.height)
        let output = CGSize(width: frame.width * outputScale, height: frame.height * outputScale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: output, format: format)

        return renderer.image { _ in
            // `scaledToFill` inside the frame, then the user's zoom on top.
            let imageAspect = image.size.width / image.size.height
            let fillScale = imageAspect > aspect
                ? output.height / image.size.height
                : output.width / image.size.width
            let drawScale = fillScale * scale

            let drawSize = CGSize(
                width: image.size.width * drawScale,
                height: image.size.height * drawScale
            )

            // The gesture offset is in frame points; convert to output pixels.
            let origin = CGPoint(
                x: (output.width - drawSize.width) / 2 + offset.width * outputScale,
                y: (output.height - drawSize.height) / 2 + offset.height * outputScale
            )

            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }

}
#endif
