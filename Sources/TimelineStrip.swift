import SwiftUI

/// CapCut-style timeline: the playhead stays in the middle, the tracks move under it.
struct TimelineStrip: View {
    @ObservedObject var editor: Editor
    @State private var dragStart: Double?
    @State private var pinchBase: CGFloat?

    private let mainY: CGFloat = 22
    private let mainH: CGFloat = 54
    private let laneH: CGFloat = 22
    private let overlayY: CGFloat = 82
    private let audioY: CGFloat = 134

    var body: some View {
        GeometryReader { g in
            let cx = g.size.width / 2
            ZStack(alignment: .topLeading) {
                Color(.secondarySystemBackground).opacity(0.5)
                ruler(cx: cx)
                mainRow(cx: cx)
                overlayRows(cx: cx)
                audioRows(cx: cx)
                headers
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: g.size.height)
                    .position(x: cx, y: g.size.height / 2)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(scrub)
            .simultaneousGesture(pinch)
        }
    }

    private func x(_ t: Double, _ cx: CGFloat) -> CGFloat {
        cx + CGFloat(t - editor.currentTime) * editor.pps
    }

    private func label(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    // MARK: ruler
    private func ruler(cx: CGFloat) -> some View {
        let pps = editor.pps
        let step: Double = pps >= 80 ? 1 : (pps >= 40 ? 2 : (pps >= 20 ? 5 : 10))
        let span = Double(cx / pps) + 1
        let first = max(0, floor((editor.currentTime - span) / step) * step)
        let last = editor.currentTime + span
        var ticks: [Double] = []
        var t = first
        while t <= last { ticks.append(t); t += step }
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { tick in
                Text(label(tick))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .position(x: x(tick, cx), y: 9)
            }
        }
    }

    // MARK: main track
    private func mainRow(cx: CGFloat) -> some View {
        let starts = editor.tl.starts()
        return ZStack(alignment: .topLeading) {
            ForEach(Array(editor.tl.clips.enumerated()), id: \.element.id) { i, c in
                let w = max(6, CGFloat(c.outDuration) * editor.pps - 1)
                ClipTile(editor: editor, clip: c, width: w, selected: editor.selectedClips.contains(c.id))
                    .frame(width: w, height: mainH)
                    .position(x: x(starts[i], cx) + w / 2, y: mainY + mainH / 2)
                    .opacity(editor.tl.videoHidden ? 0.35 : 1)
                    .onTapGesture { editor.tapClip(c.id) }
            }
        }
    }

    // MARK: overlay + audio lanes
    private func lanes(_ items: [(UUID, Double, Double)]) -> [UUID: Int] {
        var ends: [Double] = []
        var out: [UUID: Int] = [:]
        for (id, s, e) in items.sorted(by: { $0.1 < $1.1 }) {
            if let l = ends.firstIndex(where: { $0 <= s + 0.01 }) {
                ends[l] = e
                out[id] = min(l, 1)
            } else {
                ends.append(e)
                out[id] = min(ends.count - 1, 1)
            }
        }
        return out
    }

