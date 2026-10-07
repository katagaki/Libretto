import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The page view's editor: one text view holding the whole document, laid
/// out in pages, kept in step with the model.
///
/// The text is a rendering of the document with the model riding along in
/// its attributes. Typing edits the text, and a moment later the text is
/// read back into blocks and handed to the document; formatting commands
/// change the model in the attributes, restyle what they touched and hand
/// the result over at once. When the document changes from elsewhere — an
/// undo, a panel — the text is rendered afresh.
@MainActor
final class DocumentTextController: NSObject, UITextViewDelegate {
    private(set) var document: WordDocument
    private var scheme: ColorScheme
    private let storage = NSTextStorage()
    private let layoutManager: PageLayoutManager
    private let container = NSTextContainer()
    let textView: DocumentTextView
    let view: PagedDocumentView

    private(set) var geometry: PageGeometry
    private var context: RenderContext
    private let images = ImageStore()
    /// The body the text was last rendered from or read back as.
    private var lastBody: [Block] = []
    private var finalParagraph = Paragraph()
    private var trailingMarkers: [Inline] = []
    private var pageCount = 1
    private var syncTask: Task<Void, Never>?
    /// Formatting chosen with nothing selected, for the text typed next.
    /// The text's length when it was chosen tells typing apart from moving
    /// the caret: UIKit resets the typing attributes on its own schedule, so
    /// the formatting is applied to whatever arrives at that spot instead.
    private var typingFormat: (format: RunFormat, location: Int, length: Int)?

    weak var state: EditorState?
    /// Hands a changed document to whoever owns it.
    var onChange: ((WordDocument) -> Void)?

    init(document: WordDocument, scheme: ColorScheme) {
        self.document = document
        self.scheme = scheme
        geometry = PageGeometry(setup: document.pageSetup, gap: PagedDocumentView.pageGap)
        context = RenderContext(document: document, scheme: scheme, images: images)
        layoutManager = PageLayoutManager(geometry: geometry)
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        textView = DocumentTextView(frame: .zero, textContainer: container)
        view = PagedDocumentView(textView: textView)
        super.init()

        textView.delegate = self
        textView.controller = self
        render()
    }

    // MARK: - Rendering

    private func refreshContext() {
        context = RenderContext(document: document, scheme: scheme, images: images)
        context.contentWidth = geometry.contentWidth
        context.contentHeight = geometry.contentHeight
        layoutManager.geometry = geometry
        layoutManager.styles = document.styles
    }

    /// Renders the whole document into the text, keeping the selection
    /// roughly where it was.
    private func render() {
        refreshContext()
        let selection = textView.selectedRange
        let rendered = DocumentRenderer.render(document.body, context: context)
        storage.setAttributedString(rendered.string)
        finalParagraph = rendered.finalParagraph
        trailingMarkers = rendered.trailingMarkers
        lastBody = document.body
        relayout()
        let location = min(selection.location, storage.length)
        textView.selectedRange = NSRange(location: location, length: min(selection.length, storage.length - location))
        selectionDidChange()
    }

    private func relayout() {
        pageCount = layoutManager.layOutPages(in: container, startingWith: pageCount)
        view.update(
            geometry: geometry, pages: pageCount, setup: document.pageSetup,
            header: document.header, footer: document.footer
        )
    }

    /// Takes a document from the owner, rendering it if it is not the one
    /// the text already shows.
    func update(document new: WordDocument, scheme newScheme: ColorScheme) {
        guard new != document || newScheme != scheme else { return }
        let newGeometry = PageGeometry(setup: new.pageSetup, gap: PagedDocumentView.pageGap)
        let needsRender = newScheme != scheme || newGeometry != geometry || new.body != lastBody
            || new.styles != document.styles || new.numbering != document.numbering
            || new.header != document.header || new.footer != document.footer
        if needsRender {
            // The document's own version wins over typing not yet handed over.
            syncTask?.cancel()
            syncTask = nil
        }
        document = new
        scheme = newScheme
        geometry = newGeometry
        if needsRender { render() } else { refreshContext() }
    }

