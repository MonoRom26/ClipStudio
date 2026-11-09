import SwiftUI
import ImageIO

// MARK: - presets
enum FilterPreset: String, CaseIterable, Identifiable {
    case none, vivid, warm, cool, noir, mono, chrome, fade, instant, process, tonal, transfer, sepia, dramatic, cinema
    var id: String { rawValue }
    var title: String { self == .none ? "None" : rawValue.capitalized }
}

enum EffectPreset: String, CaseIterable, Identifiable {
    case none, blur, pixelate, glow, comic, glitch, zoomBlur
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .glow: return "Glow"
        case .comic: return "Comic"
        case .glitch: return "Glitch"
        case .zoomBlur: return "Zoom blur"
        }
    }
}

enum AspectPreset: String, CaseIterable, Identifiable {
    case original, wide, tall, square, portrait, classic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Original"
        case .wide: return "16:9"
        case .tall: return "9:16"
        case .square: return "1:1"
        case .portrait: return "4:5"
        case .classic: return "4:3"
        }
    }
    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .wide: return 16.0 / 9.0
        case .tall: return 9.0 / 16.0
        case .square: return 1
        case .portrait: return 4.0 / 5.0
        case .classic: return 4.0 / 3.0
        }
    }
}

enum ResolutionPreset: String, CaseIterable, Identifiable {
    case original, p720, p1080, p2160
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Original"
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p2160: return "4K"
        }
    }
    var shortSide: CGFloat? {
        switch self {
        case .original: return nil
        case .p720: return 720
        case .p1080: return 1080
        case .p2160: return 2160
        }
    }
}

enum FillStyle: String, CaseIterable, Identifiable {
    case patch, blur
    var id: String { rawValue }
    var title: String { self == .patch ? "Patch fill" : "Blur" }
}

// MARK: - clips
/// Everything that can be copied from one clip to another (except speed)
struct ClipStyle {
    var speed = 1.0
    var volume = 1.0
    var muted = false
    var rotation = 0
    var flipH = false
    var fill = false          // false = fit (black bars), true = fill (crop)
    var zoom = 1.0
    var panX = 0.0
    var panY = 0.0
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var warmth = 0.0
    var sharpness = 0.0
    var vignette = 0.0
    var filter = FilterPreset.none
    var filterAmount = 1.0
    var effect = EffectPreset.none
    var effectAmount = 0.5
}

struct MediaInfo {
    let id: UUID
    let url: URL
    let duration: Double
    let rawSize: CGSize
    let orientation: CGImagePropertyOrientation
    let fps: Double
    let hasAudio: Bool
    var orientedSize: CGSize {
        (orientation == .right || orientation == .left)
            ? CGSize(width: rawSize.height, height: rawSize.width) : rawSize
    }

    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = t.a.rounded(), b = t.b.rounded(), c = t.c.rounded(), d = t.d.rounded()
        if a == 0 && b == 1 && c == -1 && d == 0 { return .right }
        if a == 0 && b == -1 && c == 1 && d == 0 { return .left }
        if a == -1 && b == 0 && c == 0 && d == -1 { return .down }
        return .up
    }
}

struct Clip: Identifiable {
    var id = UUID()
    var mediaID: UUID
    var srcStart: Double
    var srcEnd: Double
    var freeze = false
    var freezeLength = 2.0
    var style = ClipStyle()

    var outDuration: Double {
        freeze ? freezeLength : max(0.05, (srcEnd - srcStart) / max(0.05, style.speed))
    }
}

struct AudioItem: Identifiable {
    var id = UUID()
    var url: URL
    var name: String
    var sourceDuration: Double
    var srcStart = 0.0
    var start = 0.0       // timeline seconds
    var length = 5.0      // seconds on the timeline
    var volume = 1.0
}

/// Region (normalized, origin top-left) in the finished frame where text is removed
struct TextRegion: Identifiable {
    var id = UUID()
    var rect: CGRect
    var start: Double
    var end: Double
    var wholeVideo: Bool
    var enabled = true
}

enum OverlayKind { case text, emoji, image }

struct OverlayItem: Identifiable {
    var id = UUID()
    var kind: OverlayKind
    var text = ""
    var imageData: Data?
    var color = Color.white
    var bold = true
    var background = false
    var x = 0.5
    var y = 0.5
    var size = 0.07        // text/emoji: font height / frame height. image: width / frame width
    var rotation = 0.0
    var opacity = 1.0
    var start = 0.0        // timeline seconds
    var end = 3.0
}

