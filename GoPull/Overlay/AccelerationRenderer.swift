//
//  AccelerationRenderer.swift
//  GoPull
//
//  The standing-start badge: 0-30, 0-60, ticking over as they are reached.
//
//  Two jobs at once, which is why it is a panel rather than a dial. While a run
//  is happening it is a stopwatch — the clock runs and each target lands as it
//  is passed. Afterwards it is a scorecard, and if the clip holds an earlier
//  run it shows the difference against the best one, because a second 0-60 is
//  only interesting next to the first.
//

import CoreGraphics
import CoreText
import Foundation

struct AccelerationStyle: Equatable, Codable {
    var face: RGBA
    var bezel: RGBA
    var bezelWidth: Double
    var label: RGBA
    var value: RGBA
    /// A target that has been reached this run.
    var reached: RGBA
    /// Quicker than the best previous run.
    var faster: RGBA
    var slower: RGBA
    var numberFont: String
    var captionFont: String
    var shadow: Double

    static func matching(_ preset: GaugePreset) -> AccelerationStyle {
        switch preset {
        case .modern:
            return AccelerationStyle(face: RGBA(0.06, 0.07, 0.09, 0.60),
                                     bezel: RGBA(1, 1, 1, 0.20), bezelWidth: 1.5,
                                     label: RGBA(1, 1, 1, 0.62), value: RGBA(1, 1, 1),
                                     reached: RGBA(0.20, 0.65, 1.0),
                                     faster: RGBA(0.30, 0.85, 0.45),
                                     slower: RGBA(1, 0.45, 0.40),
                                     numberFont: "HelveticaNeue-Bold",
                                     captionFont: "HelveticaNeue-Medium", shadow: 0.55)
        case .classic:
            return AccelerationStyle(face: RGBA(0.94, 0.91, 0.83, 0.92),
                                     bezel: RGBA(0.30, 0.30, 0.32, 0.9), bezelWidth: 3,
                                     label: RGBA(0.32, 0.29, 0.25), value: RGBA(0.10, 0.09, 0.08),
                                     reached: RGBA(0.78, 0.10, 0.09),
                                     faster: RGBA(0.16, 0.42, 0.20),
                                     slower: RGBA(0.62, 0.16, 0.12),
                                     numberFont: "Times-Bold", captionFont: "Times-Roman",
                                     shadow: 0.35)
        case .hiTech:
            return AccelerationStyle(face: RGBA(0.02, 0.04, 0.06, 0.75),
                                     bezel: RGBA(0.0, 0.85, 0.95, 0.5), bezelWidth: 1.2,
                                     label: RGBA(0.0, 0.85, 0.95, 0.8),
                                     value: RGBA(0.85, 1.0, 1.0),
                                     reached: RGBA(0.0, 0.95, 0.85),
                                     faster: RGBA(0.35, 1.0, 0.55),
                                     slower: RGBA(1.0, 0.42, 0.42),
                                     numberFont: "Menlo-Bold", captionFont: "Menlo-Regular",
                                     shadow: 0.7)
        case .minimal:
            return AccelerationStyle(face: RGBA(0, 0, 0, 0),
                                     bezel: RGBA(1, 1, 1, 0.15), bezelWidth: 1,
                                     label: RGBA(1, 1, 1, 0.55), value: RGBA(1, 1, 1),
                                     reached: RGBA(1, 1, 1),
                                     faster: RGBA(0.55, 0.95, 0.65),
                                     slower: RGBA(1, 0.6, 0.55),
                                     numberFont: "HelveticaNeue-Thin",
                                     captionFont: "HelveticaNeue", shadow: 0.8)
        }
    }
}

struct AccelerationConfig: Equatable, Codable {
    var preset: GaugePreset = .modern
    var style: AccelerationStyle = .matching(.modern)
    var placement: OverlayPlacement = OverlayPlacement(x: 0.5, y: 0.12, scale: 0.24)
    var detection = AccelerationSettings()
    /// How long the result stays up after a run finishes.
    var holdSeconds: Double = 6
    /// Compare against the best earlier run in the clip.
    var comparesToBest: Bool = true

    mutating func apply(_ preset: GaugePreset) {
        self.preset = preset
        self.style = .matching(preset)
    }
}

enum AccelerationRenderer {

    /// Rows plus a title, so the panel grows with the number of targets.
    static func frame(in size: CGSize, config: AccelerationConfig) -> CGRect {
        let rows = max(config.detection.targets.count, 1)
        let ratio = (0.34 + Double(rows) * 0.30)
        return config.placement.rect(in: size, heightRatio: ratio)
    }

