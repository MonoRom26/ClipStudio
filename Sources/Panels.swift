import SwiftUI

// MARK: - helpers
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.2f"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.footnote)
                Spacer()
                Text(String(format: format, value)).font(.footnote).foregroundColor(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

struct ChipRow<T: Hashable>: View {
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { o in
                    Button(action: { selection = o }) {
                        Text(title(o))
                            .font(.footnote)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(selection == o ? Color.blue : Color(.secondarySystemBackground))
                            .foregroundColor(selection == o ? .white : .primary)
                            .cornerRadius(16)
                    }
                }
            }
        }
    }
}

struct SmallButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.footnote)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
        }
    }
}

struct Hint: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundColor(.secondary)
    }
}

// MARK: - Trim
struct TrimBar: View {
    @ObservedObject var editor: Editor
    let clip: Clip
    let duration: Double

    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width)
            let sx = CGFloat(clip.srcStart / duration) * w
            let ex = CGFloat(clip.srcEnd / duration) * w
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(Array((editor.strips[clip.mediaID] ?? []).enumerated()), id: \.offset) { _, img in
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: w / 8, height: 48).clipped()
                    }
                }
                .frame(width: w, height: 48, alignment: .leading)
                .background(Color.gray.opacity(0.3))
                .clipped()

                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, sx), height: 48)
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, w - ex), height: 48).offset(x: ex)
                Rectangle().stroke(Color.pink, lineWidth: 2).frame(width: max(2, ex - sx), height: 48).offset(x: sx)

                handle(x: sx, isStart: true, w: w)
                handle(x: ex, isStart: false, w: w)
            }
            .coordinateSpace(name: "trimbar")
        }
        .frame(height: 48)
        .onAppear { editor.requestStrip(clip.mediaID) }
    }

    private func handle(x: CGFloat, isStart: Bool, w: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.pink)
            .frame(width: 14, height: 48)
            .overlay(Rectangle().fill(Color.white).frame(width: 2, height: 18))
            .offset(x: x - 7)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trimbar"))
                .onChanged { v in
                    let t = Double(min(max(0, v.location.x), w) / w) * duration
                    if isStart { editor.setTrim(start: t) } else { editor.setTrim(end: t) }
                })
    }
}

struct TrimPanel: View {
    @ObservedObject var editor: Editor
    var body: some View {
        if let c = editor.primaryClip, !c.freeze, let info = editor.infos[c.mediaID] {
            VStack(alignment: .leading, spacing: 12) {
                TrimBar(editor: editor, clip: c, duration: info.duration)
                Text(String(format: "In %.2f s    Out %.2f s    Length %.2f s", c.srcStart, c.srcEnd, c.outDuration))
                    .font(.footnote).foregroundColor(.secondary)
                HStack {
                    SmallButton(title: "Cut start here", icon: "arrow.right.to.line") { editor.trimToPlayhead(left: true) }
                    SmallButton(title: "Cut end here", icon: "arrow.left.to.line") { editor.trimToPlayhead(left: false) }
                }
                Hint(text: "Drag the pink handles, or move the playhead and tap a Cut button. Use Split and Delete to remove a section in the middle.")
            }
        } else {
            Hint(text: "Select a normal clip to trim it.")
        }
    }
}

// MARK: - Speed
struct SpeedPanel: View {
    @ObservedObject var editor: Editor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let c = editor.primaryClip, c.freeze {
                LabeledSlider(title: "Freeze length", value: editor.clipBinding(\.freezeLength, default: 2.0),
                              range: 0.5...10, format: "%.1f s")
            } else {
                ChipRow(options: [0.1, 0.25, 0.5, 1.0, 1.5, 2.0, 4.0, 8.0],
                        title: { String(format: "%g×", $0) },
                        selection: editor.styleBinding(\.speed, default: 1.0))
                LabeledSlider(title: "Speed", value: editor.styleBinding(\.speed, default: 1.0),
                              range: 0.1...4, format: "%.2f×")
                Hint(text: "Slow motion looks smoothest on videos shot at 120 or 240 fps. Split a clip first to change only one part.")
            }
        }
    }
}

// MARK: - Volume
struct VolumePanel: View {
    @ObservedObject var editor: Editor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editor.focus == .audio, let id = editor.selectedAudio {
                LabeledSlider(title: "Music volume", value: editor.audioBinding(id, \.volume, default: 1.0),
                              range: 0...2)
            } else {
                Toggle(isOn: editor.styleBinding(\.muted, default: false)) { Text("Mute clip") }
                LabeledSlider(title: "Volume", value: editor.styleBinding(\.volume, default: 1.0), range: 0...2)
            }
        }
    }
}

