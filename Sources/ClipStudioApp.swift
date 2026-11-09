import SwiftUI

@main
struct ClipStudioApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @StateObject private var editor = Editor()

    var body: some View {
        Group {
            if editor.hasProject {
                EditorView(editor: editor)
            } else {
                HomeView(editor: editor)
            }
        }
    }
}
