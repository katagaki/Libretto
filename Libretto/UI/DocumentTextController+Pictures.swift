import UIKit

extension DocumentTextController {
    /// The picture the selection is on: picked out, or just beside the caret.
    var selectedImage: (range: NSRange, image: InlineImage)? {
        let selection = textView.selectedRange
        let candidates = selection.length == 1 ? [selection.location]
            : selection.length == 0 ? [selection.location - 1, selection.location] : []
        for index in candidates where index >= 0 && index < storage.length {
            guard let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ImageAttachment,
                  case .image(let image) = attachment.inline.content else { continue }
            return (NSRange(location: index, length: 1), image)
        }
        return nil
    }

    /// Changes the picture the selection is on: its size, crop, wrap or place.
    func updateSelectedImage(_ change: (inout InlineImage) -> Void) {
        guard let (range, image) = selectedImage,
              let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? ImageAttachment
        else { return }
        var picture = image
        change(&picture)
        guard picture != image else { return }
        picture.isEdited = true
        var inline = attachment.inline
        inline.content = .image(picture)
        var attributes = storage.attributes(at: range.location, effectiveRange: nil)
        let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        attributes[.attachment] = DocumentRenderer.imageAttachment(
            picture, inline: inline, context: context,
            maximumHeight: DocumentRenderer.maximumImageHeight(in: paragraphStyle, context: context)
        )
        storage.replaceCharacters(in: range, with: NSAttributedString(string: TextCharacters.attachment, attributes: attributes))
        textView.selectedRange = range
        relayout()
        sync(scope: .formatting)
        selectionDidChange()
    }

    /// The picture's own size, in points, before it was scaled.
    var selectedImageNaturalSize: CGSize? {
        guard let (_, image) = selectedImage,
              let picture = context.images.image(forRelationship: image.relationshipID, in: document.package) else { return nil }
        return picture.size
    }

    /// Puts in a shape, or a text box, floating at the selection's paragraph, text going round it.
    func insertShape(_ geometry: String, isTextBox: Bool = false) {
        let shape = ShapeSpec(
            geometry: geometry, fillHex: isTextBox ? "FFFFFF" : "4472C4", lineHex: isTextBox ? "000000" : "2F528F",
            lineWidth: isTextBox ? 0.75 : 1, isTextBox: isTextBox
        )
        var picture = InlineImage(relationshipID: "", width: isTextBox ? 180 : 120, height: isTextBox ? 72 : 80, xml: nil)
        picture.object = .shape(shape)
        picture.wrap = .square
        picture.alignment = .center
        picture.isFloating = true
        picture.isEdited = true
        let selection = textView.selectedRange
        let inline = Inline(.image(picture), format: runBox(forTypingAt: selection.location).format)
        var attributes = typingAttributes(at: selection.location)
        attributes[.attachment] = DocumentRenderer.imageAttachment(picture, inline: inline, context: context)
        insert(NSAttributedString(string: TextCharacters.attachment, attributes: attributes), at: selection, selecting: selection.location)
        textView.selectedRange = NSRange(location: selection.location, length: 1)
        selectionDidChange()
    }

    /// Changes the shape the selection is on: its text, fill or line.
    func updateSelectedShape(_ change: (inout ShapeSpec) -> Void) {
        updateSelectedImage { picture in
            guard case .shape(var shape) = picture.object else { return }
            change(&shape)
            picture.object = .shape(shape)
        }
    }

    func deleteSelectedImage() {
        guard let (range, _) = selectedImage else { return }
        storage.deleteCharacters(in: range)
        textView.selectedRange = NSRange(location: range.location, length: 0)
        relayout()
        sync(scope: .insertion)
        selectionDidChange()
    }

    /// The floating picture at a point in the text view, if one is drawn there.
    func floatingImage(at point: CGPoint) -> Int? {
        layoutManager.placedFloats.last { $0.frame.contains(point) }?.location
    }
}
