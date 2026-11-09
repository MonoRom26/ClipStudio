import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject var editor: Editor
    @State private var sheet: ImportSheet?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "film")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            Text("Clip Studio").font(.largeTitle).bold()
            Text("Import one or more videos to start a project.")
                .font(.subheadline).foregroundColor(.secondary)

            VStack(spacing: 12) {
                Button(action: { sheet = .photos }) {
                    Label("Import from Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledStyle(color: .blue))

                Button(action: { sheet = .files }) {
                    Label("Import from Files", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledStyle(color: .purple))
            }
            .padding(.horizontal, 30)

            if !editor.message.isEmpty {
                Text(editor.message).font(.footnote).foregroundColor(.red)
            }
            Spacer()
            Text("Everything runs on your iPhone. No internet needed.")
                .font(.footnote).foregroundColor(.secondary)
                .padding(.bottom, 16)
        }
        .padding()
        .sheet(item: $sheet) { s in
            switch s {
            case .photos:
                VideoPhotosPicker(limit: 0,
                                  onPick: { urls in sheet = nil; editor.importVideos(urls) },
                                  onCancel: { sheet = nil })
            case .files:
                FilePicker(types: [UTType.movie], multiple: true,
                           onPick: { urls in sheet = nil; editor.importVideos(urls) },
                           onCancel: { sheet = nil })
            default:
                EmptyView()
            }
        }
    }
}

struct FilledStyle: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1))
            .cornerRadius(12)
    }
}
