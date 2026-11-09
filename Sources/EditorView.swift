import SwiftUI
import UniformTypeIdentifiers

enum Panel: String, Identifiable {
    case trim, speed, volume, crop, adjust, filter, effect, overlayEdit, audioEdit
    case canvas, removeText, enhance, addMedia, stickers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trim: return "Trim"
        case .speed: return "Speed"
        case .volume: return "Volume"
        case .crop: return "Crop"
        case .adjust: return "Adjust"
        case .filter: return "Filters"
        case .effect: return "Effects"
        case .overlayEdit: return "Edit layer"
        case .audioEdit: return "Edit music"
        case .canvas: return "Canvas"
        case .removeText: return "Remove text"
        case .enhance: return "Enhance HD"
        case .addMedia: return "Add media"
        case .stickers: return "Stickers"
        }
    }
}

struct ToolItem: Identifiable {
    let id: String
    let icon: String
    var on = false
    var disabled = false
    let action: () -> Void
    init(_ title: String, _ icon: String, on: Bool = false, disabled: Bool = false,
         action: @escaping () -> Void) {
        self.id = title
        self.icon = icon
        self.on = on
        self.disabled = disabled
        self.action = action
    }
}

struct EditorView: View {
    @ObservedObject var editor: Editor
    @State private var panel: Panel?
    @State private var sheet: ImportSheet?
    @State private var drawMode = false
    @State private var drawStart: CGPoint?
    @State private var drawCurrent: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
            controls
            if !editor.message.isEmpty {
                Text(editor.message)
                    .font(.footnote).foregroundColor(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            TimelineStrip(editor: editor).frame(height: 182)
            Divider()
            bottom
        }
        .sheet(item: $sheet) { s in
            sheetContent(s)
        }
        .onDisappear { editor.pause() }
    }

    // MARK: sheets
    @ViewBuilder
    private func sheetContent(_ s: ImportSheet) -> some View {
        switch s {
        case .photos:
            VideoPhotosPicker(limit: 0,
                              onPick: { urls in sheet = nil; panel = nil; editor.importVideos(urls) },
                              onCancel: { sheet = nil })
        case .files:
            FilePicker(types: [.movie], multiple: true,
                       onPick: { urls in sheet = nil; panel = nil; editor.importVideos(urls) },
                       onCancel: { sheet = nil })
        case .replace:
            VideoPhotosPicker(limit: 1,
                              onPick: { urls in sheet = nil; if let u = urls.first { editor.replaceMedia(url: u) } },
                              onCancel: { sheet = nil })
        case .image:
            ImagePhotosPicker(onPick: { img in sheet = nil; editor.addImageOverlay(img); panel = .overlayEdit },
                              onCancel: { sheet = nil })
        case .music:
            FilePicker(types: [.audio], multiple: false,
                       onPick: { urls in
                           sheet = nil
                           if let u = urls.first { editor.addMusic(url: u); panel = .audioEdit }
                       },
                       onCancel: { sheet = nil })
        case .export:
            ExportSheet(editor: editor, onClose: { sheet = nil })
        }
    }