// MARK: - Crop (fit / fill / zoom / pan)
struct CropPanel: View {
    @ObservedObject var editor: Editor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChipRow(options: [false, true], title: { $0 ? "Fill (crop)" : "Fit (bars)" },
                    selection: editor.styleBinding(\.fill, default: false))
            LabeledSlider(title: "Zoom", value: editor.styleBinding(\.zoom, default: 1.0), range: 1...4, format: "%.2f×")
            LabeledSlider(title: "Move left / right", value: editor.styleBinding(\.panX, default: 0.0), range: -1...1)
            LabeledSlider(title: "Move down / up", value: editor.styleBinding(\.panY, default: 0.0), range: -1...1)
            HStack {
                SmallButton(title: "Rotate", icon: "rotate.right") { editor.rotateSelected() }
                SmallButton(title: "Flip", icon: "arrow.left.arrow.right") { editor.flipSelected() }
            }
            Hint(text: "Change the video shape (16:9, 9:16 ...) in Canvas. Crop, then remove text.")
        }
    }
}

// MARK: - Adjust / Filter / Effect
struct AdjustPanel: View {
    @ObservedObject var editor: Editor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledSlider(title: "Brightness", value: editor.styleBinding(\.brightness, default: 0.0), range: -0.5...0.5)
            LabeledSlider(title: "Contrast", value: editor.styleBinding(\.contrast, default: 1.0), range: 0.5...1.5)
            LabeledSlider(title: "Saturation", value: editor.styleBinding(\.saturation, default: 1.0), range: 0...2)
            LabeledSlider(title: "Warmth", value: editor.styleBinding(\.warmth, default: 0.0), range: -1...1)
            LabeledSlider(title: "Sharpness", value: editor.styleBinding(\.sharpness, default: 0.0), range: 0...2)
            LabeledSlider(title: "Vignette", value: editor.styleBinding(\.vignette, default: 0.0), range: 0...1)
        }
    }
}

struct FilterPanel: View {
    @ObservedObject var editor: Editor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChipRow(options: FilterPreset.allCases, title: { $0.title },
                    selection: editor.styleBinding(\.filter, default: FilterPreset.none))
            LabeledSlider(title: "Amount", value: editor.styleBinding(\.filterAmount, default: 1.0), range: 0...1)
        }
    }
}

struct EffectPanel: View {
    @ObservedObject var editor: Editor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChipRow(options: EffectPreset.allCases, title: { $0.title },
                    selection: editor.styleBinding(\.effect, default: EffectPreset.none))
            LabeledSlider(title: "Intensity", value: editor.styleBinding(\.effectAmount, default: 0.5), range: 0...1)
        }
    }
}

// MARK: - Canvas / Enhance
struct CanvasPanel: View {
    @ObservedObject var editor: Editor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Video shape").font(.subheadline).bold()
            ChipRow(options: AspectPreset.allCases, title: { $0.title }, selection: editor.tlBinding(\.canvas))
            Hint(text: "Clips are fitted inside the shape. Use Crop > Fill to remove the black bars.")
        }
    }
}

struct EnhancePanel: View {
    @ObservedObject var editor: Editor
    var body: some View {
        let o = editor.canvasSize()
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: editor.tlBinding(\.enhance)) {
                VStack(alignment: .leading) {
                    Text("Enhance HD").font(.subheadline).bold()
                    Text("Upscales 2× and reduces noise and softness").font(.caption).foregroundColor(.secondary)
                }
            }
            Text("Output size").font(.subheadline).bold()
            ChipRow(options: ResolutionPreset.allCases, title: { $0.title }, selection: editor.tlBinding(\.resolution))
            Text("Result: \(Int(o.width))×\(Int(o.height))").font(.footnote).foregroundColor(.secondary)
            Hint(text: "This sharpens and enlarges the picture on your iPhone. It does not add new detail like AI upscalers. 4K exports are slow on older iPhones.")
        }
    }
}

// MARK: - Remove text
struct RemoveTextPanel: View {
    @ObservedObject var editor: Editor
    @Binding var drawMode: Bool
    @State private var padding = 0.01

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: { editor.detectText(padding: padding) }) {
                Label(editor.scanning ? "Scanning…" : "Auto detect text", systemImage: "text.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FilledStyle(color: .blue))
            .disabled(editor.scanning)

            if editor.scanning { ProgressView(value: editor.scanProgress) }
            if !editor.scanMessage.isEmpty { Hint(text: editor.scanMessage) }

            LabeledSlider(title: "Box padding", value: $padding, range: 0...0.04, format: "%.3f")
            Toggle("Draw a box on the preview", isOn: $drawMode)

            Text("Fill style").font(.subheadline).bold()
            ChipRow(options: FillStyle.allCases, title: { $0.title }, selection: editor.tlBinding(\.fillStyle))

            if !editor.tl.regions.isEmpty {
                Text("Areas").font(.subheadline).bold()
                ForEach(Array(editor.tl.regions.enumerated()), id: \.element.id) { idx, r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle(isOn: editor.regionBinding(r.id, \.enabled, default: true)) {
                                Text("Area \(idx + 1)").font(.footnote)
                            }
                            Button(action: { editor.deleteRegion(r.id) }) {
                                Image(systemName: "trash").foregroundColor(.red)
                            }
                        }
                        Toggle(isOn: editor.regionBinding(r.id, \.wholeVideo, default: true)) {
                            Text(r.wholeVideo ? "Whole video"
                                 : String(format: "From %.1f s to %.1f s", r.start, r.end))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                }
            }
            Hint(text: "Works best on small, still text such as captions and watermarks over simple backgrounds. Busy or moving backgrounds can leave traces. Do crop and canvas first.")
        }
    }
}

