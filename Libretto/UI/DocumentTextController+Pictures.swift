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