    /// `run` is the one in progress or just finished; `best` an earlier one to
    /// measure it against.
    static func draw(_ run: AccelerationRun?, best: AccelerationRun?, at time: Double,
                     in context: CGContext, frameSize: CGSize, config: AccelerationConfig) {
        guard let run else { return }
        let rect = frame(in: frameSize, config: config)
        let style = config.style
        let unit = config.detection.unit

        context.saveGState()
        defer { context.restoreGState() }

        let blur = rect.width * 0.05
        context.clip(to: rect.insetBy(dx: -blur * 3, dy: -blur * 3))
        if style.shadow > 0 {
            context.setShadow(offset: CGSize(width: 0, height: -rect.width * 0.01), blur: blur,
                              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: style.shadow))
        }
        let corner = rect.width * 0.06
        let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner,
                          transform: nil)
        if style.face.a > 0 {
            context.setFillColor(style.face.cgColor)
            context.addPath(path); context.fillPath()
        }
        if style.bezelWidth > 0, style.bezel.a > 0 {
            context.setStrokeColor(style.bezel.cgColor)
            context.setLineWidth(style.bezelWidth * rect.width / 200)
            context.addPath(path); context.strokePath()
        }
        context.setShadow(offset: .zero, blur: 0, color: nil)

        let rows = config.detection.targets.sorted()
        let rowHeight = rect.height * 0.30 / (0.34 + Double(rows.count) * 0.30)
        let titleY = rect.maxY - rect.height * 0.34 / (0.34 + Double(rows.count) * 0.30) * 0.55
        let elapsed = time - run.start

        let reachedSoFar = rows.filter { (run.splits[$0] ?? .infinity) <= elapsed }.count
        text(reachedSoFar < rows.count
             ? String(format: "LAUNCH  %.2fs", max(elapsed, 0))
             : "LAUNCH",
             at: CGPoint(x: rect.midX, y: titleY), size: rect.width * 0.085,
             font: style.captionFont, color: style.label, align: .centre, in: context)

        for (index, target) in rows.enumerated() {
            let y = rect.maxY - rect.height * 0.34 / (0.34 + Double(rows.count) * 0.30)
                  - rowHeight * (Double(index) + 0.5)
            let label = "0–\(target) \(unit.label)"
            text(label, at: CGPoint(x: rect.minX + rect.width * 0.09, y: y),
                 size: rect.width * 0.085, font: style.captionFont,
                 color: style.label, align: .left, in: context)

            // Only what has actually happened by now. Showing the whole run
            // from its first frame turns a stopwatch into a spoiler.
            let takenSoFar = run.splits[target].flatMap { $0 <= elapsed ? $0 : nil }
            if let taken = takenSoFar {
                text(String(format: "%.2fs", taken),
                     at: CGPoint(x: rect.maxX - rect.width * 0.09, y: y),
                     size: rect.width * 0.11, font: style.numberFont,
                     color: style.reached, align: .right, in: context)

                if config.comparesToBest, let best, best.start != run.start,
                   let previous = best.splits[target] {
                    let delta = taken - previous
                    text(String(format: "%+.2f", delta),
                         at: CGPoint(x: rect.maxX - rect.width * 0.09,
                                     y: y - rowHeight * 0.34),
                         size: rect.width * 0.062, font: style.captionFont,
                         color: delta <= 0 ? style.faster : style.slower,
                         align: .right, in: context)
                }
            } else {
                // Not reached yet: show the clock so the panel is alive.
                let pending = elapsed > 0 ? String(format: "%.2fs", elapsed) : "—"
                text(pending, at: CGPoint(x: rect.maxX - rect.width * 0.09, y: y),
                     size: rect.width * 0.11, font: style.numberFont,
                     color: style.value.opacity(0.45), align: .right, in: context)
            }
        }
    }

    private enum Align { case left, centre, right }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat,
                             font name: String, color: RGBA, align: Align,
                             in context: CGContext) {
        guard !string.isEmpty, size > 0, color.a > 0 else { return }
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let attributes = [kCTFontAttributeName: font,
                          kCTForegroundColorAttributeName: color.cgColor] as CFDictionary
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, string as CFString, attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let x: CGFloat
        switch align {
        case .left:   x = point.x - bounds.minX
        case .centre: x = point.x - bounds.width / 2 - bounds.minX
        case .right:  x = point.x - bounds.width - bounds.minX
        }
        context.textPosition = CGPoint(x: x, y: point.y - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }
}