// MARK: - Overlay (text / emoji / image)
struct OverlayEditPanel: View {
    @ObservedObject var editor: Editor

    var body: some View {
        if let id = editor.selectedOverlay, let o = editor.tl.overlays.first(where: { $0.id == id }) {
            let total = max(1, editor.tl.duration)
            VStack(alignment: .leading, spacing: 12) {
                if o.kind != .image {
                    TextField("Text", text: editor.overlayBinding(id, \.text, default: ""))
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                if o.kind == .text {
                    ColorPicker("Color", selection: editor.overlayBinding(id, \.color, default: Color.white))
                    Toggle("Bold", isOn: editor.overlayBinding(id, \.bold, default: true))
                    Toggle("Dark background", isOn: editor.overlayBinding(id, \.background, default: false))
                }
                LabeledSlider(title: "Size", value: editor.overlayBinding(id, \.size, default: 0.1),
                              range: o.kind == .image ? 0.05...1 : 0.02...0.4)
                LabeledSlider(title: "Rotate", value: editor.overlayBinding(id, \.rotation, default: 0),
                              range: -180...180, format: "%.0f°")
                LabeledSlider(title: "Opacity", value: editor.overlayBinding(id, \.opacity, default: 1), range: 0.1...1)
                LabeledSlider(title: "Starts at", value: editor.overlayBinding(id, \.start, default: 0),
                              range: 0...total, format: "%.1f s")
                LabeledSlider(title: "Ends at", value: editor.overlayBinding(id, \.end, default: 3),
                              range: 0...max(total, o.end), format: "%.1f s")
                HStack {
                    SmallButton(title: "Start at playhead", icon: "arrow.right.to.line") {
                        editor.overlayBinding(id, \.start, default: 0).wrappedValue = editor.currentTime
                    }
                    SmallButton(title: "End at playhead", icon: "arrow.left.to.line") {
                        editor.overlayBinding(id, \.end, default: 3).wrappedValue = editor.currentTime
                    }
                }
                Hint(text: "Drag on the preview to move it.")
            }
        } else {
            Hint(text: "Tap a text, sticker or image on the timeline to edit it.")
        }
    }
}

struct StickerPanel: View {
    @ObservedObject var editor: Editor
    var onAdded: () -> Void

    private let emojis = ["😀", "😂", "😍", "😎", "🔥", "❤️", "👍", "🎉", "⭐️", "💯", "🚀", "🌈",
                          "🎵", "📍", "✅", "❌", "👑", "💎", "🍕", "🐶", "😭", "🙏", "💪", "👀"]
    private let cols = [GridItem(.adaptive(minimum: 44))]

    var body: some View {
        LazyVGrid(columns: cols, spacing: 8) {
            ForEach(emojis, id: \.self) { e in
                Button(action: { editor.addEmoji(e); onAdded() }) { Text(e).font(.largeTitle) }
            }
        }
    }
}

// MARK: - Audio item
struct AudioEditPanel: View {
    @ObservedObject var editor: Editor
    var body: some View {
        if let id = editor.selectedAudio, let a = editor.tl.audios.first(where: { $0.id == id }) {
            let total = max(1, editor.tl.duration)
            VStack(alignment: .leading, spacing: 12) {
                Text(a.name).font(.subheadline).bold().lineLimit(1)
                LabeledSlider(title: "Volume", value: editor.audioBinding(id, \.volume, default: 1.0), range: 0...2)
                LabeledSlider(title: "Starts at", value: editor.audioBinding(id, \.start, default: 0),
                              range: 0...total, format: "%.1f s")
                LabeledSlider(title: "Length", value: editor.audioBinding(id, \.length, default: 5),
                              range: 0.5...max(0.6, a.sourceDuration - a.srcStart), format: "%.1f s")
                LabeledSlider(title: "Begin inside song at", value: editor.audioBinding(id, \.srcStart, default: 0),
                              range: 0...max(0.1, a.sourceDuration - 0.5), format: "%.1f s")
                SmallButton(title: "Start at playhead", icon: "arrow.right.to.line") {
                    editor.audioBinding(id, \.start, default: 0).wrappedValue = editor.currentTime
                }
            }
        } else {
            Hint(text: "Tap a music bar on the timeline to edit it.")
        }
    }
}

// MARK: - Add media
struct AddMediaPanel: View {
    var onPick: (ImportSheet) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: { onPick(.photos) }) {
                Label("From Photos (several at once)", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(FilledStyle(color: .blue))
            Button(action: { onPick(.files) }) {
                Label("From Files", systemImage: "folder").frame(maxWidth: .infinity)
            }
            .buttonStyle(FilledStyle(color: .purple))
            Hint(text: "New clips are inserted at the playhead. Move the playhead to the end to add them last.")
        }
    }
}
