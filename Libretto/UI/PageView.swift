import SwiftUI

/// Full document mode: the document's pages at their own size, editable.
struct PageView: UIViewRepresentable {
    @Binding var document: WordDocument
    var state: EditorState
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> DocumentTextController {
        DocumentTextController(document: document, scheme: colorScheme)
    }

    func makeUIView(context: Context) -> PagedDocumentView {
        let controller = context.coordinator
        controller.state = state
        state.controller = controller
        connect(controller)
        if state.wantsFind {
            state.wantsFind = false
            // Once the view is in a window, where it can take the keyboard.
            DispatchQueue.main.async { controller.showFind() }
        }
        return controller.view
    }

    func updateUIView(_ view: PagedDocumentView, context: Context) {
        let controller = context.coordinator
        connect(controller)
        controller.update(document: document, scheme: colorScheme)
    }

    static func dismantleUIView(_ view: PagedDocumentView, coordinator: DocumentTextController) {
        // Typing not yet handed over would otherwise be lost with the view.
        coordinator.flush()
    }

    private func connect(_ controller: DocumentTextController) {
        let binding = $document
        controller.onChange = { binding.wrappedValue = $0 }
    }
}
