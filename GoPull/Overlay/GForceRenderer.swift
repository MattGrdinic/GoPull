//
//  GForceRenderer.swift
//  GoPull
//
//  A g-force meter: a ball on a target, the way racing telemetry shows it.
//
//  Lateral across, longitudinal up and down, so braking pulls the ball toward
//  the viewer and a left-hander pushes it left. Rings mark whole and half g.
//  A short trail is drawn behind it, because a single dot tells you the number
//  and the trail tells you what the rider just did.
//

import CoreGraphics
import CoreText
import Foundation

struct GForceStyle: Equatable, Codable {
    var face: RGBA
    var rings: RGBA
    var ringWidth: Double
    var crosshair: RGBA
    /// The ball itself.
    var ball: RGBA
    var ballRing: RGBA
    /// Where it has just been.
    var trail: RGBA
    var text: RGBA
    var caption: RGBA
    var numberFont: String
    var captionFont: String
    var shadow: Double

    static func matching(_ preset: GaugePreset) -> GForceStyle {
        let gauge = GaugeStyle.preset(preset)
        switch preset {
        case .modern:
            return GForceStyle(face: RGBA(0.06, 0.07, 0.09, 0.55),
                               rings: RGBA(1, 1, 1, 0.30), ringWidth: 1.6,
                               crosshair: RGBA(1, 1, 1, 0.18),
                               ball: gauge.needle, ballRing: RGBA(1, 1, 1, 0.9),
                               trail: RGBA(0.20, 0.65, 1.0, 0.55),
                               text: RGBA(1, 1, 1), caption: RGBA(1, 1, 1, 0.65),
                               numberFont: "HelveticaNeue-Bold",
                               captionFont: "HelveticaNeue-Medium", shadow: 0.55)
        case .classic:
            return GForceStyle(face: RGBA(0.94, 0.91, 0.83, 0.92),
                               rings: RGBA(0.20, 0.18, 0.15, 0.45), ringWidth: 2.0,
                               crosshair: RGBA(0.20, 0.18, 0.15, 0.25),
                               ball: RGBA(0.78, 0.10, 0.09),
                               ballRing: RGBA(0.98, 0.96, 0.90, 0.95),
                               trail: RGBA(0.78, 0.10, 0.09, 0.35),
                               text: RGBA(0.10, 0.09, 0.08), caption: RGBA(0.32, 0.29, 0.25),
                               numberFont: "Times-Bold", captionFont: "Times-Roman",
                               shadow: 0.35)
        case .hiTech:
            return GForceStyle(face: RGBA(0.02, 0.04, 0.06, 0.72),
                               rings: RGBA(0.0, 0.85, 0.95, 0.45), ringWidth: 1.4,
                               crosshair: RGBA(0.0, 0.85, 0.95, 0.22),
                               ball: RGBA(0.0, 0.95, 0.85),
                               ballRing: RGBA(0.85, 1.0, 1.0, 0.9),
                               trail: RGBA(0.0, 0.85, 0.95, 0.5),
                               text: RGBA(0.85, 1.0, 1.0), caption: RGBA(0.0, 0.85, 0.95, 0.8),
                               numberFont: "Menlo-Bold", captionFont: "Menlo-Regular",
                               shadow: 0.7)
        case .minimal:
            return GForceStyle(face: RGBA(0, 0, 0, 0),
                               rings: RGBA(1, 1, 1, 0.22), ringWidth: 1.0,
                               crosshair: RGBA(1, 1, 1, 0.12),
                               ball: RGBA(1, 1, 1), ballRing: RGBA(0, 0, 0, 0.35),
                               trail: RGBA(1, 1, 1, 0.30),
                               text: RGBA(1, 1, 1), caption: RGBA(1, 1, 1, 0.6),
                               numberFont: "HelveticaNeue-Thin", captionFont: "HelveticaNeue",
                               shadow: 0.8)
        }
    }
}

struct GForceConfig: Equatable, Codable {
    var preset: GaugePreset = .modern
    var style: GForceStyle = .matching(.modern)
    var placement: OverlayPlacement = .corner(.topRight, scale: 0.16)
    /// Full-scale deflection, in g. Nil fits the clip.
    var maxG: Double?
    /// Seconds of trail behind the ball. Zero draws none.
    var trailSeconds: Double = 1.2
    var smoothingSeconds: Double = 0.3
    var showsReading: Bool = true

    var smoothing: Smoothing { Smoothing(seconds: smoothingSeconds) }

    mutating func apply(_ preset: GaugePreset) {
        self.preset = preset
        self.style = .matching(preset)
    }

    /// A round full scale above what the clip actually pulled.
    static func niceMaximum(above g: Double) -> Double {
        for candidate in [0.5, 1.0, 1.5, 2.0, 3.0, 4.0] where candidate >= g * 1.1 {
            return candidate
        }
        return max(1.0, (g * 1.2).rounded(.up))
    }
}

enum GForceRenderer {

