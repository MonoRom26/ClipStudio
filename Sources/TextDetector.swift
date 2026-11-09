import Foundation
import Vision
import CoreGraphics

/// Finds text areas with Apple's Vision framework (works offline).
enum TextDetector {
    /// Returns boxes normalized 0...1 with origin at the TOP-left.
    static func detect(_ cg: CGImage, accurate: Bool) -> [CGRect] {
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let r1 = VNDetectTextRectanglesRequest()
        r1.reportCharacterBoxes = false
        let r2 = VNRecognizeTextRequest()
        r2.recognitionLevel = accurate ? .accurate : .fast
        r2.usesLanguageCorrection = false
        try? handler.perform([r1, r2])

        var rects: [CGRect] = []
        for o in (r1.results as? [VNTextObservation]) ?? [] { rects.append(flip(o.boundingBox)) }
        for o in (r2.results as? [VNRecognizedTextObservation]) ?? [] { rects.append(flip(o.boundingBox)) }
        return mergeLines(rects)
    }

    private static func flip(_ b: CGRect) -> CGRect {
        CGRect(x: b.minX, y: 1 - b.minY - b.height, width: b.width, height: b.height)
    }

    /// Joins boxes that overlap or sit side by side on the same line.
    private static func mergeLines(_ input: [CGRect]) -> [CGRect] {
        var boxes = input.filter { $0.width > 0.005 && $0.height > 0.005 }
        var changed = true
        while changed {
            changed = false
            outer: for i in 0..<boxes.count {
                for j in (i + 1)..<max(i + 1, boxes.count) {
                    let a = boxes[i], b = boxes[j]
                    let vOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                    let minH = min(a.height, b.height)
                    let hGap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                    let overlaps = !a.intersection(b).isNull
                    if overlaps || (vOverlap > 0.5 * minH && hGap < 1.5 * max(a.height, b.height)) {
                        boxes[i] = a.union(b)
                        boxes.remove(at: j)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return boxes
    }
}
