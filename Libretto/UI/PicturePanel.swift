import SwiftUI

/// The picture the selection is on: its size, its crop, how text wraps
/// around it, and where it sits when it floats.
struct PicturePanel: View {
    @Binding var document: WordDocument
    @Bindable var state: EditorState

    private var controller: DocumentTextController? { state.controller }
    /// Read afresh whenever the document changes, which the binding tells this view of.
    private var image: InlineImage? { document.body.isEmpty ? nil : controller?.selectedImage?.image }

    var body: some View {
        Form {
            if let image {
                Section("Picture.Section.Size") {
                    Stepper(
                        String(format: String(localized: "Picture.Width"), Self.points(image.width)),
                        onIncrement: { resize(image, by: 12) },
                        onDecrement: { resize(image, by: -12) }
                    )
                    .accessibilityIdentifier("picture.width")
                    Text(String(format: String(localized: "Picture.Height"), Self.points(image.height)))
                        .foregroundStyle(.secondary)
                    Button("Picture.OriginalSize", systemImage: "arrow.uturn.backward") {
                        guard let natural = controller?.selectedImageNaturalSize else { return }
                        controller?.updateSelectedImage { picture in
                            picture.width = natural.width * (1 - picture.crop.left - picture.crop.right)
                            picture.height = natural.height * (1 - picture.crop.top - picture.crop.bottom)
                        }
                    }
                }

                Section("Picture.Section.Crop") {
                    cropSlider("Picture.Crop.Left", \.left, image)
                    cropSlider("Picture.Crop.Right", \.right, image)
                    cropSlider("Picture.Crop.Top", \.top, image)
                    cropSlider("Picture.Crop.Bottom", \.bottom, image)
                }

                Section("Picture.Section.Wrap") {
                    Picker("Picture.Wrap", selection: Binding(
                        get: { image.wrap },
                        set: { wrap in controller?.updateSelectedImage { $0.wrap = wrap } }
                    )) {
                        ForEach(ImageWrap.allCases, id: \.self) { wrap in
                            Text(LocalizedStringKey("Wrap.\(wrap.rawValue)")).tag(wrap)
                        }
                    }
                    .accessibilityIdentifier("picture.wrap")
                    if image.wrap != .inline {
                        Picker("Picture.Horizontal", selection: Binding(
                            get: { image.alignment ?? .leading },
                            set: { alignment in controller?.updateSelectedImage { $0.alignment = alignment } }
                        )) {
                            ForEach([ParagraphAlignment.leading, .center, .trailing], id: \.self) { alignment in
                                Image(systemName: alignment.symbolName).accessibilityLabel(alignment.label).tag(alignment)
                            }
                        }
                        .pickerStyle(.segmented)
                        Stepper(
                            String(format: String(localized: "Picture.Vertical"), Self.points(image.verticalOffset)),
                            onIncrement: { controller?.updateSelectedImage { $0.verticalOffset += 12 } },
                            onDecrement: { controller?.updateSelectedImage { $0.verticalOffset -= 12 } }
                        )
                    }
                }

                Section {
                    Button("Picture.Delete", systemImage: "trash", role: .destructive) {
                        controller?.deleteSelectedImage()
                        state.presentedPanel = nil
                    }
                }
            } else {
                ContentUnavailableView("Picture.None", systemImage: "photo")
            }
        }
        .formStyle(.grouped)
    }

    private static func points(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    /// A new width, the height keeping the picture's proportions.
    private func resize(_ image: InlineImage, by step: Double) {
        let ratio = image.height / max(image.width, 1)
        controller?.updateSelectedImage { picture in
            picture.width = max(12, picture.width + step)
            picture.height = picture.width * ratio
        }
    }

    private func cropSlider(_ label: LocalizedStringKey, _ edge: WritableKeyPath<ImageCrop, Double>, _ image: InlineImage) -> some View {
        LabeledContent(label) {
            Slider(value: Binding(
                get: { image.crop[keyPath: edge] },
                set: { value in
                    controller?.updateSelectedImage { picture in
                        // What is cut off comes off the picture's size too.
                        let old = picture.crop
                        var crop = old
                        crop[keyPath: edge] = value
                        let horizontal = (1 - crop.left - crop.right) / max(0.01, 1 - old.left - old.right)
                        let vertical = (1 - crop.top - crop.bottom) / max(0.01, 1 - old.top - old.bottom)
                        picture.width *= horizontal
                        picture.height *= vertical
                        picture.crop = crop
                    }
                }
            ), in: 0...0.45)
            .frame(maxWidth: 180)
        }
    }
}