// MARK: - timeline
struct Timeline {
    var clips: [Clip] = []
    var overlays: [OverlayItem] = []
    var audios: [AudioItem] = []
    var canvas = AspectPreset.original
    var regions: [TextRegion] = []
    var fillStyle = FillStyle.patch
    var enhance = false
    var resolution = ResolutionPreset.original
    var videoHidden = false
    var videoLocked = false
    var overlayHidden = false
    var overlayLocked = false
    var audioHidden = false
    var audioLocked = false

    var duration: Double { clips.reduce(0) { $0 + $1.outDuration } }

    func starts() -> [Double] {
        var out: [Double] = []
        var acc = 0.0
        for c in clips { out.append(acc); acc += c.outDuration }
        return out
    }

    func index(at t: Double) -> Int? {
        if clips.isEmpty { return nil }
        let st = starts()
        for i in clips.indices where t >= st[i] && t < st[i] + clips[i].outDuration { return i }
        return clips.count - 1
    }

    /// index of the clip boundary closest to t (clips.count = end of timeline)
    func nearestBoundary(to t: Double) -> Int {
        let st = starts()
        var best = clips.count
        var bestD = abs(duration - t)
        for (i, s) in st.enumerated() {
            let d = abs(s - t)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    @discardableResult
    mutating func split(at t: Double) -> Bool {
        let st = starts()
        guard let i = index(at: t), !clips[i].freeze else { return false }
        let c = clips[i]
        let local = t - st[i]
        if local < 0.1 || local > c.outDuration - 0.1 { return false }
        let srcSplit = c.srcStart + local * c.style.speed
        var a = c
        a.srcEnd = srcSplit
        var b = c
        b.id = UUID()
        b.srcStart = srcSplit
        clips[i] = a
        clips.insert(b, at: i + 1)
        return true
    }

    mutating func insert(_ new: [Clip], at t: Double) {
        if clips.isEmpty { clips = new; return }
        _ = split(at: t)
        clips.insert(contentsOf: new, at: nearestBoundary(to: t))
    }

    mutating func addFreeze(at t: Double) {
        let st = starts()
        guard let i = index(at: t), !clips[i].freeze else { return }
        let c = clips[i]
        let local = min(max(0, t - st[i]), c.outDuration)
        let srcTime = max(0, min(c.srcEnd - 0.02, c.srcStart + local * c.style.speed))
        _ = split(at: t)
        var f = Clip(mediaID: c.mediaID, srcStart: srcTime, srcEnd: srcTime + 0.01)
        f.freeze = true
        f.freezeLength = 2
        f.style = c.style
        f.style.speed = 1
        clips.insert(f, at: nearestBoundary(to: t))
    }
}

enum Geometry {
    static func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }

    static func rotatedSize(_ s: CGSize, rotation: Int) -> CGSize {
        rotation % 180 == 0 ? s : CGSize(width: s.height, height: s.width)
    }

    static func canvasSize(first: CGSize, timeline s: Timeline, maxLongSide: CGFloat) -> CGSize {
        let r = s.canvas.ratio ?? (first.width / max(1, first.height))
        var short: CGFloat = s.resolution.shortSide ?? min(first.width, first.height)
        if s.resolution == .original && s.enhance { short *= 2 }
        var w: CGFloat
        var h: CGFloat
        if r >= 1 { h = short; w = short * r } else { w = short; h = short / r }
        let long = max(w, h)
        if long > maxLongSide {
            let k = maxLongSide / long
            w *= k
            h *= k
        }
        return CGSize(width: even(w), height: even(h))
    }

    static func previewSize(_ out: CGSize, maxLong: CGFloat = 960) -> CGSize {
        let l = max(out.width, out.height)
        let k = min(1, maxLong / max(1, l))
        return CGSize(width: even(out.width * k), height: even(out.height * k))
    }
}

extension UIImage {
    func normalized(maxSide: CGFloat = 4096) -> UIImage {
        let longest = max(size.width, size.height)
        let k = longest > maxSide ? maxSide / longest : 1
        if imageOrientation == .up && k == 1 { return self }
        let newSize = CGSize(width: size.width * k, height: size.height * k)
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: f).image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
