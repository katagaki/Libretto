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
    var document: WordDocument
    var scheme: ColorScheme
    let storage = NSTextStorage()
    let layoutManager: PageLayoutManager
    let container = NSTextContainer()
    let textView: DocumentTextView
    let view: PagedDocumentView

    /// The last section's page, which a change of page setup is told by.
    private var baseGeometry: PageGeometry
    /// The pages as laid out, each section's at its own size.
    var geometry: PageGeometry { layoutManager.geometry }
    var context: RenderContext
    private let images = ImageStore()
    /// The body the text was last rendered from or read back as.
    private var lastBody: [Block] = []
    var finalParagraph = Paragraph()
    var trailingMarkers: [Inline] = []
    var pageCount = 1
    /// Each comment's text, by comment ID, as of the last layout.
    var commentRanges: [String: NSRange] = [:]
    /// When this editing session's tracked changes are dated: one date for
    /// them all, so what is typed in a session reads as one change.
    let revisionDate = Reviewer.now
    /// The table cell being edited where it is on the page, if one is.
    var cellSession: CellEditingSession?
    private var pendingInsertion: NSRange?
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
        baseGeometry = PageGeometry(setup: document.pageSetup, gap: PagedDocumentView.pageGap)
        let geometry = baseGeometry
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
        // A tap on a table cell edits it in place.
        let cellTap = UITapGestureRecognizer(target: self, action: #selector(tappedTableCell(_:)))
        cellTap.delegate = self
        textView.addGestureRecognizer(cellTap)
        render()
    }

    // MARK: - Rendering

    func refreshContext() {
        context = RenderContext(document: document, scheme: scheme, images: images)
        // Tables and pictures fit whichever page they fall on.
        context.contentWidth = min(baseGeometry.contentWidth, layoutManager.geometry.narrowestWidth)
        context.contentHeight = min(baseGeometry.contentHeight, layoutManager.geometry.contentHeight)
        layoutManager.styles = document.styles
        layoutManager.scheme = scheme
    }

    /// Renders the whole document into the text, keeping the selection
    /// roughly where it was.
    func render() {
        // The cell being edited is drawn afresh with the rest; what was typed in it is left to its session.
        if let session = cellSession {
            cellSession = nil
            session.editor.removeFromSuperview()
        }
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

    func relayout() {
        refreshCommentRanges()
        layoutManager.footnotes = NoteLayout.notes(in: storage, document: document, context: context)
        layoutManager.sections = SectionLayout.spans(in: storage, final: document.pageSetup)
        pageCount = layoutManager.layOutPages(in: container, startingWith: pageCount)
        view.update(
            geometry: geometry, pages: pageCount,
            texts: WordDocumentHeaderFooter(
                document: document, sections: layoutManager.sections.map(\.setup), pageSections: layoutManager.pageSections
            ),
            notes: PageNotes(byPage: layoutManager.notesByPage, heights: layoutManager.noteHeights)
        )
    }

    /// Takes a document from the owner, rendering it if it is not the one
    /// the text already shows.
    func update(document new: WordDocument, scheme newScheme: ColorScheme) {
        guard new != document || newScheme != scheme else { return }
        let newGeometry = PageGeometry(setup: new.pageSetup, gap: PagedDocumentView.pageGap)
        let needsRender = newScheme != scheme || newGeometry != baseGeometry || new.body != lastBody
            || new.styles != document.styles || new.numbering != document.numbering
        let marginsChanged = WordDocumentHeaderFooter(document: new) != WordDocumentHeaderFooter(document: document)
            || new.notes != document.notes
        if needsRender {
            // The document's own version wins over typing not yet handed over.
            syncTask?.cancel()
            syncTask = nil
        }
        document = new
        scheme = newScheme
        baseGeometry = newGeometry
        if needsRender {
            render()
        } else {
            refreshContext()
            if marginsChanged { relayout() }
        }
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

    func sync(scope: EditScope) {
        syncTask?.cancel()
        syncTask = nil
        let read = AttributedReader.blocks(
            from: storage, finalParagraph: finalParagraph, trailingMarkers: trailingMarkers
        )
        // Notes are numbered by where they are referred to; one gone or moved renumbers the rest.
        let references = NoteNumbering.references(in: read.blocks)
        let notesMoved = references != NoteNumbering.references(in: lastBody)
        if notesMoved {
            let referred = Set(references.map { "\($0.kind.rawValue):\($0.id)" })
            document.notes.removeAll { !referred.contains($0.key) }
        }
        document.body = read.blocks
        lastBody = read.blocks
        state?.pendingScope = scope
        onChange?(document)
        // Text typed beside a table, or rows taken out of one: the text no
        // longer looks like what it reads as, so show what it reads as.
        if read.needsRender || notesMoved { render() }
    }

    /// After a command changed the text's model: restyle, renumber, lay out, hand over.
    func commit(restyling range: NSRange, scope: EditScope) {
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
        // What UIKit is about to put in, which tracking marks as inserted once it is in.
        pendingInsertion = document.trackRevisions && !text.isEmpty
            ? NSRange(location: range.location, length: (text as NSString).length) : nil
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

        // While changes are tracked, what is taken out stays, marked deleted.
        if document.trackRevisions, range.length > 0, textView.markedTextRange == nil {
            trackedChange(in: range, replacement: replacement)
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
        // Find and Replace replaces text away from the selection, where the
        // typing attributes do not belong; the replacement looks like what it replaces.
        let isReplacingElsewhere = range.length > 0 && !replacement.isEmpty
            && range != textView.selectedRange && textView.markedTextRange == nil
        if target == range, replacement == text, !isReplacingElsewhere { return true }

        // Anything adjusted is inserted by hand, with the typing attributes.
        let attributes = typingAttributes(at: isReplacingElsewhere ? target.location + 1 : target.location)
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
        markPendingInsertion()
        textDidChange(touchingParagraphs: true)
    }

    /// UIKit puts typed text in with attributes of its own choosing; while
    /// changes are tracked, what it put in is an insertion.
    private func markPendingInsertion() {
        guard let pending = pendingInsertion, let revision = insertionRevision else { return }
        pendingInsertion = nil
        let range = NSIntersectionRange(pending, NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.librettoRun, in: range) { value, run, _ in
            let box = value as? RunBox
            guard box?.revision != revision else { return }
            storage.addAttribute(
                .librettoRun, value: RunBox(box?.format ?? RunFormat(), hyperlink: box?.hyperlink, revision: revision),
                range: run
            )
        }
        DocumentRenderer.restyle(storage, paragraphsIn: range, finalParagraph: finalParagraph, context: context)
        storage.endEditing()
    }

    func textDidChange(touchingParagraphs: Bool) {
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
            let box = value as? RunBox
            storage.addAttribute(
                .librettoRun, value: RunBox(typing.format, hyperlink: box?.hyperlink, revision: box?.revision), range: run
            )
        }
        DocumentRenderer.restyle(storage, paragraphsIn: range, finalParagraph: finalParagraph, context: context)
        storage.endEditing()
        textView.selectedRange = selection
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        selectionDidChange()
    }

    func selectionDidChange() {
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

    func hasMark(_ paragraph: NSRange) -> Bool {
        paragraph.length > 0
            && (storage.string as NSString).character(at: NSMaxRange(paragraph) - 1) == TextCharacters.paragraphBreakUnit
    }

    func isBlockLine(_ paragraph: NSRange) -> Bool {
        hasMark(paragraph) && storage.attribute(.librettoBlock, at: NSMaxRange(paragraph) - 1, effectiveRange: nil) != nil
    }

    func paragraphModel(for range: NSRange) -> Paragraph {
        DocumentRenderer.paragraphBox(in: storage, paragraphRange: range)?.paragraph ?? finalParagraph
    }

    func paragraphRange(at location: Int) -> NSRange {
        (storage.string as NSString).paragraphRange(for: NSRange(location: min(location, storage.length), length: 0))
    }

    /// The run formatting text typed at `location` takes: whatever was
    /// chosen for it, else the text before it in the same paragraph, else
    /// the paragraph's mark, which looks like the paragraph's last text.
    func runBox(forTypingAt location: Int) -> RunBox {
        let revision = insertionRevision
        if let typing = typingFormat, typing.location == location {
            return RunBox(typing.format, hyperlink: nil, revision: revision)
        }
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
            return RunBox(
                before.format, hyperlink: after?.hyperlink == before.hyperlink ? before.hyperlink : nil, revision: revision
            )
        }
        if let at = box(at: location) { return RunBox(at.format, hyperlink: nil, revision: revision) }
        return RunBox(RunFormat(), hyperlink: nil, revision: revision)
    }

    /// What text typed now is part of: an insertion, while changes are tracked.
    var insertionRevision: Revision? {
        document.trackRevisions ? Revision(kind: .insertion, author: Reviewer.name, date: revisionDate) : nil
    }

    func typingAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        let range = paragraphRange(at: location)
        let paragraph = isBlockLine(range) ? Paragraph() : paragraphModel(for: range)
        let label = range.length > 0
            ? storage.attribute(.librettoListLabel, at: range.location, effectiveRange: nil) as? ListLabelBox : nil
        let run = runBox(forTypingAt: location)
        var attributes = DocumentRenderer.paragraphAttributes(paragraph, label: label, context: context)
        attributes.merge(
            DocumentRenderer.runAttributes(
                run.format, hyperlink: run.hyperlink, revision: run.revision, paragraph: paragraph, context: context
            )
        ) { _, run in run }
        for key in librettoPositionalKeys { attributes[key] = nil }
        return attributes
    }

    func publishSelection() {
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
        result.fontName = run.fontName
        result.underlineKind = run.underline == true ? run.underlineStyle ?? "single" : "none"
        result.isDoubleStruckThrough = run.isDoubleStruckThrough ?? false
        result.smallCaps = run.smallCaps ?? false
        result.allCaps = run.allCaps ?? false
        result.outline = run.outline ?? false
        result.shadow = run.shadow ?? false
        result.emboss = run.emboss ?? false
        result.imprint = run.imprint ?? false
        result.characterSpacing = run.characterSpacing ?? 0
        result.position = run.position ?? 0
        result.colorHex = run.colorHex
        result.highlight = run.highlight
        result.alignment = resolvedParagraph.alignment ?? .leading
        result.styleChoice = styles.choice(forStyle: paragraph.properties.styleID)
        result.listKind = Typography.listReference(resolvedParagraph).flatMap { document.numbering.kind(of: $0.numberingID) }
        result.spacingBefore = resolvedParagraph.spacingBefore ?? 0
        result.spacingAfter = resolvedParagraph.spacingAfter ?? 0
        result.lineSpacing = resolvedParagraph.lineSpacing?.multiple ?? 1
        result.keepNext = resolvedParagraph.keepNext ?? false
        result.keepLines = resolvedParagraph.keepLines ?? false
        result.widowControl = resolvedParagraph.widowControl ?? false
        result.pageBreakBefore = resolvedParagraph.pageBreakBefore ?? false
        result.shadingHex = resolvedParagraph.shadingHex
        result.borders = resolvedParagraph.borders.flatMap { $0.isEmpty ? nil : $0 }
        result.tabStops = resolvedParagraph.tabStops ?? []
        result.dropCap = resolvedParagraph.dropCap
        if state.selectionFormat != result { state.selectionFormat = result }

        var table: Table.ID?
        if isBlockLine(range),
           let box = storage.attribute(.librettoBlock, at: NSMaxRange(range) - 1, effectiveRange: nil) as? BlockBox,
           case .table(let found) = box.block {
            table = found.id
        }
        if state.selectedTableID != table { state.selectedTableID = table }
        let isOnLink = selectedLink != nil
        if state.isOnLink != isOnLink { state.isOnLink = isOnLink }
        let isOnImage = selectedImage != nil
        if state.isOnImage != isOnImage { state.isOnImage = isOnImage }
        let isOnEquation = selectedEquation != nil
        if state.isOnEquation != isOnEquation { state.isOnEquation = isOnEquation }
        let isOnChange = revisionRange(around: selection.location) != nil
        if state.isOnChange != isOnChange { state.isOnChange = isOnChange }
        if state.isTracking != document.trackRevisions { state.isTracking = document.trackRevisions }
        publishSelectedComments()
    }

    // MARK: - Character formatting

    /// Changes the run formatting of the selection, or of what is typed next
    /// when nothing is selected.
    func editRuns(_ change: (inout RunStyle, _ paragraphStyleID: String?) -> Void) {
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
            storage.addAttribute(
                .librettoRun, value: RunBox(format, hyperlink: box?.hyperlink, revision: box?.revision), range: range
            )
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

    /// Underlines in one of Word's kinds, or, with `none`, takes the underline away.
    func setUnderline(_ kind: String) {
        let styles = document.styles
        editRuns { style, paragraphStyleID in
            if kind == "none" {
                var probe = style
                probe.underline = nil
                style.underline = styles.resolvedRunStyle(probe, paragraphStyleID: paragraphStyleID).underline == true
                    ? false : nil
                style.underlineStyle = nil
            } else {
                style.underline = true
                style.underlineStyle = kind == "single" ? nil : kind
            }
        }
    }

    /// Turns an on/off effect, such as small capitals or an outline, on or off.
    func setEffect(_ key: WritableKeyPath<RunStyle, Bool?>, _ isOn: Bool) {
        setFlag(key, to: isOn)
    }

    func setCharacterSpacing(_ twips: Int) {
        editRuns { style, _ in style.characterSpacing = twips == 0 ? nil : twips }
    }

    func setPosition(_ halfPoints: Int) {
        editRuns { style, _ in style.position = halfPoints == 0 ? nil : halfPoints }
    }

    /// Sets the font family, or one of the theme's by its `+minor` or `+major` stand-in.
    func setFont(_ name: String?) {
        editRuns { style, _ in style.fontName = name }
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
    func editParagraphs(scope: EditScope = .formatting, _ change: (inout ParagraphProperties) -> Void) {
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

    /// The style of the paragraph at `location`, if it names one.
    func paragraphStyleID(at location: Int) -> String? {
        paragraphModel(for: paragraphRange(at: location)).properties.styleID
    }

    /// Puts the selected paragraphs in a style of the document's, by ID.
    func applyParagraphStyle(id: String) {
        let isDefault = id == document.styles.defaultParagraphStyleID
        editParagraphs(scope: .paragraphStyle) { $0.styleID = isDefault ? nil : id }
    }

    /// Changes a style's definition, and so every paragraph in it.
    func modifyStyle(_ id: String, _ change: (inout StyleSheet.Style) -> Void) {
        flush()
        guard var style = document.styles.styles[id] else { return }
        change(&style)
        document.styles.styles[id] = style
        state?.pendingScope = .paragraphStyle
        render()
        onChange?(document)
    }

    /// The paragraph at the selection's own formatting, and its first run's, for a style to take on.
    private var selectionFormatting: (paragraph: ParagraphProperties, run: RunStyle, styleID: String?) {
        let location = textView.selectedRange.location
        let paragraph = paragraphModel(for: paragraphRange(at: location))
        var properties = paragraph.properties
        let styleID = properties.styleID ?? document.styles.defaultParagraphStyleID
        properties.styleID = nil
        properties.list = nil
        var run = runBox(forTypingAt: textView.selectedRange.length > 0 ? location + 1 : location).format.style
        run.characterStyleID = nil
        return (properties, run, styleID)
    }

    /// Makes a style of the selection's formatting, and puts its paragraphs in it.
    @discardableResult
    func createStyleFromSelection(name: String) -> String {
        let formatting = selectionFormatting
        let id = document.styles.createParagraphStyle(
            name: name, basedOn: formatting.styleID, paragraph: formatting.paragraph, run: formatting.run
        )
        refreshContext()
        // The style now says what the paragraph's own formatting did.
        editParagraphs(scope: .paragraphStyle) { properties in
            properties = ParagraphProperties(styleID: id, list: properties.list)
        }
        return id
    }

    /// Redefines a style as the selection is formatted.
    func updateStyleToMatchSelection(_ id: String) {
        let formatting = selectionFormatting
        modifyStyle(id) { style in
            style.paragraphProperties = style.paragraphProperties.merged(with: formatting.paragraph)
            style.runStyle = style.runStyle.merged(with: formatting.run)
        }
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

    /// Turns an on/off paragraph setting, such as keeping with the next, on
    /// or off, leaving it to the style where the style already says the same.
    func setParagraphFlag(_ key: WritableKeyPath<ParagraphProperties, Bool?>, _ isOn: Bool) {
        let styles = document.styles
        editParagraphs { properties in
            var probe = properties
            probe[keyPath: key] = nil
            let inherited = styles.resolvedParagraphProperties(probe)[keyPath: key] ?? false
            properties[keyPath: key] = inherited == isOn ? nil : isOn
        }
    }

    func setShading(_ hex: String?) {
        editParagraphs { $0.shadingHex = hex.map { String($0.suffix(6)).uppercased() } }
    }

    /// Borders around the paragraphs; none at all takes away any the style gives.
    func setBorders(_ borders: ParagraphBorders) {
        editParagraphs { $0.borders = borders }
    }

    /// Starts the paragraph at the selection with a drop cap, changes the one
    /// it has, or, with `nil`, sets the letter back into the paragraph. As in
    /// Word, the letter is a paragraph of its own, before the one it starts.
    func setDropCap(_ dropCap: DropCap?) {
        let styles = document.styles
        let string = storage.string as NSString
        var range = paragraphRange(at: textView.selectedRange.location)
        func isDropCap(_ range: NSRange) -> Bool {
            styles.resolvedParagraphProperties(paragraphModel(for: range).properties).dropCap != nil
        }
        if !isDropCap(range), range.location > 0 {
            let previous = paragraphRange(at: range.location - 1)
            if isDropCap(previous) { range = previous }
        }
        if isDropCap(range) {
            if let dropCap {
                var paragraph = paragraphModel(for: range)
                paragraph.properties.dropCap = dropCap
                storage.addAttribute(.librettoParagraph, value: ParagraphBox(paragraph), range: range)
            } else if hasMark(range) {
                // The letter joins the paragraph after it again.
                storage.deleteCharacters(in: NSRange(location: NSMaxRange(range) - 1, length: 1))
            }
            commit(restyling: range, scope: .formatting)
            return
        }
        guard let dropCap, range.length > (hasMark(range) ? 1 : 0), !isBlockLine(range) else { return }
        let first = string.rangeOfComposedCharacterSequence(at: range.location)
        guard string.character(at: first.location) != TextCharacters.paragraphBreakUnit else { return }
        var letter = paragraphModel(for: range).splitCopy()
        letter.properties.dropCap = dropCap
        letter.properties.list = nil
        storage.beginEditing()
        storage.addAttribute(.librettoParagraph, value: ParagraphBox(letter), range: first)
        var mark = storage.attributes(at: first.location, effectiveRange: nil)
        for key in librettoPositionalKeys { mark[key] = nil }
        storage.insert(NSAttributedString(string: "\n", attributes: mark), at: NSMaxRange(first))
        storage.endEditing()
        commit(restyling: NSRange(location: range.location, length: range.length + 1), scope: .formatting)
    }

    /// Sets the tab stops the paragraphs end up with: their own, and clearing
    /// any of their style's that are not among them.
    func setTabStops(_ stops: [TabStop]) {
        let styles = document.styles
        editParagraphs { properties in
            var probe = properties
            probe.tabStops = nil
            let inherited = styles.resolvedParagraphProperties(probe).tabStops ?? []
            let cleared = inherited.filter { !stops.contains($0) }.map { TabStop(position: $0.position, alignment: .clear) }
            let own = stops.filter { !inherited.contains($0) }
            let result = (own + cleared).sorted { $0.position < $1.position }
            properties.tabStops = result.isEmpty ? nil : result
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

    /// Puts the selected paragraphs in a new list of a preset's bullets or numbering, keeping their levels.
    func applyListPreset(_ preset: ListPreset) {
        let styles = document.styles
        let id = document.numbering.addList(levels: preset.levels, kind: preset.kind)
        refreshContext()
        editParagraphs(scope: .list) { properties in
            let level = Typography.listReference(styles.resolvedParagraphProperties(properties))?.level ?? 0
            properties.list = ListReference(numberingID: id, level: level)
        }
    }

    /// Starts the list the selection is in over, at `start`, from its paragraph on.
    func restartNumbering(at start: Int = 1) {
        let range = paragraphRange(at: textView.selectedRange.location)
        let resolved = document.styles.resolvedParagraphProperties(paragraphModel(for: range).properties)
        guard let list = Typography.listReference(resolved),
              let restarted = document.numbering.restartList(list.numberingID, level: list.level, at: start) else { return }
        refreshContext()
        moveList(from: range.location, numberingID: list.numberingID, to: restarted)
    }

    /// Carries on the numbering of the list of the same kind before the one the selection is in.
    func continueNumbering() {
        let range = paragraphRange(at: textView.selectedRange.location)
        let styles = document.styles
        guard let list = Typography.listReference(styles.resolvedParagraphProperties(paragraphModel(for: range).properties)),
              let kind = document.numbering.kind(of: list.numberingID) else { return }
        var location = range.location
        while location > 0 {
            let previous = paragraphRange(at: location - 1)
            location = previous.location
            guard !isBlockLine(previous),
                  let other = Typography.listReference(styles.resolvedParagraphProperties(paragraphModel(for: previous).properties)),
                  other.numberingID != list.numberingID, document.numbering.kind(of: other.numberingID) == kind else { continue }
            moveList(from: range.location, numberingID: list.numberingID, to: other.numberingID)
            return
        }
    }

    /// Moves the paragraphs of a list, from `location` on, into another list.
    private func moveList(from location: Int, numberingID old: Int, to new: Int) {
        let styles = document.styles
        var current = location
        storage.beginEditing()
        while current < storage.length {
            let range = paragraphRange(at: current)
            guard range.length > 0 else { break }
            current = NSMaxRange(range)
            guard !isBlockLine(range) else { continue }
            var paragraph = paragraphModel(for: range)
            guard let list = Typography.listReference(styles.resolvedParagraphProperties(paragraph.properties)),
                  list.numberingID == old else { continue }
            paragraph.properties.list = ListReference(numberingID: new, level: list.level)
            storage.addAttribute(.librettoParagraph, value: ParagraphBox(paragraph), range: range)
            if !hasMark(range) { finalParagraph = paragraph }
        }
        storage.endEditing()
        commit(restyling: NSRange(location: location, length: storage.length - location), scope: .list)
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

    func insert(_ text: NSAttributedString, at range: NSRange, selecting location: Int) {
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

    /// Puts a character in at the selection, as if typed.
    func insertSymbol(_ symbol: String) {
        let selection = textView.selectedRange
        let text = NSAttributedString(string: symbol, attributes: typingAttributes(at: selection.location))
        insert(text, at: selection, selecting: selection.location + (symbol as NSString).length)
    }

    func insertPageBreak() {
        let selection = textView.selectedRange
        let text = NSAttributedString(string: TextCharacters.pageBreak, attributes: typingAttributes(at: selection.location))
        insert(text, at: selection, selecting: selection.location + 1)
    }

    func insertTable(rows: Int, columns: Int) {
        let columnWidth = Int(context.contentWidth * 20) / max(1, columns)
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
        let scale = min(1, context.contentWidth / max(image.size.width, 1))
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

    // MARK: - Links

    /// The link at the selection, and the whole of the text it covers.
    var selectedLink: (link: Hyperlink, range: NSRange)? {
        let selection = textView.selectedRange
        let paragraph = paragraphRange(at: selection.location)
        // At a link's end, the caret is still in it.
        for index in [selection.location, selection.location - 1]
        where index >= paragraph.location && index < NSMaxRange(paragraph) && index < storage.length {
            guard let link = (storage.attribute(.librettoRun, at: index, effectiveRange: nil) as? RunBox)?.hyperlink
            else { continue }
            var start = index
            var end = index + 1
            func linked(_ location: Int) -> Bool {
                (storage.attribute(.librettoRun, at: location, effectiveRange: nil) as? RunBox)?.hyperlink == link
            }
            while start > paragraph.location, linked(start - 1) { start -= 1 }
            while end < NSMaxRange(paragraph), linked(end) { end += 1 }
            return (link, NSRange(location: start, length: end - start))
        }
        return nil
    }

    /// What the link panel starts with: the link being edited, if any, and the text it would cover.
    var linkContext: (link: Hyperlink?, text: String) {
        let string = storage.string as NSString
        if let (link, range) = selectedLink { return (link, string.substring(with: range)) }
        let selection = textView.selectedRange
        let text = string.substring(with: selection).components(separatedBy: .newlines).first ?? ""
        return (nil, text)
    }

    /// An address as typed, as the link Word reads: a bookmark for `#name`,
    /// mail for an address with `@`, the web for the rest.
    static func linkTarget(_ address: String) -> (url: String?, anchor: String?) {
        let trimmed = address.trimmed
        if trimmed.hasPrefix("#") { return (nil, String(trimmed.dropFirst())) }
        if trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil { return (trimmed, nil) }
        if trimmed.contains("@"), !trimmed.contains("/") { return ("mailto:" + trimmed, nil) }
        return ("https://" + trimmed, nil)
    }

    /// Links the selection, or the link it is in, to `address`, showing
    /// `text`; with nothing selected, inserts `text` as a link.
    func makeLink(address: String, text: String) {
        let target = Self.linkTarget(address)
        var hyperlink: Hyperlink
        if let anchor = target.anchor {
            hyperlink = Hyperlink(
                relationshipID: nil, anchor: anchor, url: nil,
                attributesXML: " w:anchor=\"\(XMLLite.escape(anchor))\" w:history=\"1\""
            )
        } else {
            let address = target.url ?? ""
            let id = document.package.unusedRelationshipID()
            document.package.addedLinks[id] = address
            hyperlink = Hyperlink(
                relationshipID: id, anchor: nil, url: URL(string: address),
                attributesXML: " r:id=\"\(id)\" w:history=\"1\""
            )
        }
        refreshContext()
        let linkStyle = document.styles.styles.values.first { $0.kind == .character && $0.name == "Hyperlink" }?.id
        func linked(_ format: RunFormat) -> RunFormat {
            var format = format
            if let linkStyle { format.style.characterStyleID = linkStyle }
            return format
        }

        var range = selectedLink?.range ?? textView.selectedRange
        let shown = text.isEmpty ? address.trimmed : text
        let current = (storage.string as NSString).substring(with: range)
        if range.length == 0 || (shown != current && !shown.contains("\n")) {
            // New text for the link, looking like the text it replaces or follows.
            var attributes = typingAttributes(at: range.length > 0 ? range.location + 1 : range.location)
            let run = (attributes[.librettoRun] as? RunBox)?.format ?? RunFormat()
            attributes[.librettoRun] = RunBox(linked(run), hyperlink: hyperlink, revision: insertionRevision)
            storage.replaceCharacters(in: range, with: NSAttributedString(string: shown, attributes: attributes))
            range = NSRange(location: range.location, length: (shown as NSString).length)
        } else {
            storage.beginEditing()
            storage.enumerateAttribute(.librettoRun, in: range) { value, run, _ in
                if storage.attribute(.attachment, at: run.location, effectiveRange: nil) is BlockAttachment { return }
                let box = value as? RunBox
                storage.addAttribute(
                    .librettoRun, value: RunBox(linked(box?.format ?? RunFormat()), hyperlink: hyperlink, revision: box?.revision),
                    range: run
                )
            }
            storage.endEditing()
        }
        textView.selectedRange = NSRange(location: NSMaxRange(range), length: 0)
        commit(restyling: range, scope: .formatting)
    }

    /// Unlinks the link at the selection, leaving its text.
    func removeLink() {
        guard let (link, range) = selectedLink else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.librettoRun, in: range) { value, run, _ in
            guard let box = value as? RunBox, box.hyperlink == link else { return }
            var format = box.format
            if let style = format.style.characterStyleID,
               document.styles.styles[style]?.name == "Hyperlink" { format.style.characterStyleID = nil }
            storage.addAttribute(.librettoRun, value: RunBox(format, hyperlink: nil, revision: box.revision), range: run)
        }
        storage.endEditing()
        commit(restyling: range, scope: .formatting)
    }

    // MARK: - Tables

    /// The text range of a block's line, mark included.
    func lineRange(ofBlock id: UUID) -> NSRange? {
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

    // MARK: - Finding

    /// Opens the find bar, with replacing, over the keyboard.
    func showFind() {
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
        textView.findInteraction?.presentFindNavigator(showingReplace: true)
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
        // ⌘F and the More menu's Find and Replace.
        isFindInteractionEnabled = true
        // A drop cap set in the margin is drawn beside the text, outside it.
        clipsToBounds = false
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
            UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(linkCommand)),
        ].map { command in
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func boldCommand() { controller?.toggleBold() }
    @objc private func italicCommand() { controller?.toggleItalic() }
    // The floating bar gives way to the find bar while it is open.
    override func findInteraction(_ interaction: UIFindInteraction, didBegin session: UIFindSession) {
        super.findInteraction(interaction, didBegin: session)
        controller?.state?.isFinding = true
    }

    override func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
        super.findInteraction(interaction, didEnd: session)
        controller?.state?.isFinding = false
    }

    @objc private func underlineCommand() { controller?.toggleUnderline() }
    @objc private func linkCommand() { controller?.state?.presentedPanel = .link }
}
