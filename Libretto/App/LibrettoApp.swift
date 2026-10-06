import SwiftUI

@main
struct LibrettoApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: LibrettoDocument()) { configuration in
            DocumentView(document: configuration.$document, fileName: configuration.fileURL?.lastPathComponent)
        }
    }
}
