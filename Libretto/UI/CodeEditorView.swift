import SwiftUI
import UIKit

/// Code mode: a source file as a code editor shows it. The text runs the
/// width of the screen in a monospaced font, numbered line by line and
/// coloured by its syntax, and long lines scroll sideways rather than wrap.
struct CodeEditorView: UIViewRepresentable {
    @Binding var document: WordDocument
    var language: SourceLanguage
    var state: EditorState
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> CodeEditorController {
        CodeEditorController(document: document, language: language, scheme: colorScheme)
    }

    func makeUIView(context: Context) -> CodeEditorContainer {
        let controller = context.coordinator
        state.codeEditor = controller
        connect(controller)
        return controller.view
    }

    func updateUIView(_ view: CodeEditorContainer, context: Context) {
        let controller = context.coordinator
        connect(controller)
        controller.update(document: document, scheme: colorScheme)
    }

    static func dismantleUIView(_ view: CodeEditorContainer, coordinator: CodeEditorController) {
        // Typing not yet handed over would otherwise be lost with the view.
        coordinator.flush()
    }

    private func connect(_ controller: CodeEditorController) {
        let binding = $document
        let state = state
        controller.onChange = { document in
            state.pendingScope = .typing
            binding.wrappedValue = document
        }
    }
}

/// Keeps the code editor's text and the document in step.
///
/// The editor holds plain text. Typing is handed to the document a moment
/// later, as a paragraph for each line; a document changed from elsewhere,
/// such as by an undo, replaces the text.
@MainActor
final class CodeEditorController: NSObject, UITextViewDelegate {
    private(set) var document: WordDocument
    private let language: SourceLanguage
    private var scheme: ColorScheme
    let view: CodeEditorContainer
    private var textView: CodeTextView { view.textView }
    private var syncTask: Task<Void, Never>?
    /// Set while the editor makes an edit itself, so it is not taken for typing.
    private var isEditing = false

    /// Hands a changed document to whoever owns it.
    var onChange: ((WordDocument) -> Void)?

    init(document: WordDocument, language: SourceLanguage, scheme: ColorScheme) {
        self.document = document
        self.language = language
        self.scheme = scheme
        view = CodeEditorContainer()
        super.init()
        textView.delegate = self
        setText(PlainText.text(of: document))
    }

    /// Takes a document from the owner, showing its text if it is not the
    /// text the editor already has.
    func update(document new: WordDocument, scheme newScheme: ColorScheme) {
        let schemeChanged = newScheme != scheme
        scheme = newScheme
        guard new != document else {
            if schemeChanged { highlight() }
            return
        }
        document = new
        let text = PlainText.text(of: new)
        if text != textView.text {
            // The document's own version wins over typing not yet handed over.
            syncTask?.cancel()
            syncTask = nil
            setText(text)
        } else if schemeChanged {
            highlight()
        }
    }

    /// Hands over typing that is still waiting.
    func flush() {
        guard syncTask != nil else { return }
        sync()
    }

    private func setText(_ text: String) {
        let selection = textView.selectedRange
        textView.textStorage.setAttributedString(NSAttributedString(string: text, attributes: view.textAttributes))
        let length = (text as NSString).length
        let location = min(selection.location, length)
        textView.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
        textDidChange()
    }

    private func highlight() {
        SyntaxHighlighter.apply(language, to: textView.textStorage, scheme: scheme, plainColor: .label)
    }

    private func textDidChange() {
        highlight()
        view.textDidChange()
    }

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    private func sync() {
        syncTask?.cancel()
        syncTask = nil
        document.body = PlainText.body(from: textView.text, format: PlainText.codeFormat)
        onChange?(document)
    }

    // MARK: - Text view

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !isEditing, text == "\n" else { return true }
        // A new line starts as indented as the one it breaks.
        let string = textView.text as NSString
        let line = string.lineRange(for: NSRange(location: range.location, length: 0))
        let before = string.substring(with: NSRange(location: line.location, length: range.location - line.location))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        guard !indent.isEmpty else { return true }
        isEditing = true
        textView.insertText("\n" + indent)
        isEditing = false
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        // The typed text takes the editor's look, not the colour of what it follows.
        textView.typingAttributes = view.textAttributes
        textDidChange()
        scheduleSync()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        view.selectionDidChange()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        view.gutter.setNeedsDisplay()
    }
}

// MARK: - Views

/// The line numbers beside the text, and the text.
final class CodeEditorContainer: UIView {
    let textView: CodeTextView
    let gutter = LineNumberGutter()
    /// Scrolls the text sideways. The text view, as wide as its widest line,
    /// scrolls up and down within it, and the line numbers stay put.
    private let sideways = UIScrollView()
    /// Points, from the text's leading edge to the end of its widest line.
    private var widestLine: CGFloat = 0

    let font: UIFont = UIFontMetrics(forTextStyle: .body).scaledFont(
        for: .monospacedSystemFont(ofSize: 14, weight: .regular)
    )
    private var characterWidth: CGFloat { (" " as NSString).size(withAttributes: [.font: font]).width }

