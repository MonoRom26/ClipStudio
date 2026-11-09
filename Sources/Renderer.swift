import SwiftUI
import CoreImage

/// Builds one finished frame of the project (same code for preview and export).
final class Renderer {
    let tl: Timeline
    let outSize: CGSize
    private let infos: [UUID: MediaInfo]
    private let starts: [Double]
    private var overlayImages: [UUID: CIImage] = [:]

    init(timeline: Timeline, infos: [UUID: MediaInfo], outSize: CGSize) {
        self.tl = timeline
        self.outSize = outSize
        self.infos = infos
        self.starts = timeline.starts()
        for o in timeline.overlays {
            if let img = Renderer.overlayImage(o, outSize: outSize) { overlayImages[o.id] = img }
        }
    }

    func normalizedSizes() -> [UUID: CGSize] {
        overlayImages.mapValues {
            CGSize(width: $0.extent.width / max(1, outSize.width), height: $0.extent.height / max(1, outSize.height))
        }
    }

    private func clipIndex(at t: Double) -> Int? {
        if tl.clips.isEmpty { return nil }
        for i in tl.clips.indices where t >= starts[i] && t < starts[i] + tl.clips[i].outDuration { return i }
        return tl.clips.count - 1
    }

    // MARK: main
    func render(_ src: CIImage, t: Double) -> CIImage {
        let rect = CGRect(origin: .zero, size: outSize)
        let black = CIImage(color: CIColor.black).cropped(to: rect)
        var img = black

        if !tl.videoHidden, let i = clipIndex(at: t) {
            let clip = tl.clips[i]
            img = place(src, clip: clip, canvas: black)
            img = adjust(img, clip.style)
            img = applyFilter(img, clip.style)
            img = applyEffect(img, clip.style)
        }

        let active = tl.regions.filter { $0.enabled && ($0.wholeVideo || (t >= $0.start && t <= $0.end)) }
        if !active.isEmpty { img = removeText(img, regions: active) }

        if tl.enhance {
            img = img.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02, "inputSharpness": 0.5])
            img = img.applyingFilter("CIUnsharpMask", parameters: ["inputRadius": 2.0, "inputIntensity": 0.7])
            img = img.applyingFilter("CIColorControls", parameters: ["inputContrast": 1.04, "inputSaturation": 1.06])
        }

        if !tl.overlayHidden { img = compositeOverlays(img, t: t) }
        return img.cropped(to: rect)
    }

    // MARK: place clip on the canvas (orientation, rotate, flip, fit/fill, zoom, pan)
    private func place(_ src: CIImage, clip: Clip, canvas: CIImage) -> CIImage {
        var im = src
        if let o = infos[clip.mediaID]?.orientation, o != .up { im = im.oriented(o) }
        let st = clip.style
        if st.flipH { im = im.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
        if st.rotation != 0 {
            im = im.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(st.rotation) * .pi / 180))
        }
        im = im.transformed(by: CGAffineTransform(translationX: -im.extent.minX, y: -im.extent.minY))
        let sz = im.extent.size
        guard sz.width > 0, sz.height > 0 else { return canvas }

        let fit = min(outSize.width / sz.width, outSize.height / sz.height)
        let fill = max(outSize.width / sz.width, outSize.height / sz.height)
        let k = (st.fill ? fill : fit) * CGFloat(max(1, st.zoom))
        let scaled = im.applyingFilter("CILanczosScaleTransform",
                                       parameters: ["inputScale": k, "inputAspectRatio": 1.0])
        let slackX = sz.width * k - outSize.width
        let slackY = sz.height * k - outSize.height
        let dx = slackX >= 0 ? -slackX / 2 * (1 + CGFloat(st.panX)) : -slackX / 2
        let dy = slackY >= 0 ? -slackY / 2 * (1 + CGFloat(st.panY)) : -slackY / 2
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .composited(over: canvas)
            .cropped(to: CGRect(origin: .zero, size: outSize))
    }

    // MARK: text removal
    private func removeText(_ img: CIImage, regions: [TextRegion]) -> CIImage {
        let ext = img.extent
        let clamped = img.clampedToExtent()
        var result = img
        for r in regions {
            let rect = CGRect(x: ext.minX + r.rect.minX * ext.width,
                              y: ext.minY + (1 - r.rect.maxY) * ext.height,
                              width: r.rect.width * ext.width,
                              height: r.rect.height * ext.height).intersection(ext)
            if rect.isNull || rect.width < 2 || rect.height < 2 { continue }

            let fill: CIImage
            switch tl.fillStyle {
            case .patch:
                let h = rect.height
                let spaceAbove = ext.maxY - rect.maxY
                let dy: CGFloat = spaceAbove >= h ? -h : h
                fill = clamped.transformed(by: CGAffineTransform(translationX: 0, y: dy))
            case .blur:
                fill = clamped.applyingFilter("CIGaussianBlur",
                                              parameters: ["inputRadius": max(rect.width, rect.height) * 0.3])
            }

            let feather = max(2, min(rect.width, rect.height) * 0.2)
            let inner = rect.insetBy(dx: min(feather * 0.5, rect.width * 0.2),
                                     dy: min(feather * 0.5, rect.height * 0.2))
            let mask = CIImage(color: CIColor.white).cropped(to: inner)
                .composited(over: CIImage(color: CIColor.black).cropped(to: ext))
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": feather * 0.5])
                .cropped(to: ext)

            result = fill.cropped(to: ext).applyingFilter("CIBlendWithMask",
                parameters: ["inputBackgroundImage": result, "inputMaskImage": mask])
        }
        return result
    }

    // MARK: adjust / filter / effect
    private func matrix(_ img: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }

    private func adjust(_ img: CIImage, _ s: ClipStyle) -> CIImage {
        var out = img
        if s.brightness != 0 || s.contrast != 1 || s.saturation != 1 {
            out = out.applyingFilter("CIColorControls", parameters: [
                "inputBrightness": s.brightness, "inputContrast": s.contrast, "inputSaturation": s.saturation])
        }
        if s.warmth != 0 {
            let w = CGFloat(s.warmth) * 0.25
            out = matrix(out, r: 1 + w, g: 1, b: 1 - w)
        }
        if s.sharpness > 0 {
            out = out.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": s.sharpness])
        }
        if s.vignette > 0 {
            out = out.applyingFilter("CIVignette", parameters: ["inputIntensity": s.vignette, "inputRadius": 1.5])
        }
        return out
    }

    private func applyFilter(_ img: CIImage, _ s: ClipStyle) -> CIImage {
        let f: CIImage
        switch s.filter {
        case .none: return img
        case .vivid: f = img.applyingFilter("CIColorControls", parameters: ["inputSaturation": 1.5, "inputContrast": 1.1])
        case .warm: f = matrix(img, r: 1.12, g: 1.0, b: 0.88)
        case .cool: f = matrix(img, r: 0.9, g: 1.0, b: 1.12)
        case .noir: f = img.applyingFilter("CIPhotoEffectNoir")
        case .mono: f = img.applyingFilter("CIPhotoEffectMono")
        case .chrome: f = img.applyingFilter("CIPhotoEffectChrome")
        case .fade: f = img.applyingFilter("CIPhotoEffectFade")
        case .instant: f = img.applyingFilter("CIPhotoEffectInstant")
        case .process: f = img.applyingFilter("CIPhotoEffectProcess")
        case .tonal: f = img.applyingFilter("CIPhotoEffectTonal")
        case .transfer: f = img.applyingFilter("CIPhotoEffectTransfer")
        case .sepia: f = img.applyingFilter("CISepiaTone", parameters: ["inputIntensity": 0.9])
        case .dramatic:
            f = img.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.75, "inputContrast": 1.35])
                .applyingFilter("CIVignette", parameters: ["inputIntensity": 0.8, "inputRadius": 1.5])
        case .cinema:
            let c = img.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.9, "inputContrast": 1.15])
            f = matrix(c, r: 1.08, g: 1.0, b: 0.95)
        }
        if s.filterAmount >= 0.99 { return f }
        return img.applyingFilter("CIDissolveTransition",
                                  parameters: ["inputTargetImage": f, "inputTime": s.filterAmount])
    }

    private func applyEffect(_ img: CIImage, _ s: ClipStyle) -> CIImage {
        let ext = img.extent
        let a = CGFloat(s.effectAmount)
        switch s.effect {
        case .none:
            return img
        case .blur:
            return img.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": a * 25]).cropped(to: ext)
        case .pixelate:
            return img.applyingFilter("CIPixellate", parameters: [
                "inputScale": 4 + a * 0.05 * min(ext.width, ext.height),
                "inputCenter": CIVector(x: 0, y: 0)]).cropped(to: ext)
        case .glow:
            return img.applyingFilter("CIBloom", parameters: [
                "inputRadius": 10 + a * 30, "inputIntensity": a * 1.5]).cropped(to: ext)
        case .comic:
            return img.applyingFilter("CIComicEffect").cropped(to: ext)
        case .zoomBlur:
            return img.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                "inputCenter": CIVector(x: ext.midX, y: ext.midY),
                "inputAmount": a * 30]).cropped(to: ext)
        case .glitch:
            let off = a * 0.02 * ext.width
            func channel(_ rv: CIVector, _ gv: CIVector, _ bv: CIVector, dx: CGFloat) -> CIImage {
                img.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": rv, "inputGVector": gv, "inputBVector": bv,
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
                    .clampedToExtent()
                    .transformed(by: CGAffineTransform(translationX: dx, y: 0))
            }
            let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
            let red = channel(CIVector(x: 1, y: 0, z: 0, w: 0), zero, zero, dx: off)
            let green = channel(zero, CIVector(x: 0, y: 1, z: 0, w: 0), zero, dx: 0)
            let blue = channel(zero, zero, CIVector(x: 0, y: 0, z: 1, w: 0), dx: -off)
            return red
                .applyingFilter("CIAdditionCompositing", parameters: ["inputBackgroundImage": green])
                .applyingFilter("CIAdditionCompositing", parameters: ["inputBackgroundImage": blue])
                .cropped(to: ext)
        }
    }

    // MARK: overlays
    private func compositeOverlays(_ base: CIImage, t: Double) -> CIImage {
        var out = base
        for o in tl.overlays {
            guard t >= o.start && t <= o.end, var img = overlayImages[o.id] else { continue }
            let e = img.extent
            img = img.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY))
            if o.rotation != 0 {
                img = img.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(o.rotation) * .pi / 180))
            }
            if o.opacity < 1 {
                img = img.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(o.opacity))])
            }
            img = img.transformed(by: CGAffineTransform(translationX: CGFloat(o.x) * outSize.width,
                                                         y: (1 - CGFloat(o.y)) * outSize.height))
            out = img.composited(over: out)
        }
        return out
    }

    private static func overlayImage(_ o: OverlayItem, outSize: CGSize) -> CIImage? {
        switch o.kind {
        case .text, .emoji:
            guard !o.text.isEmpty else { return nil }
            let fontSize = max(8, CGFloat(o.size) * outSize.height)
            let font: UIFont = (o.kind == .text && o.bold) ? UIFont.boldSystemFont(ofSize: fontSize)
                                                            : UIFont.systemFont(ofSize: fontSize)
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: UIColor(o.color), .paragraphStyle: para]
            let str = NSAttributedString(string: o.text, attributes: attrs)
            let maxW = outSize.width * 0.9
            let bounds = str.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            let pad = o.background ? fontSize * 0.3 : fontSize * 0.1
            let size = CGSize(width: ceil(bounds.width) + pad * 2, height: ceil(bounds.height) + pad * 2)
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            fmt.opaque = false
            let image = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
                if o.background {
                    UIColor.black.withAlphaComponent(0.55).setFill()
                    UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: fontSize * 0.3).fill()
                }
                str.draw(with: CGRect(x: pad, y: pad, width: ceil(bounds.width), height: ceil(bounds.height)),
                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
            return CIImage(image: image)
        case .image:
            guard let d = o.imageData, let ui = UIImage(data: d)?.normalized(maxSide: 2048),
                  let ci = CIImage(image: ui) else { return nil }
            let k = CGFloat(o.size) * outSize.width / max(1, ci.extent.width)
            return ci.transformed(by: CGAffineTransform(scaleX: k, y: k))
        }
    }
}