    // MARK: - Handing changes over

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.sync(scope: .typing)
        }
    }

    /// Hands over typing that is still waiting.
    func flush() {
        guard syncTask != nil else { return }
        sync(scope: .typing)
    }

    private func sync(scope: EditScope) {
        syncTask?.cancel()
        syncTask = nil
        let read = AttributedReader.blocks(
            from: storage, finalParagraph: finalParagraph, trailingMarkers: trailingMarkers
        )
        document.body = read.blocks
        lastBody = read.blocks
        state?.pendingScope = scope
        onChange?(document)
        // Text typed beside a table, or rows taken out of one: the text no
        // longer looks like what it reads as, so show what it reads as.
        if read.needsRender { render() }
    }

    /// After a command changed the text's model: restyle, renumber, lay out, hand over.
    private func commit(restyling range: NSRange, scope: EditScope) {
        storage.beginEditing()
        let relabelled = DocumentRenderer.relabel(storage, finalParagraph: finalParagraph, context: context)
        DocumentRenderer.restyle(storage, paragraphsIn: range, finalParagraph: finalParagraph, context: context)
        for changed in relabelled {
            DocumentRenderer.restyle(storage, paragraphsIn: changed, finalParagraph: finalParagraph, context: context)
        }
        storage.endEditing()
        relayout()
        sync(scope: scope)
        selectionDidChange()
    }

    // MARK: - Text view

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let replacement = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
        let string = storage.string as NSString

        // Backspace into a table's line from the paragraph after it picks out
        // the last row instead of merging the paragraph into the table.
        if replacement.isEmpty, range.length == 1, range.location < string.length,
           storage.attribute(.librettoBlock, at: range.location, effectiveRange: nil) != nil {
            textView.selectedRange = NSRange(location: max(0, range.location - 1), length: 1)
            return false
        }

        var target = range
        let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
        // Typing on a table's line goes into the paragraph after the table.
        if !replacement.isEmpty, range.length == 0, isBlockLine(paragraph) {
            target = NSRange(location: NSMaxRange(paragraph), length: 0)
            if replacement == "\n" { return insertParagraph(at: target, copying: target.location) }
        }

        if replacement == "\n", range.length == 0 {
            return handleReturn(at: range, paragraph: paragraph)
        }
        if target == range, replacement == text { return true }

        // Anything adjusted is inserted by hand, with the typing attributes.
        let attributes = typingAttributes(at: target.location)
        storage.replaceCharacters(in: target, with: NSAttributedString(string: replacement, attributes: attributes))
        textView.selectedRange = NSRange(location: target.location + (replacement as NSString).length, length: 0)
        textDidChange(touchingParagraphs: replacement.contains("\n") || storage.string.isEmpty)
        return false
    }

    /// Return: a new paragraph, in the style the current one says comes next,
    /// or, in an empty list item, the end of the list.
    private func handleReturn(at range: NSRange, paragraph: NSRange) -> Bool {
        let current = paragraphModel(for: paragraph)
        let resolved = document.styles.resolvedParagraphProperties(current.properties)
        let contentLength = paragraph.length - (hasMark(paragraph) ? 1 : 0)
        if contentLength == 0, Typography.listReference(resolved) != nil {
            toggleList(kindOf: resolved)
            return false
        }
        let atEnd = range.location == paragraph.location + contentLength
        let next = document.styles.styles[resolved.styleID ?? current.properties.styleID ?? ""]?.next
        guard atEnd, let next, next != (current.properties.styleID ?? document.styles.defaultParagraphStyleID) else {
            return true
        }
        // The new paragraph starts fresh in the next style.
        var fresh = Paragraph()
        fresh.properties.styleID = next == document.styles.defaultParagraphStyleID ? nil : next
        var attributes = DocumentRenderer.paragraphAttributes(fresh, label: nil, context: context)
        attributes.merge(DocumentRenderer.runAttributes(RunFormat(), hyperlink: nil, paragraph: fresh, context: context)) { _, run in run }
        let mark = hasMark(paragraph) ? NSMaxRange(paragraph) - 1 : nil
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: "\n", attributes: typingAttributes(at: range.location)))
        if let mark {
            // The old mark, one along now, ends the new paragraph.
            storage.setAttributes(attributes, range: NSRange(location: mark + 1, length: 1))
        } else {
            finalParagraph = fresh
        }
        storage.endEditing()
        textView.selectedRange = NSRange(location: range.location + 1, length: 0)
        textDidChange(touchingParagraphs: true)
        return false
    }

    private func insertParagraph(at range: NSRange, copying location: Int) -> Bool {
        storage.replaceCharacters(in: range, with: NSAttributedString(string: "\n", attributes: typingAttributes(at: location)))
        textView.selectedRange = NSRange(location: range.location, length: 0)
        textDidChange(touchingParagraphs: true)
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        textDidChange(touchingParagraphs: true)
    }

    private func textDidChange(touchingParagraphs: Bool) {
        applyTypingFormat()
        if touchingParagraphs {
            let changed = DocumentRenderer.relabel(storage, finalParagraph: finalParagraph, context: context)
            for range in changed {
                DocumentRenderer.restyle(storage, paragraphsIn: range, finalParagraph: finalParagraph, context: context)
            }
        }
        relayout()
        scheduleSync()
        selectionDidChange()
    }

    /// Gives text typed where formatting was chosen that formatting.
    private func applyTypingFormat() {
        guard let typing = typingFormat else { return }
        typingFormat = nil
        let inserted = storage.length - typing.length
        let selection = textView.selectedRange
        guard inserted > 0, selection.location == typing.location + inserted else { return }
        let range = NSRange(location: typing.location, length: inserted)
        storage.beginEditing()
        storage.enumerateAttribute(.librettoRun, in: range) { value, run, _ in
            let hyperlink = (value as? RunBox)?.hyperlink
            storage.addAttribute(.librettoRun, value: RunBox(typing.format, hyperlink: hyperlink), range: run)
        }
        DocumentRenderer.restyle(storage, paragraphsIn: range, finalParagraph: finalParagraph, context: context)
        storage.endEditing()
        textView.selectedRange = selection
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        selectionDidChange()
    }

    private func selectionDidChange() {
        let selection = textView.selectedRange
        if let typing = typingFormat, storage.length == typing.length,
           typing.location != selection.location || selection.length > 0 {
            typingFormat = nil
        }
        textView.typingAttributes = typingAttributes(at: selection.location)
        publishSelection()
        if let range = textView.selectedTextRange, textView.isFirstResponder {
            view.scrollToVisible(textView.caretRect(for: range.end))
        }
    }

    // MARK: - Reading the text's model

    private func hasMark(_ paragraph: NSRange) -> Bool {
        paragraph.length > 0
            && (storage.string as NSString).character(at: NSMaxRange(paragraph) - 1) == TextCharacters.paragraphBreakUnit
    }

    private func isBlockLine(_ paragraph: NSRange) -> Bool {
        hasMark(paragraph) && storage.attribute(.librettoBlock, at: NSMaxRange(paragraph) - 1, effectiveRange: nil) != nil
    }

    private func paragraphModel(for range: NSRange) -> Paragraph {
        DocumentRenderer.paragraphBox(in: storage, paragraphRange: range)?.paragraph ?? finalParagraph
    }

    private func paragraphRange(at location: Int) -> NSRange {
        (storage.string as NSString).paragraphRange(for: NSRange(location: min(location, storage.length), length: 0))
    }

    /// The run formatting text typed at `location` takes: whatever was
    /// chosen for it, else the text before it in the same paragraph, else
    /// the paragraph's mark, which looks like the paragraph's last text.
    private func runBox(forTypingAt location: Int) -> RunBox {
        if let typing = typingFormat, typing.location == location { return RunBox(typing.format, hyperlink: nil) }
        let paragraph = paragraphRange(at: location)
        let string = storage.string as NSString
        func box(at index: Int) -> RunBox? {
            guard index >= paragraph.location, index < NSMaxRange(paragraph), index < string.length else { return nil }
            if storage.attribute(.attachment, at: index, effectiveRange: nil) is BlockAttachment { return nil }
            return storage.attribute(.librettoRun, at: index, effectiveRange: nil) as? RunBox
        }
        if let before = box(at: location - 1), string.character(at: location - 1) != TextCharacters.paragraphBreakUnit {
            // A link carries on only into text that is still inside it.
            let after = box(at: location)
            return RunBox(before.format, hyperlink: after?.hyperlink == before.hyperlink ? before.hyperlink : nil)
        }
        if let at = box(at: location) { return RunBox(at.format, hyperlink: nil) }
        // Code is typed in the code font, even on a line with nothing to take it from.
        return RunBox(document.sourceLanguage == nil ? RunFormat() : PlainText.codeFormat, hyperlink: nil)
    }

    private func typingAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        let range = paragraphRange(at: location)
        let paragraph = isBlockLine(range) ? Paragraph() : paragraphModel(for: range)
        let label = range.length > 0
            ? storage.attribute(.librettoListLabel, at: range.location, effectiveRange: nil) as? ListLabelBox : nil
        let run = runBox(forTypingAt: location)
        var attributes = DocumentRenderer.paragraphAttributes(paragraph, label: label, context: context)
        attributes.merge(
            DocumentRenderer.runAttributes(run.format, hyperlink: run.hyperlink, paragraph: paragraph, context: context)
        ) { _, run in run }
        for key in librettoPositionalKeys { attributes[key] = nil }
        return attributes
    }

    private func publishSelection() {
        guard let state else { return }
        let selection = textView.selectedRange
        let range = paragraphRange(at: selection.location)
        let paragraph = paragraphModel(for: range)
        let format: RunFormat = selection.length == 0
            ? runBox(forTypingAt: selection.location).format
            : (storage.attribute(.librettoRun, at: selection.location, effectiveRange: nil) as? RunBox)?.format
                ?? RunFormat()
        let styles = document.styles
        let resolvedParagraph = styles.resolvedParagraphProperties(paragraph.properties)
        let run = styles.resolvedRunStyle(format.style, paragraphStyleID: paragraph.properties.styleID)

        var result = SelectionFormat()
        result.isBold = run.isBold ?? false
        result.isItalic = run.isItalic ?? false
        result.isUnderlined = run.underline ?? false
        result.isStruckThrough = run.isStruckThrough ?? false
        result.verticalAlignment = run.verticalAlignment ?? .baseline
        result.fontSize = run.fontSize ?? 22
        result.colorHex = run.colorHex
        result.highlight = run.highlight
        result.alignment = resolvedParagraph.alignment ?? .leading
        result.styleChoice = styles.choice(forStyle: paragraph.properties.styleID)
        result.listKind = Typography.listReference(resolvedParagraph).flatMap { document.numbering.kind(of: $0.numberingID) }
        result.spacingBefore = resolvedParagraph.spacingBefore ?? 0
        result.spacingAfter = resolvedParagraph.spacingAfter ?? 0
        result.lineSpacing = resolvedParagraph.lineSpacing?.multiple ?? 1
        if state.selectionFormat != result { state.selectionFormat = result }

        var table: Table.ID?
        if isBlockLine(range),
           let box = storage.attribute(.librettoBlock, at: NSMaxRange(range) - 1, effectiveRange: nil) as? BlockBox,
           case .table(let found) = box.block {
            table = found.id
        }
        if state.selectedTableID != table { state.selectedTableID = table }
    }

    // MARK: - Character formatting

    /// Changes the run formatting of the selection, or of what is typed next
    /// when nothing is selected.
    private func editRuns(_ change: (inout RunStyle, _ paragraphStyleID: String?) -> Void) {
        let selection = textView.selectedRange
        if selection.length == 0 {
            let paragraph = paragraphModel(for: paragraphRange(at: selection.location))
            var format = runBox(forTypingAt: selection.location).format
            change(&format.style, paragraph.properties.styleID)
            typingFormat = (format, selection.location, storage.length)
            textView.typingAttributes = typingAttributes(at: selection.location)
            publishSelection()
            return
        }
        storage.beginEditing()
        storage.enumerateAttribute(.librettoRun, in: selection) { value, range, _ in
            if storage.attribute(.attachment, at: range.location, effectiveRange: nil) is BlockAttachment { return }
            let box = value as? RunBox
            var format = box?.format ?? RunFormat()
            let paragraph = paragraphModel(for: paragraphRange(at: range.location))
            change(&format.style, paragraph.properties.styleID)
            storage.addAttribute(.librettoRun, value: RunBox(format, hyperlink: box?.hyperlink), range: range)
        }
        storage.endEditing()
        commit(restyling: selection, scope: .formatting)
    }

    /// Sets an on/off property, leaving it to the style where the style
    /// already says the same.
    private func setFlag(_ key: WritableKeyPath<RunStyle, Bool?>, to value: Bool) {
        let styles = document.styles
        editRuns { style, paragraphStyleID in
            var probe = style
            probe[keyPath: key] = nil
            let inherited = styles.resolvedRunStyle(probe, paragraphStyleID: paragraphStyleID)[keyPath: key] ?? false
            style[keyPath: key] = inherited == value ? nil : value
        }
    }

    func toggleBold() { setFlag(\.isBold, to: !(state?.selectionFormat.isBold ?? false)) }
    func toggleItalic() { setFlag(\.isItalic, to: !(state?.selectionFormat.isItalic ?? false)) }
    func toggleUnderline() { setFlag(\.underline, to: !(state?.selectionFormat.isUnderlined ?? false)) }
    func toggleStrikethrough() { setFlag(\.isStruckThrough, to: !(state?.selectionFormat.isStruckThrough ?? false)) }

    func toggleVerticalAlignment(_ position: RunStyle.VerticalPosition) {
        let isOn = state?.selectionFormat.verticalAlignment == position
        editRuns { style, _ in style.verticalAlignment = isOn ? nil : position }
    }

    /// Steps the font size, in points.
    func adjustFontSize(by points: Int) {
        let styles = document.styles
        editRuns { style, paragraphStyleID in
            let current = styles.resolvedRunStyle(style, paragraphStyleID: paragraphStyleID).fontSize ?? 22
            style.fontSize = min(192, max(2, current + points * 2))
        }
    }

    func setTextColor(_ hex: String?) {
        editRuns { style, _ in style.colorHex = hex.map { String($0.suffix(6)).uppercased() } }
    }

    func setHighlight(_ name: String?) {
        editRuns { style, _ in style.highlight = name }
    }

    func clearFormatting() {
        editRuns { style, _ in style = RunStyle() }
    }

    // MARK: - Paragraph formatting

    /// Changes the properties of every paragraph the selection touches.
    private func editParagraphs(scope: EditScope = .formatting, _ change: (inout ParagraphProperties) -> Void) {
        let selection = textView.selectedRange
        let string = storage.string as NSString
        var location = selection.location
        storage.beginEditing()
        repeat {
            let range = paragraphRange(at: location)
            defer { location = NSMaxRange(range) == location ? location + 1 : NSMaxRange(range) }
            guard !isBlockLine(range) else { continue }
            var paragraph = paragraphModel(for: range)
            change(&paragraph.properties)
            if range.length > 0 {
                storage.addAttribute(.librettoParagraph, value: ParagraphBox(paragraph), range: range)
            }
            if !hasMark(range) { finalParagraph = paragraph }
        } while location < NSMaxRange(selection) && location < string.length
        storage.endEditing()
        commit(restyling: selection, scope: scope)
    }

    func applyParagraphStyle(_ choice: ParagraphStyleChoice) {
        let id = document.styles.ensureStyle(choice)
        refreshContext()
        let isDefault = id == document.styles.defaultParagraphStyleID
        editParagraphs(scope: .paragraphStyle) { $0.styleID = isDefault ? nil : id }
    }

    func setAlignment(_ alignment: ParagraphAlignment) {
        editParagraphs { $0.alignment = alignment }
    }

    func cycleAlignment() {
        let order: [ParagraphAlignment] = [.leading, .center, .trailing, .justified]
        let current = state?.selectionFormat.alignment ?? .leading
        setAlignment(order[((order.firstIndex(of: current) ?? 0) + 1) % order.count])
    }

    func setSpacing(before: Int? = nil, after: Int? = nil, lineMultiple: Double? = nil) {
        editParagraphs { properties in
            if let before { properties.spacingBefore = before }
            if let after { properties.spacingAfter = after }
            if let lineMultiple { properties.lineSpacing = LineSpacing(line: Int(lineMultiple * 240), rule: .auto) }
        }
    }

    func toggleList(_ kind: ListKind) {
        let isOn = state?.selectionFormat.listKind == kind
        let styles = document.styles
        var numberingID = 0
        if !isOn {
            numberingID = neighbouringList(of: kind) ?? document.numbering.numberingID(for: kind)
            refreshContext()
        }
        editParagraphs(scope: .list) { properties in
            if isOn {
                var probe = properties
                probe.list = nil
                let styleHasList = Typography.listReference(styles.resolvedParagraphProperties(probe)) != nil
                properties.list = styleHasList ? ListReference(numberingID: 0, level: 0) : nil
            } else {
                properties.list = ListReference(numberingID: numberingID, level: properties.list?.level ?? 0)
            }
        }
    }

    private func toggleList(kindOf resolved: ParagraphProperties) {
        guard let list = Typography.listReference(resolved), let kind = document.numbering.kind(of: list.numberingID)
        else { return }
        toggleList(kind)
    }

    /// The list the paragraph before the selection is in, if it is of this
    /// kind, so a new item carries on its numbering.
    private func neighbouringList(of kind: ListKind) -> Int? {
        let start = paragraphRange(at: textView.selectedRange.location).location
        guard start > 0 else { return nil }
        let previous = paragraphModel(for: paragraphRange(at: start - 1))
        let resolved = document.styles.resolvedParagraphProperties(previous.properties)
        guard let list = Typography.listReference(resolved), document.numbering.kind(of: list.numberingID) == kind
        else { return nil }
        return list.numberingID
    }

    func indent(by step: Int) {
        let styles = document.styles
        editParagraphs { properties in
            let resolved = styles.resolvedParagraphProperties(properties)
            if let list = Typography.listReference(resolved) {
                properties.list = ListReference(numberingID: list.numberingID, level: min(8, max(0, list.level + step)))
            } else {
                properties.indentLeft = max(0, (properties.indentLeft ?? resolved.indentLeft ?? 0) + step * 720)
            }
        }
    }

    // MARK: - Inserting

    private func insert(_ text: NSAttributedString, at range: NSRange, selecting location: Int) {
        storage.replaceCharacters(in: range, with: text)
        textView.selectedRange = NSRange(location: min(location, storage.length), length: 0)
        storage.beginEditing()
        let changed = DocumentRenderer.relabel(storage, finalParagraph: finalParagraph, context: context)
        for range in changed {
            DocumentRenderer.restyle(storage, paragraphsIn: range, finalParagraph: finalParagraph, context: context)
        }
        storage.endEditing()
        relayout()
        sync(scope: .insertion)
        selectionDidChange()
    }

    func insertPageBreak() {
        let selection = textView.selectedRange
        let text = NSAttributedString(string: TextCharacters.pageBreak, attributes: typingAttributes(at: selection.location))
        insert(text, at: selection, selecting: selection.location + 1)
    }

    func insertTable(rows: Int, columns: Int) {
        let columnWidth = Int(geometry.contentWidth * 20) / max(1, columns)
        let table = Table(
            rows: (0..<rows).map { _ in
                TableRow(cells: (0..<columns).map { _ in TableCell(blocks: [.paragraph(Paragraph())]) })
            },
            gridColumns: Array(repeating: columnWidth, count: columns), preservedPropertiesXML: nil,
            styleID: nil, hasBorders: true
        )
        let block = DocumentRenderer.renderBlock(.table(table), context: context)
        let paragraph = paragraphRange(at: textView.selectedRange.location)
        let isEmpty = paragraph.length == (hasMark(paragraph) ? 1 : 0)
        if isEmpty, hasMark(paragraph) {
            // An empty paragraph makes way for the table.
            insert(block, at: NSRange(location: paragraph.location, length: 0), selecting: paragraph.location + block.length)
        } else if hasMark(paragraph) {
            let end = NSMaxRange(paragraph)
            insert(block, at: NSRange(location: end, length: 0), selecting: end + block.length)
        } else {
            // The last paragraph has no mark to put the table after; give it one.
            let output = NSMutableAttributedString(string: "\n", attributes: typingAttributes(at: NSMaxRange(paragraph)))
            output.append(block)
            insert(output, at: NSRange(location: NSMaxRange(paragraph), length: 0), selecting: NSMaxRange(paragraph) + output.length)
        }
    }

    func insertImage(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        var payload = data
        var fileExtension = "png"
        var contentType = "image/png"
        if let type = imageType(of: data), type.conforms(to: .jpeg) {
            fileExtension = "jpeg"
            contentType = "image/jpeg"
        } else if imageType(of: data)?.conforms(to: .png) != true {
            // Word reads PNG and JPEG everywhere; anything else is converted.
            guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return }
            payload = jpeg
            fileExtension = "jpeg"
            contentType = "image/jpeg"
        }
        let id = document.package.unusedRelationshipID()
        document.package.addedMedia[id] = DocumentPackage.AddedMedia(
            path: "word/media/libretto-\(UUID().uuidString.lowercased()).\(fileExtension)", data: payload,
            fileExtension: fileExtension, contentType: contentType
        )
        refreshContext()
        let scale = min(1, geometry.contentWidth / max(image.size.width, 1))
        let picture = InlineImage(
            relationshipID: id, width: image.size.width * scale, height: image.size.height * scale, xml: nil
        )
        let selection = textView.selectedRange
        let run = runBox(forTypingAt: selection.location)
        let inline = Inline(.image(picture), format: run.format)
        var attributes = typingAttributes(at: selection.location)
        attributes[.attachment] = DocumentRenderer.imageAttachment(picture, inline: inline, context: context)
        insert(
            NSAttributedString(string: TextCharacters.attachment, attributes: attributes),
            at: selection, selecting: selection.location + 1
        )
    }

    private func imageType(of data: Data) -> UTType? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        return nil
    }

    // MARK: - Tables

    /// The text range of a block's line, mark included.
    private func lineRange(ofBlock id: UUID) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(.librettoBlock, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let box = value as? BlockBox, box.block.id == id else { return }
            let line = paragraphRange(at: range.location)
            found = line
            stop.pointee = true
        }
        return found
    }

    var selectedTable: Table? {
        guard let id = state?.selectedTableID, let range = lineRange(ofBlock: id),
              let box = storage.attribute(.librettoBlock, at: NSMaxRange(range) - 1, effectiveRange: nil) as? BlockBox,
              case .table(let table) = box.block else { return nil }
        return table
    }

    func replaceTable(_ table: Table) {
        guard let range = lineRange(ofBlock: table.id) else { return }
        let selection = textView.selectedRange
        let rendered = DocumentRenderer.renderBlock(.table(table), context: context)
        storage.replaceCharacters(in: range, with: rendered)
        textView.selectedRange = NSRange(location: min(selection.location, range.location + rendered.length - 1), length: 0)
        relayout()
        sync(scope: .table)
        selectionDidChange()
    }

    func deleteSelectedTable() {
        guard let id = state?.selectedTableID, let range = lineRange(ofBlock: id) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString())
        textView.selectedRange = NSRange(location: min(range.location, storage.length), length: 0)
        relayout()
        sync(scope: .table)
        selectionDidChange()
    }
}

/// The text view the pages show. Its own undo is off: every change goes
/// through the document's history instead, as a snapshot of the document.
final class DocumentTextView: UITextView {
    weak var controller: DocumentTextController?
    private let disabledUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isScrollEnabled = false
        textContainerInset = .zero
        backgroundColor = .clear
        allowsEditingTextAttributes = false
        dataDetectorTypes = []
        smartInsertDeleteType = .no
        accessibilityIdentifier = "documentText"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var undoManager: UndoManager? { disabledUndoManager }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(boldCommand)),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(italicCommand)),
            UIKeyCommand(input: "u", modifierFlags: .command, action: #selector(underlineCommand)),
        ].map { command in
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func boldCommand() { controller?.toggleBold() }
    @objc private func italicCommand() { controller?.toggleItalic() }
    @objc private func underlineCommand() { controller?.toggleUnderline() }
}
