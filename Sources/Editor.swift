import SwiftUI
import AVFoundation
import Photos
import CoreImage

enum ExportState {
    case idle
    case working(Double)
    case done
    case failed(String)
}

enum Focus { case none, clip, overlay, audio }

private struct Cluster {
    var rect: CGRect
    var first: Double
    var last: Double
    var hits: Int
    var lastSample: Int
}

/// Project state: timeline, selection, undo/redo, preview player, text scan and export.
final class Editor: ObservableObject {
    @Published var tl = Timeline() { didSet { scheduleRebuild() } }
    @Published var hasProject = false
    @Published var currentTime = 0.0
    @Published var isPlaying = false
    @Published var selectedClips: Set<UUID> = []
    @Published var selectedOverlay: UUID?
    @Published var selectedAudio: UUID?
    @Published var multiSelect = false
    @Published var snap = true
    @Published var pps: CGFloat = 60
    @Published var thumbs: [String: UIImage] = [:]
    @Published var strips: [UUID: [UIImage]] = [:]
    @Published var overlayBoxes: [UUID: CGSize] = [:]
    @Published var undoCount = 0
    @Published var redoCount = 0
    @Published var scanning = false
    @Published var scanProgress = 0.0
    @Published var scanMessage = ""
    @Published var exportState: ExportState = .idle
    @Published var message = ""
    @Published var copiedStyle: ClipStyle?

    let player = AVPlayer()
    private(set) var infos: [UUID: MediaInfo] = [:]
    private var assets: [UUID: AVURLAsset] = [:]
    private var composition: AVMutableComposition?
    private var lastKey = ""
    private var rebuildWork: DispatchWorkItem?
    private let ciContext = CIContext()
    private var exportSession: AVAssetExportSession?
    private var undoStack: [Timeline] = []
    private var redoStack: [Timeline] = []
    private var lastEditKey = ""
    private var lastEditTime = Date.distantPast
    private var pendingThumbs = Set<String>()
    private var pendingStrips = Set<UUID>()

