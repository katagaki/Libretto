import UIKit

extension DocumentTextController {
    /// The equation the selection is on: picked out, or just beside the caret.
    var selectedEquation: (range: NSRange, xml: String)? {
        let selection = textView.selectedRange
        let candidates = selection.length == 1 ? [selection.location]
            : selection.length == 0 ? [selection.location - 1, selection.location] : []
        for index in candidates where index >= 0 && index < storage.length {
            guard let box = storage.attribute(.librettoToken, at: index, effectiveRange: nil) as? InlineBox,
                  case .paragraphChild(let xml, _) = box.inline.content, MathRenderer.isEquation(xml) else { continue }
            return (NSRange(location: index, length: 1), xml)
        }
        return nil
    }

    /// An equation typed on a line, put in at the selection, or in place of the equation it is on.
    func insertEquation(_ linear: String) {
        let xml = LinearMath.omml(linear)
        let replacing = selectedEquation?.range
        let range = replacing ?? textView.selectedRange
        let format = runBox(forTypingAt: range.location).format
        let inline = Inline(.paragraphChild(xml: xml, display: linear), format: format)
        var attributes = typingAttributes(at: range.location)
        attributes[.attachment] = DocumentRenderer.equationAttachment(xml, attributes: attributes, context: context)
        attributes[.librettoToken] = InlineBox(inline, display: TextCharacters.attachment)
        insert(NSAttributedString(string: TextCharacters.attachment, attributes: attributes), at: range, selecting: range.location + 1)
        if replacing != nil { textView.selectedRange = NSRange(location: range.location, length: 1) }
        selectionDidChange()
    }

    func deleteSelectedEquation() {
        guard let (range, _) = selectedEquation else { return }
        storage.deleteCharacters(in: range)
        textView.selectedRange = NSRange(location: range.location, length: 0)
        relayout()
        sync(scope: .insertion)
        selectionDidChange()
    }
}
