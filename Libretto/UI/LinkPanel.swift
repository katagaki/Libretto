import SwiftUI

/// Makes a link of the selection, edits the link it is in, or takes it away.
struct LinkPanel: View {
    @Bindable var state: EditorState
    @Environment(\.openURL) private var openURL
    @State private var address = ""
    @State private var text = ""
    @State private var existing: Hyperlink?

    private var controller: DocumentTextController? { state.controller }

    var body: some View {
        Form {
            Section {
                TextField("Link.Address", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("link.address")
                TextField("Link.Text", text: $text)
                    .accessibilityIdentifier("link.text")
            } footer: {
                Text("Link.Footer")
            }
            Section {
                Button(existing == nil ? "Link.Insert" : "Link.Update") {
                    controller?.makeLink(address: address, text: text)
                    state.presentedPanel = nil
                }
                .disabled(address.trimmed.isEmpty)
                .accessibilityIdentifier("link.confirm")
                if let url = existing?.url {
                    Button("Link.Open", systemImage: "safari") { openURL(url) }
                }
                if existing != nil {
                    Button("Link.Remove", systemImage: "link.badge.minus", role: .destructive) {
                        controller?.removeLink()
                        state.presentedPanel = nil
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard let context = controller?.linkContext else { return }
            existing = context.link
            text = context.text
            if let link = context.link {
                address = link.anchor.map { "#" + $0 } ?? link.url?.absoluteString ?? ""
            }
        }
    }
}