    private func overlayRows(cx: CGFloat) -> some View {
        let laneMap = lanes(editor.tl.overlays.map { ($0.id, $0.start, $0.end) })
        let total = editor.tl.duration
        return ZStack(alignment: .topLeading) {
            ForEach(editor.tl.overlays) { o in
                let lane = laneMap[o.id] ?? 0
                let endT = max(o.start + 0.3, min(o.end, max(total, o.start + 0.3)))
                let w = max(10, CGFloat(endT - o.start) * editor.pps)
                let color: Color = o.kind == .image ? .green : (o.kind == .emoji ? .orange : .blue)
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.opacity(editor.tl.overlayHidden ? 0.3 : 0.85))
                    .overlay(
                        Text(o.kind == .image ? "Image" : o.text)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 4),
                        alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(editor.selectedOverlay == o.id ? Color.yellow : Color.clear, lineWidth: 2))
                    .frame(width: w, height: laneH - 2)
                    .position(x: x(o.start, cx) + w / 2, y: overlayY + CGFloat(lane) * laneH + laneH / 2)
                    .onTapGesture { editor.tapOverlay(o.id) }
            }
        }
    }

    private func audioRows(cx: CGFloat) -> some View {
        let laneMap = lanes(editor.tl.audios.map { ($0.id, $0.start, $0.start + $0.length) })
        return ZStack(alignment: .topLeading) {
            ForEach(editor.tl.audios) { a in
                let lane = laneMap[a.id] ?? 0
                let w = max(10, CGFloat(a.length) * editor.pps)
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.purple.opacity(editor.tl.audioHidden ? 0.3 : 0.85))
                    .overlay(
                        HStack(spacing: 3) {
                            Image(systemName: "music.note").font(.system(size: 9))
                            Text(a.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 4),
                        alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(editor.selectedAudio == a.id ? Color.yellow : Color.clear, lineWidth: 2))
                    .frame(width: w, height: laneH - 2)
                    .position(x: x(a.start, cx) + w / 2, y: audioY + CGFloat(lane) * laneH + laneH / 2)
                    .onTapGesture { editor.tapAudio(a.id) }
            }
        }
    }

    // MARK: track headers (hide / lock)
    private var headers: some View {
        ZStack(alignment: .topLeading) {
            trackHeader(y: mainY + mainH / 2, hidden: editor.tl.videoHidden, locked: editor.tl.videoLocked,
                        onHide: { editor.edit { $0.videoHidden.toggle() } },
                        onLock: { editor.edit { $0.videoLocked.toggle() } })
            trackHeader(y: overlayY + laneH, hidden: editor.tl.overlayHidden, locked: editor.tl.overlayLocked,
                        onHide: { editor.edit { $0.overlayHidden.toggle() } },
                        onLock: { editor.edit { $0.overlayLocked.toggle() } })
            trackHeader(y: audioY + laneH, hidden: editor.tl.audioHidden, locked: editor.tl.audioLocked,
                        onHide: { editor.edit { $0.audioHidden.toggle() } },
                        onLock: { editor.edit { $0.audioLocked.toggle() } })
        }
    }

    private func trackHeader(y: CGFloat, hidden: Bool, locked: Bool,
                             onHide: @escaping () -> Void, onLock: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            Button(action: onHide) {
                Image(systemName: hidden ? "eye.slash" : "eye").font(.system(size: 11))
                    .frame(width: 22, height: 20)
            }
            Button(action: onLock) {
                Image(systemName: locked ? "lock.fill" : "lock.open").font(.system(size: 11))
                    .frame(width: 22, height: 20)
            }
        }
        .foregroundColor(.primary)
        .background(Color(.systemBackground).opacity(0.85))
        .cornerRadius(6)
        .position(x: 16, y: y)
    }

    // MARK: gestures
    private var scrub: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                if dragStart == nil {
                    dragStart = editor.currentTime
                    editor.pause()
                }
                var t = (dragStart ?? 0) - Double(v.translation.width / editor.pps)
                t = min(max(0, t), editor.tl.duration)
                if editor.snap { t = snapped(t) }
                editor.seek(to: t)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func snapped(_ t: Double) -> Double {
        var points = editor.tl.starts()
        points.append(editor.tl.duration)
        for p in points where abs(p - t) * Double(editor.pps) < 10 { return p }
        return t
    }

    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { s in
                if pinchBase == nil { pinchBase = editor.pps }
                editor.pps = min(400, max(8, (pinchBase ?? 60) * s))
            }
            .onEnded { _ in pinchBase = nil }
    }
}

struct ClipTile: View {
    @ObservedObject var editor: Editor
    let clip: Clip
    let width: CGFloat
    let selected: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 0) {
                if let img = editor.thumbs[editor.thumbKey(clip)] {
                    let tw = 54 * img.size.width / max(1, img.size.height)
                    let n = min(40, Int(ceil(width / max(20, tw))))
                    ForEach(0..<max(1, n), id: \.self) { _ in
                        Image(uiImage: img).resizable().scaledToFill().frame(width: tw, height: 54).clipped()
                    }
                } else {
                    Color.gray.opacity(0.4)
                }
            }
            .frame(width: width, height: 54, alignment: .leading)
            .clipped()

            HStack(spacing: 3) {
                if clip.freeze { Image(systemName: "pause.circle.fill") }
                if clip.style.speed != 1 && !clip.freeze { Text(String(format: "%g×", clip.style.speed)) }
                Text(String(format: "%.1fs", clip.outDuration))
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Color.black.opacity(0.55))
            .cornerRadius(3)
            .padding(2)
        }
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.yellow : Color.clear, lineWidth: 2))
        .onAppear { editor.requestThumb(clip) }
        .onChange(of: editor.thumbKey(clip)) { _ in editor.requestThumb(clip) }
    }
}