    /// How the text is set: tabs four characters wide, as most editors have them.
    var textAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = 4 * characterWidth
        style.tabStops = []
        style.lineHeightMultiple = 1.15
        return [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: style]
    }

    override init(frame: CGRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        layoutManager.addTextContainer(container)
        textView = CodeTextView(frame: .zero, textContainer: container)
        super.init(frame: frame)

        backgroundColor = .systemBackground
        textView.typingAttributes = textAttributes
        sideways.showsVerticalScrollIndicator = false
        sideways.alwaysBounceHorizontal = false
        sideways.isDirectionalLockEnabled = true
        sideways.contentInsetAdjustmentBehavior = .never
        sideways.addSubview(textView)
        gutter.textView = textView
        gutter.textFont = font
        gutter.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        )
        addSubview(sideways)
        addSubview(gutter)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gutterWidth = gutter.preferredWidth
        gutter.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        sideways.frame = CGRect(x: gutterWidth, y: 0, width: bounds.width - gutterWidth, height: bounds.height)
        // A character to spare, so the widest line never wraps for want of a fraction of a point.
        let inset = textView.textContainerInset
        let needed = ceil(widestLine + characterWidth + inset.left + inset.right
            + textView.textContainer.lineFragmentPadding * 2)
        let width = max(sideways.bounds.width, needed)
        textView.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        sideways.contentSize = CGSize(width: width, height: bounds.height)
    }

    func textDidChange() {
        let gutterWidth = gutter.preferredWidth
        let widest = widestLine
        gutter.textDidChange()
        widestLine = measureWidestLine()
        if gutter.preferredWidth != gutterWidth || widestLine != widest {
            setNeedsLayout()
            layoutIfNeeded()
        }
        gutter.setNeedsDisplay()
    }

    func selectionDidChange() {
        gutter.setNeedsDisplay()
        guard textView.isFirstResponder, let range = textView.selectedTextRange else { return }
        // Keep the caret in view sideways; the text view keeps it in view up and down.
        let caret = textView.caretRect(for: range.end)
        guard caret.minX.isFinite else { return }
        let margin = characterWidth * 4
        sideways.scrollRectToVisible(CGRect(x: caret.minX - margin, y: 0, width: margin * 2, height: 1), animated: false)
    }

    /// The widest line's width. Columns times the width of a character, the
    /// font being monospaced, except on lines with characters beyond ASCII,
    /// which may be wider and are measured.
    private func measureWidestLine() -> CGFloat {
        let string = textView.text as NSString
        let tabColumns = 4
        var widest: CGFloat = 0
        var columns = 0
        var lineStart = 0
        var isASCII = true
        func endLine(at end: Int) {
            if isASCII {
                widest = max(widest, CGFloat(columns) * characterWidth)
            } else {
                let line = string.substring(with: NSRange(location: lineStart, length: end - lineStart))
                    .replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabColumns))
                widest = max(widest, (line as NSString).size(withAttributes: [.font: font]).width)
            }
            columns = 0
            isASCII = true
            lineStart = end + 1
        }
        for index in 0..<string.length {
            switch string.character(at: index) {
            case 0x0A: endLine(at: index)
            case 0x09: columns += tabColumns - columns % tabColumns
            case let unit where unit >= 0x80:
                isASCII = false
                columns += 1
            default: columns += 1
            }
        }
        endLine(at: string.length)
        return widest
    }
}

/// The editor's text view: plain text only, with none of the help meant for prose.
final class CodeTextView: UITextView {
    /// Undo is the document's history's, which takes typing as it is handed over.
    private let disabledUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()

    override var undoManager: UndoManager? { disabledUndoManager }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .clear
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 120, right: 24)
        allowsEditingTextAttributes = false
        dataDetectorTypes = []
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        accessibilityIdentifier = "codeText"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// Numbers each line of the text view beside it, the line with the caret
/// in it brighter than the rest.
final class LineNumberGutter: UIView {
    weak var textView: UITextView?
    var font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    /// The text's font, whose baseline the numbers sit on.
    var textFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    /// Where each line starts, in UTF-16 offsets.
    private var lineStarts: [Int] = [0]
    private static let padding: CGFloat = 12

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        isOpaque = true
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Wide enough for the last line's number, and never narrower than three digits.
    var preferredWidth: CGFloat {
        let digits = max(3, String(lineStarts.count).count)
        let width = (String(repeating: "0", count: digits) as NSString).size(withAttributes: [.font: font]).width
        return ceil(width) + Self.padding * 2
    }

    func textDidChange() {
        guard let string = textView?.text as NSString? else { return }
        var starts = [0]
        var location = 0
        while location < string.length {
            let found = string.range(
                of: "\n", options: .literal, range: NSRange(location: location, length: string.length - location)
            )
            guard found.location != NSNotFound else { break }
            starts.append(found.location + 1)
            location = found.location + 1
        }
        lineStarts = starts
    }

    /// The index of the line holding the character at `location`.
    private func line(at location: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= location { low = middle } else { high = middle - 1 }
        }
        return low
    }

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        let layoutManager = textView.layoutManager
        let container = textView.textContainer
        let inset = textView.textContainerInset
        let top = textView.contentOffset.y - inset.top
        let caretLine = line(at: textView.selectedRange.location)

        func drawNumber(_ index: Int, in fragment: CGRect) {
            let isCaretLine = index == caretLine
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: isCaretLine ? UIColor.label : UIColor.secondaryLabel,
            ]
            let number = String(index + 1) as NSString
            let size = number.size(withAttributes: attributes)
            // Set on the text's baseline, whatever the two fonts' sizes.
            let baseline = fragment.minY - top + (fragment.height - textFont.lineHeight) / 2 + textFont.ascender
            number.draw(
                at: CGPoint(x: bounds.width - Self.padding - size.width, y: baseline - font.ascender),
                withAttributes: attributes
            )
        }

        let visible = CGRect(x: 0, y: top, width: container.size.width, height: bounds.height)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let location = layoutManager.characterIndexForGlyph(at: range.location)
            let line = self.line(at: location)
            // Only where a line starts, should one ever wrap.
            if self.lineStarts[line] == location { drawNumber(line, in: fragment) }
        }
        // The empty line after a final newline has a fragment of its own.
        let extra = layoutManager.extraLineFragmentRect
        if extra.height > 0, extra.maxY >= top, extra.minY <= top + bounds.height {
            drawNumber(lineStarts.count - 1, in: extra)
        }
    }
}