    init() {
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
                                       queue: .main) { [weak self] t in
            guard let self = self, self.isPlaying else { return }
            let sec = t.seconds
            if sec.isFinite { self.currentTime = min(sec, self.tl.duration) }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.isPlaying = false
            self?.player.seek(to: .zero)
            self?.currentTime = 0
        }
    }

    // MARK: derived
    var focus: Focus {
        if selectedOverlay != nil { return .overlay }
        if selectedAudio != nil { return .audio }
        if !selectedClips.isEmpty { return .clip }
        return .none
    }

    var primaryClip: Clip? { tl.clips.first { selectedClips.contains($0.id) } }

    func firstSize() -> CGSize {
        guard let c = tl.clips.first, let info = infos[c.mediaID] else { return CGSize(width: 1920, height: 1080) }
        return Geometry.rotatedSize(info.orientedSize, rotation: c.style.rotation)
    }

    func canvasSize(maxLong: CGFloat = 3840) -> CGSize {
        Geometry.canvasSize(first: firstSize(), timeline: tl, maxLongSide: maxLong)
    }

    var canvasAspect: CGFloat {
        let s = canvasSize()
        return max(0.1, s.width / max(1, s.height))
    }

    // MARK: undo / redo
    func edit(key: String? = nil, _ change: (inout Timeline) -> Void) {
        let now = Date()
        if let k = key, k == lastEditKey, now.timeIntervalSince(lastEditTime) < 1.0 {
            // keep the same undo step while a slider is moving
        } else {
            undoStack.append(tl)
            if undoStack.count > 60 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastEditKey = key ?? ""
        lastEditTime = now
        var t = tl
        change(&t)
        tl = t
        undoCount = undoStack.count
        redoCount = redoStack.count
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(tl)
        lastEditKey = ""
        tl = prev
        afterHistory()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(tl)
        lastEditKey = ""
        tl = next
        afterHistory()
    }

    private func afterHistory() {
        undoCount = undoStack.count
        redoCount = redoStack.count
        let clipIDs = Set(tl.clips.map { $0.id })
        selectedClips = selectedClips.intersection(clipIDs)
        if let o = selectedOverlay, !tl.overlays.contains(where: { $0.id == o }) { selectedOverlay = nil }
        if let a = selectedAudio, !tl.audios.contains(where: { $0.id == a }) { selectedAudio = nil }
        currentTime = min(currentTime, tl.duration)
        if focus == .none { selectClipAtPlayhead() }
    }

    // MARK: selection
    func tapClip(_ id: UUID) {
        guard !tl.videoLocked else { return }
        selectedOverlay = nil
        selectedAudio = nil
        if multiSelect {
            if selectedClips.contains(id) { selectedClips.remove(id) } else { selectedClips.insert(id) }
        } else {
            selectedClips = [id]
        }
    }

    func tapOverlay(_ id: UUID) {
        guard !tl.overlayLocked else { return }
        selectedClips = []
        selectedAudio = nil
        selectedOverlay = id
    }

    func tapAudio(_ id: UUID) {
        guard !tl.audioLocked else { return }
        selectedClips = []
        selectedOverlay = nil
        selectedAudio = id
    }

    func selectClipAtPlayhead() {
        selectedOverlay = nil
        selectedAudio = nil
        if let i = tl.index(at: currentTime) { selectedClips = [tl.clips[i].id] } else { selectedClips = [] }
    }

    private func targetIDs() -> Set<UUID> {
        selectedClips.isEmpty ? Set(tl.clips.map { $0.id }) : selectedClips
    }

    // MARK: bindings
    func styleBinding<T>(_ kp: WritableKeyPath<ClipStyle, T>, default d: T) -> Binding<T> {
        Binding(get: { self.primaryClip?.style[keyPath: kp] ?? d },
                set: { v in
                    guard !self.tl.videoLocked else { return }
                    let ids = self.targetIDs()
                    self.edit(key: "style-\(kp)") { t in
                        for i in t.clips.indices where ids.contains(t.clips[i].id) {
                            t.clips[i].style[keyPath: kp] = v
                        }
                    }
                })
    }

    func tlBinding<T>(_ kp: WritableKeyPath<Timeline, T>) -> Binding<T> {
        Binding(get: { self.tl[keyPath: kp] },
                set: { v in self.edit(key: "tl-\(kp)") { $0[keyPath: kp] = v } })
    }

    func overlayBinding<T>(_ id: UUID, _ kp: WritableKeyPath<OverlayItem, T>, default d: T) -> Binding<T> {
        Binding(get: { self.tl.overlays.first(where: { $0.id == id })?[keyPath: kp] ?? d },
                set: { v in
                    self.edit(key: "ov-\(kp)") { t in
                        if let i = t.overlays.firstIndex(where: { $0.id == id }) { t.overlays[i][keyPath: kp] = v }
                    }
                })
    }

    func audioBinding<T>(_ id: UUID, _ kp: WritableKeyPath<AudioItem, T>, default d: T) -> Binding<T> {
        Binding(get: { self.tl.audios.first(where: { $0.id == id })?[keyPath: kp] ?? d },
                set: { v in
                    self.edit(key: "au-\(kp)") { t in
                        if let i = t.audios.firstIndex(where: { $0.id == id }) { t.audios[i][keyPath: kp] = v }
                    }
                })
    }

    func regionBinding<T>(_ id: UUID, _ kp: WritableKeyPath<TextRegion, T>, default d: T) -> Binding<T> {
        Binding(get: { self.tl.regions.first(where: { $0.id == id })?[keyPath: kp] ?? d },
                set: { v in
                    self.edit(key: "rg-\(kp)") { t in
                        if let i = t.regions.firstIndex(where: { $0.id == id }) { t.regions[i][keyPath: kp] = v }
                    }
                })
    }

    func clipBinding<T>(_ kp: WritableKeyPath<Clip, T>, default d: T) -> Binding<T> {
        Binding(get: { self.primaryClip?[keyPath: kp] ?? d },
                set: { v in
                    guard !self.tl.videoLocked, let id = self.primaryClip?.id else { return }
                    self.edit(key: "clip-\(kp)") { t in
                        if let i = t.clips.firstIndex(where: { $0.id == id }) { t.clips[i][keyPath: kp] = v }
                    }
                })
    }

    // MARK: media import
    private func registerMedia(url: URL) -> MediaInfo? {
        let a = AVURLAsset(url: url)
        guard let vt = a.tracks(withMediaType: .video).first else { return nil }
        let dur = a.duration.seconds
        guard dur.isFinite, dur > 0.1 else { return nil }
        let info = MediaInfo(id: UUID(), url: url, duration: dur, rawSize: vt.naturalSize,
                             orientation: MediaInfo.orientation(for: vt.preferredTransform),
                             fps: Double(vt.nominalFrameRate),
                             hasAudio: !a.tracks(withMediaType: .audio).isEmpty)
        infos[info.id] = info
        assets[info.id] = a
        return info
    }

    func importVideos(_ urls: [URL]) {
        guard !tl.videoLocked else { message = "The video track is locked."; return }
        var new: [Clip] = []
        for u in urls {
            if let info = registerMedia(url: u) {
                new.append(Clip(mediaID: info.id, srcStart: 0, srcEnd: info.duration))
            }
        }
        guard !new.isEmpty else { message = "Could not read that video."; return }
        let t = currentTime
        edit { $0.insert(new, at: t) }
        hasProject = true
        selectedClips = [new[0].id]
        selectedOverlay = nil
        selectedAudio = nil
        message = ""
        rebuildNow()
    }

    func replaceMedia(url: URL) {
        guard let c = primaryClip, !tl.videoLocked, let info = registerMedia(url: url) else {
            message = "Could not read that video."
            return
        }
        let span = max(0.2, c.srcEnd - c.srcStart)
        edit { t in
            if let i = t.clips.firstIndex(where: { $0.id == c.id }) {
                t.clips[i].mediaID = info.id
                t.clips[i].srcStart = 0
                t.clips[i].srcEnd = min(info.duration, span)
                t.clips[i].freeze = false
            }
        }
    }

    func close() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        hasProject = false
        tl = Timeline()
        infos = [:]
        assets = [:]
        composition = nil
        lastKey = ""
        undoStack = []
        redoStack = []
        undoCount = 0
        redoCount = 0
        selectedClips = []
        selectedOverlay = nil
        selectedAudio = nil
        thumbs = [:]
        strips = [:]
        currentTime = 0
        exportState = .idle
        scanMessage = ""
        message = ""
    }

    // MARK: clip operations
    private var clipsEditable: Bool {
        if tl.videoLocked { message = "The video track is locked."; return false }
        return true
    }

    func splitAtPlayhead() {
        guard clipsEditable else { return }
        let t = currentTime
        var ok = false
        edit { ok = $0.split(at: t) }
        if !ok { message = "Move the playhead inside a clip to split." } else { message = "" }
        selectClipAtPlayhead()
    }

    func deleteSelection() {
        switch focus {
        case .clip:
            guard clipsEditable else { return }
            let ids = selectedClips
            edit { $0.clips.removeAll { ids.contains($0.id) } }
            currentTime = min(currentTime, tl.duration)
            selectClipAtPlayhead()
        case .overlay:
            guard !tl.overlayLocked, let id = selectedOverlay else { return }
            edit { $0.overlays.removeAll { $0.id == id } }
            selectedOverlay = nil
            selectClipAtPlayhead()
        case .audio:
            guard !tl.audioLocked, let id = selectedAudio else { return }
            edit { $0.audios.removeAll { $0.id == id } }
            selectedAudio = nil
            selectClipAtPlayhead()
        case .none:
            break
        }
    }

    func duplicateSelection() {
        switch focus {
        case .clip:
            guard clipsEditable else { return }
            let ids = selectedClips
            edit { t in
                var out: [Clip] = []
                for c in t.clips {
                    out.append(c)
                    if ids.contains(c.id) {
                        var d = c
                        d.id = UUID()
                        out.append(d)
                    }
                }
                t.clips = out
            }
        case .overlay:
            guard !tl.overlayLocked, let id = selectedOverlay,
                  let o = tl.overlays.first(where: { $0.id == id }) else { return }
            var d = o
            d.id = UUID()
            d.start += 0.5
            d.end += 0.5
            edit { $0.overlays.append(d) }
            selectedOverlay = d.id
        case .audio:
            guard !tl.audioLocked, let id = selectedAudio,
                  let a = tl.audios.first(where: { $0.id == id }) else { return }
            var d = a
            d.id = UUID()
            d.start += 0.5
            edit { $0.audios.append(d) }
            selectedAudio = d.id
        case .none:
            break
        }
    }

    func moveSelected(_ delta: Int) {
        guard clipsEditable, let id = primaryClip?.id else { return }
        edit { t in
            guard let i = t.clips.firstIndex(where: { $0.id == id }) else { return }
            let j = i + delta
            guard j >= 0, j < t.clips.count else { return }
            t.clips.swapAt(i, j)
        }
    }

    func freezeFrame() {
        guard clipsEditable else { return }
        let t = currentTime
        edit { $0.addFreeze(at: t) }
        selectClipAtPlayhead()
    }

    func rotateSelected() {
        guard clipsEditable else { return }
        let ids = targetIDs()
        edit { t in
            for i in t.clips.indices where ids.contains(t.clips[i].id) {
                t.clips[i].style.rotation = (t.clips[i].style.rotation + 90) % 360
            }
        }
    }

    func flipSelected() {
        guard clipsEditable else { return }
        let ids = targetIDs()
        edit { t in
            for i in t.clips.indices where ids.contains(t.clips[i].id) { t.clips[i].style.flipH.toggle() }
        }
    }

    func copyStyle() {
        if let c = primaryClip {
            copiedStyle = c.style
            message = "Edits copied. Select another clip and tap Paste."
        }
    }

    func pasteStyle() {
        guard clipsEditable, let s = copiedStyle else { return }
        let ids = targetIDs()
        edit { t in
            for i in t.clips.indices where ids.contains(t.clips[i].id) {
                let speed = t.clips[i].style.speed
                var n = s
                n.speed = speed
                t.clips[i].style = n
            }
        }
        message = ""
    }

    // MARK: trim
    func setTrim(start: Double? = nil, end: Double? = nil) {
        guard let c = primaryClip, !c.freeze, !tl.videoLocked, let info = infos[c.mediaID] else { return }
        edit(key: "trim") { t in
            guard let i = t.clips.firstIndex(where: { $0.id == c.id }) else { return }
            var s = t.clips[i].srcStart
            var e = t.clips[i].srcEnd
            if let v = start { s = min(max(0, v), e - 0.2) }
            if let v = end { e = max(min(info.duration, v), s + 0.2) }
            t.clips[i].srcStart = s
            t.clips[i].srcEnd = e
        }
    }

    func trimToPlayhead(left: Bool) {
        guard clipsEditable, let i = tl.index(at: currentTime) else { return }
        let c = tl.clips[i]
        guard !c.freeze else { return }
        let local = currentTime - tl.starts()[i]
        let srcT = c.srcStart + local * c.style.speed
        edit { t in
            if left { t.clips[i].srcStart = min(srcT, t.clips[i].srcEnd - 0.2) }
            else { t.clips[i].srcEnd = max(srcT, t.clips[i].srcStart + 0.2) }
        }
        currentTime = min(currentTime, tl.duration)
    }

    // MARK: overlays and audio
    func addText() {
        var o = OverlayItem(kind: .text)
        o.text = "Your text"
        o.size = 0.07
        o.start = currentTime
        o.end = currentTime + 3
        edit { $0.overlays.append(o) }
        tapOverlayForce(o.id)
    }

    func addEmoji(_ e: String) {
        var o = OverlayItem(kind: .emoji)
        o.text = e
        o.size = 0.15
        o.start = currentTime
        o.end = currentTime + 3
        edit { $0.overlays.append(o) }
        tapOverlayForce(o.id)
    }

    func addImageOverlay(_ image: UIImage) {
        guard let data = image.normalized(maxSide: 1024).pngData() else { return }
        var o = OverlayItem(kind: .image)
        o.imageData = data
        o.size = 0.3
        o.start = currentTime
        o.end = currentTime + 3
        edit { $0.overlays.append(o) }
        tapOverlayForce(o.id)
    }

    private func tapOverlayForce(_ id: UUID) {
        selectedClips = []
        selectedAudio = nil
        selectedOverlay = id
    }

    func moveSelectedOverlay(x: Double, y: Double) {
        guard !tl.overlayLocked, let id = selectedOverlay else { return }
        edit(key: "ov-move") { t in
            if let i = t.overlays.firstIndex(where: { $0.id == id }) {
                t.overlays[i].x = x
                t.overlays[i].y = y
            }
        }
    }

    func addMusic(url: URL) {
        let a = AVURLAsset(url: url)
        let dur = a.duration.seconds
        guard a.tracks(withMediaType: .audio).first != nil, dur.isFinite, dur > 0.1 else {
            message = "Could not read that audio file."
            return
        }
        let total = tl.duration
        var item = AudioItem(url: url, name: url.deletingPathExtension().lastPathComponent, sourceDuration: dur)
        item.start = min(currentTime, max(0, total - 0.5))
        item.length = max(0.5, min(dur, total - item.start))
        edit { $0.audios.append(item) }
        selectedClips = []
        selectedOverlay = nil
        selectedAudio = item.id
    }

    // MARK: playback
    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            guard !tl.clips.isEmpty else { return }
            if currentTime >= tl.duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let t = min(max(0, seconds), tl.duration)
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(_ n: Int) {
        pause()
        let fps = max(24, infos[tl.clips.first?.mediaID ?? UUID()]?.fps ?? 30)
        seek(to: currentTime + Double(n) / fps)
    }

    func zoom(_ factor: CGFloat) {
        pps = min(400, max(8, pps * factor))
    }

    // MARK: thumbnails
    func thumbKey(_ c: Clip) -> String { "\(c.mediaID.uuidString)-\(Int(c.srcStart * 2))" }

    func requestThumb(_ clip: Clip) {
        let key = thumbKey(clip)
        guard thumbs[key] == nil, !pendingThumbs.contains(key), let asset = assets[clip.mediaID] else { return }
        pendingThumbs.insert(key)
        let time = clip.srcStart
        DispatchQueue.global(qos: .utility).async {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 200, height: 200)
            let cg = try? gen.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
            DispatchQueue.main.async {
                self.pendingThumbs.remove(key)
                if let cg = cg { self.thumbs[key] = UIImage(cgImage: cg) }
            }
        }
    }

    func requestStrip(_ mediaID: UUID) {
        guard strips[mediaID] == nil, !pendingStrips.contains(mediaID),
              let asset = assets[mediaID], let info = infos[mediaID] else { return }
        pendingStrips.insert(mediaID)
        DispatchQueue.global(qos: .utility).async {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 160, height: 160)
            var out: [UIImage] = []
            let n = 8
            for i in 0..<n {
                let t = info.duration * (Double(i) + 0.5) / Double(n)
                if let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                    out.append(UIImage(cgImage: cg))
                }
            }
            DispatchQueue.main.async {
                self.pendingStrips.remove(mediaID)
                self.strips[mediaID] = out
            }
        }
    }

    // MARK: composition + preview
    private func scheduleRebuild() {
        guard hasProject else { return }
        rebuildWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.rebuildNow() }
        rebuildWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func structureKey() -> String {
        let c = tl.clips.map {
            "\($0.mediaID)-\($0.srcStart)-\($0.srcEnd)-\($0.style.speed)-\($0.freeze)-\($0.freezeLength)-\($0.style.volume)-\($0.style.muted)"
        }.joined(separator: ",")
        let a = tl.audios.map { "\($0.url.lastPathComponent)-\($0.start)-\($0.srcStart)-\($0.length)-\($0.volume)" }
            .joined(separator: ",")
        return c + "|" + a + "|\(tl.audioHidden)"
    }

    func rebuildNow() {
        rebuildWork?.cancel()
        guard !tl.clips.isEmpty else {
            player.replaceCurrentItem(with: nil)
            composition = nil
            lastKey = ""
            overlayBoxes = [:]
            return
        }
        let prev = Geometry.previewSize(canvasSize())
        let renderer = Renderer(timeline: tl, infos: infos, outSize: prev)
        overlayBoxes = renderer.normalizedSizes()
        let key = structureKey()

        if key != lastKey || composition == nil {
            guard let result = compose() else { return }
            composition = result.0
            let vc = Builder.videoComposition(for: result.0, renderer: renderer, size: prev, fps: 30, context: ciContext)
            let item = AVPlayerItem(asset: result.0)
            item.audioMix = result.1
            item.audioTimePitchAlgorithm = .spectral
            item.videoComposition = vc
            let wasPlaying = isPlaying
            player.replaceCurrentItem(with: item)
            player.seek(to: CMTime(seconds: min(currentTime, max(0, tl.duration - 0.01)), preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
            lastKey = key
        } else if let comp = composition {
            let vc = Builder.videoComposition(for: comp, renderer: renderer, size: prev, fps: 30, context: ciContext)
            player.currentItem?.videoComposition = vc
            if !isPlaying {
                player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private func compose() -> (AVMutableComposition, AVAudioMix?)? {
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video,
                                            preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let ts: CMTimeScale = 600
        var cursor = CMTime.zero
        var clipVolumes: [(CMTime, Float)] = []

        for clip in tl.clips {
            guard let a = assets[clip.mediaID], let vt = a.tracks(withMediaType: .video).first else { continue }
            let srcDur = clip.freeze ? 0.01 : max(0.05, clip.srcEnd - clip.srcStart)
            let range = CMTimeRange(start: CMTime(seconds: clip.srcStart, preferredTimescale: ts),
                                    duration: CMTime(seconds: srcDur, preferredTimescale: ts))
            do {
                try cv.insertTimeRange(range, of: vt, at: cursor)
                if !clip.freeze, let at = a.tracks(withMediaType: .audio).first, let ca = ca {
                    try ca.insertTimeRange(range, of: at, at: cursor)
                }
            } catch {
                continue
            }
            let outDur = CMTime(seconds: clip.outDuration, preferredTimescale: ts)
            comp.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: outDur)
            clipVolumes.append((cursor, (clip.style.muted || clip.freeze) ? 0 : Float(clip.style.volume)))
            cursor = CMTimeAdd(cursor, outDur)
        }

        var params: [AVMutableAudioMixInputParameters] = []
        if let ca = ca {
            let p = AVMutableAudioMixInputParameters(track: ca)
            for (t, v) in clipVolumes { p.setVolume(v, at: t) }
            params.append(p)
        }

        if !tl.audioHidden {
            let total = cursor.seconds
            for item in tl.audios {
                let len = min(item.length, total - item.start)
                guard len > 0.05,
                      let at = AVURLAsset(url: item.url).tracks(withMediaType: .audio).first,
                      let track = comp.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let range = CMTimeRange(start: CMTime(seconds: item.srcStart, preferredTimescale: ts),
                                        duration: CMTime(seconds: len, preferredTimescale: ts))
                do {
                    try track.insertTimeRange(range, of: at, at: CMTime(seconds: max(0, item.start), preferredTimescale: ts))
                } catch {
                    continue
                }
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(Float(item.volume), at: .zero)
                params.append(p)
            }
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return (comp, mix)
    }

    // MARK: text removal scan
    private static func pad(_ r: CGRect, _ p: Double) -> CGRect {
        let d = CGFloat(p)
        return r.insetBy(dx: -d, dy: -d).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func overlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        if i.isNull { return 0 }
        let minArea = min(a.width * a.height, b.width * b.height)
        return minArea > 0 ? (i.width * i.height) / minArea : 0
    }

    func addRegion(_ rect: CGRect) {
        edit { $0.regions.append(TextRegion(rect: rect, start: 0, end: 0, wholeVideo: true)) }
    }

    func deleteRegion(_ id: UUID) {
        edit { $0.regions.removeAll { $0.id == id } }
    }

    func detectText(padding: Double) {
        guard !scanning, !tl.clips.isEmpty else { return }
        pause()
        scanning = true
        scanProgress = 0
        scanMessage = ""
        var plain = tl
        plain.regions = []
        plain.overlays = []
        plain.enhance = false
        let prev = Geometry.previewSize(canvasSize())
        let total = tl.duration
        guard let result = compose() else { scanning = false; return }
        let renderer = Renderer(timeline: plain, infos: infos, outSize: prev)
        let vc = Builder.videoComposition(for: result.0, renderer: renderer, size: prev, fps: 30, context: ciContext)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let gen = AVAssetImageGenerator(asset: result.0)
            gen.videoComposition = vc
            gen.maximumSize = prev

            let step = max(0.4, total / 40)
            var times: [Double] = []
            var t = 0.0
            while t < total - 0.05 { times.append(t); t += step }
            if times.isEmpty { times = [0] }

            var clusters: [Cluster] = []
            for (i, time) in times.enumerated() {
                if let cg = try? gen.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) {
                    for b in TextDetector.detect(cg, accurate: false) {
                        if let idx = clusters.firstIndex(where: { Editor.overlapRatio($0.rect, b) > 0.5 }) {
                            clusters[idx].rect = clusters[idx].rect.union(b)
                            clusters[idx].last = time
                            if clusters[idx].lastSample != i {
                                clusters[idx].hits += 1
                                clusters[idx].lastSample = i
                            }
                        } else {
                            clusters.append(Cluster(rect: b, first: time, last: time, hits: 1, lastSample: i))
                        }
                    }
                }
                let p = Double(i + 1) / Double(times.count)
                DispatchQueue.main.async { self.scanProgress = p }
            }

            let minHits = times.count >= 3 ? 2 : 1
            let regions: [TextRegion] = clusters.filter { $0.hits >= minHits }.map { c in
                TextRegion(rect: Editor.pad(c.rect, padding),
                           start: max(0, c.first - step),
                           end: min(total, c.last + step),
                           wholeVideo: Double(c.hits) >= 0.7 * Double(times.count))
            }
            DispatchQueue.main.async {
                self.scanning = false
                if regions.isEmpty {
                    self.scanMessage = "No text found. Try drawing a box on the preview."
                } else {
                    self.edit { $0.regions.append(contentsOf: regions) }
                    self.scanMessage = "Found \(regions.count) text area(s). Check the red boxes on the preview."
                }
            }
        }
    }

    // MARK: export
    func export() {
        guard !tl.clips.isEmpty else { exportState = .failed("Add a video first."); return }
        pause()
        exportState = .working(0)
        let out = canvasSize()
        guard let result = compose() else { fail("Could not build the video."); return }
        let renderer = Renderer(timeline: tl, infos: infos, outSize: out)
        let vc = Builder.videoComposition(for: result.0, renderer: renderer, size: out, fps: 30, context: ciContext)
        guard let session = AVAssetExportSession(asset: result.0, presetName: AVAssetExportPresetHighestQuality) else {
            fail("Export is not available for this project.")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).mp4")
        session.videoComposition = vc
        session.audioMix = result.1
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.audioTimePitchAlgorithm = .spectral
        exportSession = session

        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self, weak session] t in
            guard let self = self, let session = session else { t.invalidate(); return }
            if session.status == .exporting || session.status == .waiting {
                self.exportState = .working(Double(session.progress) * 0.95)
            } else {
                t.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)

        session.exportAsynchronously { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async { timer.invalidate() }
            switch session.status {
            case .completed:
                self.requestPhotos { ok in
                    guard ok else { self.fail("Photos access is off. Enable it in Settings."); return }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }, completionHandler: { success, err in
                        try? FileManager.default.removeItem(at: url)
                        DispatchQueue.main.async {
                            self.exportState = success ? .done : .failed(err?.localizedDescription ?? "Save failed.")
                        }
                    })
                }
            case .cancelled:
                self.fail("Export cancelled.")
            default:
                self.fail(session.error?.localizedDescription ?? "Export failed.")
            }
        }
    }

    func cancelExport() { exportSession?.cancelExport() }

    private func fail(_ msg: String) {
        DispatchQueue.main.async { self.exportState = .failed(msg) }
    }

    private func requestPhotos(_ done: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            done(status == .authorized || status == .limited)
        }
    }
}

enum Builder {
    static func videoComposition(for comp: AVAsset, renderer: Renderer, size: CGSize,
                                 fps: Double, context: CIContext) -> AVMutableVideoComposition {
        let vc = AVMutableVideoComposition(asset: comp, applyingCIFiltersWithHandler: { request in
            let out = renderer.render(request.sourceImage, t: request.compositionTime.seconds)
            request.finish(with: out, context: context)
        })
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: Int32(max(24, min(60, fps.rounded()))))
        return vc
    }
}