    /// Taller than it is wide: the circle takes the top, and the reading gets
    /// a strip of its own underneath.
    ///
    /// Putting the number inside the circle does not work — the ball travels
    /// through wherever it would sit. At 0.97 g on a 1.5 g scale the two landed
    /// on exactly the same spot.
    static let readoutStrip = 0.20

    static func frame(in size: CGSize, config: GForceConfig) -> CGRect {
        config.placement.rect(in: size,
                              heightRatio: config.showsReading ? 1 + readoutStrip : 1)
    }

    /// `trail` is the recent history, oldest first, in the same units.
    static func draw(_ reading: GForceSample?, trail: [GForceSample],
                     in context: CGContext, frameSize: CGSize,
                     config: GForceConfig, maxG: Double) {
        let rect = frame(in: frameSize, config: config)
        // The circle occupies the top square of the box; anything below it is
        // the readout strip.
        let dial = CGRect(x: rect.minX, y: rect.maxY - rect.width,
                          width: rect.width, height: rect.width)
        let centre = CGPoint(x: dial.midX, y: dial.midY)
        let radius = rect.width / 2
        let style = config.style
        guard maxG > 0 else { return }

        context.saveGState()
        defer { context.restoreGState() }

        // Clip before the shadow, for the reason in DECISIONS #21's neighbour:
        // a shadow on an unclipped 8K frame makes Core Graphics consider the
        // whole thing.
        let blur = radius * 0.10
        context.clip(to: rect.insetBy(dx: -blur * 3, dy: -blur * 3))
        if style.shadow > 0 {
            context.setShadow(offset: CGSize(width: 0, height: -radius * 0.03), blur: blur,
                              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: style.shadow))
        }
        if style.face.a > 0 {
            context.setFillColor(style.face.cgColor)
            context.fillEllipse(in: dial)
        }
        context.setShadow(offset: .zero, blur: 0, color: nil)

        /// g to a point on the target.
        func place(_ sample: GForceSample) -> CGPoint {
            let scale = radius * 0.86 / maxG
            let x = centre.x + sample.lateral * scale
            // Braking is negative longitudinal and should pull the ball down,
            // and Core Graphics y goes up, so the sign works out directly.
            let y = centre.y + sample.longitudinal * scale
            return CGPoint(x: x, y: y)
        }

        // Rings at each whole or half g that fits.
        if style.rings.a > 0 {
            let step: Double = maxG <= 1 ? 0.25 : (maxG <= 2 ? 0.5 : 1.0)
            var value = step
            context.setStrokeColor(style.rings.cgColor)
            context.setLineWidth(style.ringWidth * radius / 100)
            while value <= maxG + 0.0001 {
                let r = radius * 0.86 * (value / maxG)
                context.strokeEllipse(in: CGRect(x: centre.x - r, y: centre.y - r,
                                                 width: r * 2, height: r * 2))
                value += step
            }
        }
        if style.crosshair.a > 0 {
            context.setStrokeColor(style.crosshair.cgColor)
            context.setLineWidth(max(radius * 0.012, 0.5))
            let reach = radius * 0.86
            context.move(to: CGPoint(x: centre.x - reach, y: centre.y))
            context.addLine(to: CGPoint(x: centre.x + reach, y: centre.y))
            context.move(to: CGPoint(x: centre.x, y: centre.y - reach))
            context.addLine(to: CGPoint(x: centre.x, y: centre.y + reach))
            context.strokePath()
        }

        if trail.count > 1, style.trail.a > 0 {
            context.setStrokeColor(style.trail.cgColor)
            context.setLineWidth(max(radius * 0.035, 1))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: place(trail[0]))
            for sample in trail.dropFirst() { context.addLine(to: place(sample)) }
            context.strokePath()
        }

        if let reading {
            let at = place(reading)
            let dot = radius * 0.09
            context.setFillColor(style.ballRing.cgColor)
            context.fillEllipse(in: CGRect(x: at.x - dot * 1.4, y: at.y - dot * 1.4,
                                           width: dot * 2.8, height: dot * 2.8))
            context.setFillColor(style.ball.cgColor)
            context.fillEllipse(in: CGRect(x: at.x - dot, y: at.y - dot,
                                           width: dot * 2, height: dot * 2))
        }

        if config.showsReading {
            // Inside the disc, not on its edge: at radius * 0.20 the number sat
            // on the rim and the unit fell outside the circle entirely.
            let value = reading.map { String(format: "%.2f g", $0.planar) } ?? "-- g"
            text(value, centredAt: CGPoint(x: rect.midX,
                                           y: rect.minY + rect.width * readoutStrip * 0.5),
                 size: radius * 0.30, font: style.numberFont, color: style.text, in: context)
        }
    }

    private static func text(_ string: String, centredAt point: CGPoint, size: CGFloat,
                             font name: String, color: RGBA, in context: CGContext) {
        guard !string.isEmpty, size > 0, color.a > 0 else { return }
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let attributes = [kCTFontAttributeName: font,
                          kCTForegroundColorAttributeName: color.cgColor] as CFDictionary
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, string as CFString, attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: point.x - bounds.width / 2 - bounds.minX,
                                       y: point.y - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }
}