    // MARK: top bar
    private var topBar: some View {
        HStack(spacing: 16) {
            Button(action: { editor.close() }) { Image(systemName: "xmark").font(.headline) }
            Spacer()
            Button(action: { editor.undo() }) { Image(systemName: "arrow.uturn.backward").font(.headline) }
                .disabled(editor.undoCount == 0)
            Button(action: { editor.redo() }) { Image(systemName: "arrow.uturn.forward").font(.headline) }
                .disabled(editor.redoCount == 0)
            Button(action: { editor.exportState = .idle; sheet = .export }) {
                Text("Export").bold()
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.blue).foregroundColor(.white)
                    .cornerRadius(14)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: preview
    private var preview: some View {
        ZStack {
            Color.black
            if editor.tl.clips.isEmpty {
                Text("Open Add media to start").foregroundColor(.white).font(.footnote)
            } else {
                PlayerView(player: editor.player)
            }
        }
        .aspectRatio(editor.canvasAspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: UIScreen.main.bounds.height * 0.34)
        .overlay(GeometryReader { g in interactionLayer(g.size) })
    }

    private func interactionLayer(_ size: CGSize) -> some View {
        ZStack {
            if panel == .removeText {
                ForEach(editor.tl.regions) { r in
                    Rectangle()
                        .stroke(r.enabled ? Color.red : Color.gray, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                        .frame(width: r.rect.width * size.width, height: r.rect.height * size.height)
                        .position(x: r.rect.midX * size.width, y: r.rect.midY * size.height)
                }
                if let a = drawStart, let b = drawCurrent {
                    Rectangle()
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                        .frame(width: abs(b.x - a.x), height: abs(b.y - a.y))
                        .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                }
            }
            if editor.focus == .overlay, let id = editor.selectedOverlay,
               let o = editor.tl.overlays.first(where: { $0.id == id }) {
                let box = editor.overlayBoxes[o.id] ?? CGSize(width: 0.2, height: 0.1)
                Rectangle()
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .frame(width: box.width * size.width, height: box.height * size.height)
                    .rotationEffect(.degrees(o.rotation))
                    .position(x: CGFloat(o.x) * size.width, y: CGFloat(o.y) * size.height)
            }
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in drag(v, size, ended: false) }
                    .onEnded { v in drag(v, size, ended: true) })
        }
        .frame(width: size.width, height: size.height)
    }

    private func drag(_ v: DragGesture.Value, _ size: CGSize, ended: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, 0), size.width), y: min(max(p.y, 0), size.height))
        }
        if editor.focus == .overlay {
            let p = clamp(v.location)
            editor.moveSelectedOverlay(x: Double(p.x / size.width), y: Double(p.y / size.height))
        } else if panel == .removeText && drawMode {
            let a = clamp(v.startLocation)
            let b = clamp(v.location)
            if ended {
                let r = CGRect(x: min(a.x, b.x) / size.width, y: min(a.y, b.y) / size.height,
                               width: abs(b.x - a.x) / size.width, height: abs(b.y - a.y) / size.height)
                if r.width > 0.01 && r.height > 0.01 { editor.addRegion(r) }
                drawStart = nil
                drawCurrent = nil
            } else {
                drawStart = a
                drawCurrent = b
            }
        }
    }

    // MARK: playback controls
    private var controls: some View {
        HStack(spacing: 14) {
            Text(timeString(editor.currentTime) + " / " + timeString(editor.tl.duration))
                .font(.system(size: 12, design: .monospaced))
            Spacer()
            Button(action: { editor.step(-1) }) { Image(systemName: "backward.frame.fill") }
            Button(action: { editor.togglePlay() }) {
                Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill").font(.title2)
            }
            Button(action: { editor.step(1) }) { Image(systemName: "forward.frame.fill") }
            Spacer()
            Button(action: { editor.zoom(0.7) }) { Image(systemName: "minus.magnifyingglass") }
            Button(action: { editor.zoom(1.4) }) { Image(systemName: "plus.magnifyingglass") }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func timeString(_ t: Double) -> String {
        let v = max(0, t)
        return String(format: "%d:%05.2f", Int(v) / 60, v.truncatingRemainder(dividingBy: 60))
    }

    // MARK: bottom (tool strip or panel)
    @ViewBuilder
    private var bottom: some View {
        if let p = panel {
            VStack(spacing: 0) {
                HStack {
                    Text(p.title).font(.headline)
                    Spacer()
                    Button(action: { panel = nil; drawMode = false }) {
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundColor(.blue)
                    }
                }
                .padding(.horizontal).padding(.vertical, 6)
                Divider()
                ScrollView { panelContent(p).padding() }
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { t in
                        Button(action: t.action) {
                            VStack(spacing: 3) {
                                Image(systemName: t.icon).font(.title3)
                                Text(t.id).font(.system(size: 10)).lineLimit(1)
                            }
                            .frame(width: 66, height: 52)
                            .foregroundColor(t.on ? .white : .primary)
                            .background(t.on ? Color.blue : Color(.secondarySystemBackground))
                            .cornerRadius(10)
                            .opacity(t.disabled ? 0.35 : 1)
                        }
                        .disabled(t.disabled)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            Spacer(minLength: 0)
        }
    }

    private var items: [ToolItem] {
        var list: [ToolItem] = []
        switch editor.focus {
        case .clip:
            list.append(ToolItem("Split", "scissors") { editor.splitAtPlayhead() })
            list.append(ToolItem("Trim", "crop") { panel = .trim })
            list.append(ToolItem("Speed", "speedometer") { panel = .speed })
            list.append(ToolItem("Volume", "speaker.wave.2") { panel = .volume })
            list.append(ToolItem("Crop", "crop.rotate") { panel = .crop })
            list.append(ToolItem("Adjust", "slider.horizontal.3") { panel = .adjust })
            list.append(ToolItem("Filters", "camera.filters") { panel = .filter })
            list.append(ToolItem("Effects", "wand.and.stars") { panel = .effect })
            list.append(ToolItem("Freeze", "pause.circle") { editor.freezeFrame() })
            list.append(ToolItem("Rotate", "rotate.right") { editor.rotateSelected() })
            list.append(ToolItem("Flip", "arrow.left.arrow.right") { editor.flipSelected() })
            list.append(ToolItem("Duplicate", "plus.square.on.square") { editor.duplicateSelection() })
            list.append(ToolItem("Delete", "trash") { editor.deleteSelection() })
            list.append(ToolItem("Move left", "chevron.left") { editor.moveSelected(-1) })
            list.append(ToolItem("Move right", "chevron.right") { editor.moveSelected(1) })
            list.append(ToolItem("Copy edits", "doc.on.doc") { editor.copyStyle() })
            list.append(ToolItem("Paste edits", "doc.on.clipboard", disabled: editor.copiedStyle == nil) { editor.pasteStyle() })
            list.append(ToolItem("Replace", "arrow.triangle.2.circlepath") { sheet = .replace })
            list.append(ToolItem("Multi-select", "checkmark.circle", on: editor.multiSelect) { editor.multiSelect.toggle() })
        case .overlay:
            list.append(ToolItem("Edit", "pencil") { panel = .overlayEdit })
            list.append(ToolItem("Duplicate", "plus.square.on.square") { editor.duplicateSelection() })
            list.append(ToolItem("Delete", "trash") { editor.deleteSelection() })
        case .audio:
            list.append(ToolItem("Edit", "pencil") { panel = .audioEdit })
            list.append(ToolItem("Volume", "speaker.wave.2") { panel = .volume })
            list.append(ToolItem("Duplicate", "plus.square.on.square") { editor.duplicateSelection() })
            list.append(ToolItem("Delete", "trash") { editor.deleteSelection() })
        case .none:
            break
        }
        list.append(ToolItem("Add media", "plus.circle") { panel = .addMedia })
        list.append(ToolItem("Text", "textformat") { editor.addText(); panel = .overlayEdit })
        list.append(ToolItem("Stickers", "face.smiling") { panel = .stickers })
        list.append(ToolItem("Image", "photo") { sheet = .image })
        list.append(ToolItem("Music", "music.note") { sheet = .music })
        list.append(ToolItem("Canvas", "aspectratio") { panel = .canvas })
        list.append(ToolItem("Remove text", "eraser") { panel = .removeText })
        list.append(ToolItem("Enhance HD", "sparkles") { panel = .enhance })
        list.append(ToolItem("Snap", "magnet", on: editor.snap) { editor.snap.toggle() })
        return list
    }

    @ViewBuilder
    private func panelContent(_ p: Panel) -> some View {
        switch p {
        case .trim: TrimPanel(editor: editor)
        case .speed: SpeedPanel(editor: editor)
        case .volume: VolumePanel(editor: editor)
        case .crop: CropPanel(editor: editor)
        case .adjust: AdjustPanel(editor: editor)
        case .filter: FilterPanel(editor: editor)
        case .effect: EffectPanel(editor: editor)
        case .overlayEdit: OverlayEditPanel(editor: editor)
        case .audioEdit: AudioEditPanel(editor: editor)
        case .canvas: CanvasPanel(editor: editor)
        case .removeText: RemoveTextPanel(editor: editor, drawMode: $drawMode)
        case .enhance: EnhancePanel(editor: editor)
        case .addMedia: AddMediaPanel(onPick: { sheet = $0 })
        case .stickers: StickerPanel(editor: editor, onAdded: { panel = .overlayEdit })
        }
    }
}

struct ExportSheet: View {
    @ObservedObject var editor: Editor
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Export").font(.title2).bold()
            Text(summary).font(.subheadline).foregroundColor(.secondary)

            switch editor.exportState {
            case .idle:
                Button(action: { editor.export() }) {
                    Text("Export & save to Photos").frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledStyle(color: .blue))
            case .working(let p):
                ProgressView(value: p)
                Text("\(Int(p * 100))%").font(.footnote).foregroundColor(.secondary)
                Button(action: { editor.cancelExport() }) { Text("Cancel") }
            case .done:
                Text("Saved to Photos ✓").font(.headline).foregroundColor(.green)
            case .failed(let msg):
                Text(msg).font(.footnote).foregroundColor(.red).multilineTextAlignment(.center)
                Button(action: { editor.export() }) {
                    Text("Try again").frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledStyle(color: .blue))
            }

            Button(action: onClose) { Text("Close") }
            Spacer()
        }
        .padding()
    }

    private var summary: String {
        let o = editor.canvasSize()
        return "\(Int(o.width))×\(Int(o.height)) • " + String(format: "%.1f s", editor.tl.duration)
    }
}
