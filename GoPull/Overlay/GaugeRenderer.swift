//
//  GaugeRenderer.swift
//  GoPull
//
//  Draws a speed gauge into a CGContext.
//
//  Deliberately not a SwiftUI view: the same drawing has to serve the live
//  preview and the frame-by-frame burn-in on export, and Core Graphics is the
//  one thing both can call. It touches no app state -- give it a reading, a
//  rect and a config and it draws, which also means it can be rendered to a
//  PNG and looked at.
//

import CoreGraphics
import CoreText
import Foundation

/// What the gauge is showing at one moment.
struct GaugeReading {
    /// Speed in the config's unit, already smoothed. Nil when there is no fix.
    var speed: Double?
    /// Metres.
    var altitude: Double?

    static let noFix = GaugeReading(speed: nil, altitude: nil)
}

enum GaugeRenderer {

    /// The gauge's box for a frame of this size.
    static func frame(in size: CGSize, config: GaugeConfig) -> CGRect {
        config.placement.rect(in: size, heightRatio: config.kind == .bar ? 0.34 : 1)
    }

    static func draw(_ reading: GaugeReading, in context: CGContext,
                     frameSize: CGSize, config: GaugeConfig, maxSpeed: Double) {
        let rect = frame(in: frameSize, config: config)
        context.saveGState()
        defer { context.restoreGState() }

        // Clip to the gauge before setting a shadow: a shadow on an unclipped
        // 4K context makes Core Graphics consider the whole frame.
        let blur = rect.width * 0.05
        context.clip(to: rect.insetBy(dx: -blur * 3, dy: -blur * 3))

        if config.style.shadow > 0 {
            context.setShadow(offset: CGSize(width: 0, height: -rect.width * 0.012),
                              blur: blur,
                              color: CGColor(srgbRed: 0, green: 0, blue: 0,
                                             alpha: config.style.shadow))
        }

        switch config.kind {
        case .dial:    drawDial(reading, in: context, rect: rect, config: config, maxSpeed: maxSpeed)
        case .digital: drawDigital(reading, in: context, rect: rect, config: config)
        case .bar:     drawBar(reading, in: context, rect: rect, config: config, maxSpeed: maxSpeed)
        }
    }

    // MARK: - Dial

    /// The scale sweeps from lower-left, up over the top, round to lower-right,
    /// leaving a gap at the bottom for the numerals -- what every speedometer
    /// does.
    ///
    /// Core Graphics puts y upward, so angles run anticlockwise from east:
    /// lower-left is 225° and lower-right is -45°, and sweeping *clockwise*
    /// between them means the angle decreases. Getting this backwards puts the
    /// scale under the dial and the gap on top, which is what the first render
    /// showed.
    private static let sweepStart = 1.25 * Double.pi    // 225°, lower left
    private static let sweepEnd   = -0.25 * Double.pi   // -45°, lower right

    private static func angle(forFraction fraction: Double) -> Double {
        sweepStart + (sweepEnd - sweepStart) * min(max(fraction, 0), 1)
    }

    /// A tick step that lands on round numbers -- 0, 10, 20 … not 0, 8, 15, 23.
    static func tickStep(for maxSpeed: Double) -> Double {
        for step in [5.0, 10, 20, 25, 50, 100] where (4...8).contains(maxSpeed / step) {
            return step
        }
        return max(1, (maxSpeed / 6).rounded())
    }

    private static func drawDial(_ reading: GaugeReading, in context: CGContext,
                                 rect: CGRect, config: GaugeConfig, maxSpeed: Double) {
        let style = config.style
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2

        if style.face.a > 0 {
            context.setFillColor(style.face.cgColor)
            context.fillEllipse(in: rect)
        }
        if style.bezelWidth > 0, style.bezel.a > 0 {
            context.setStrokeColor(style.bezel.cgColor)
            context.setLineWidth(style.bezelWidth * radius / 100)
            context.strokeEllipse(in: rect.insetBy(dx: style.bezelWidth * radius / 200,
                                                   dy: style.bezelWidth * radius / 200))
        }
        context.setShadow(offset: .zero, blur: 0, color: nil)   // marks stay crisp

        let fraction = reading.speed.map { min(max($0 / maxSpeed, 0), 1) }

        // Ticks, and a number on each major one.
        if style.ticks.a > 0, style.majorTickWidth > 0 {
            let step = tickStep(for: maxSpeed)
            let majors = max(Int((maxSpeed / step).rounded()), 1)
            let minors = style.minorTicksPerMajor
            let total = majors * max(minors + 1, 1)
            for step in 0...total {
                let isMajor = minors == 0 || step % (minors + 1) == 0
                let theta = angle(forFraction: Double(step) / Double(total))
                let outer = radius * 0.94
                let inner = radius * (isMajor ? 0.80 : 0.87)
                context.setStrokeColor(style.ticks.cgColor)
                context.setLineWidth((isMajor ? style.majorTickWidth : style.minorTickWidth)
                                     * radius / 100)
                context.setLineCap(.round)
                context.move(to: CGPoint(x: centre.x + cos(theta) * inner,
                                         y: centre.y + sin(theta) * inner))
                context.addLine(to: CGPoint(x: centre.x + cos(theta) * outer,
                                            y: centre.y + sin(theta) * outer))
                context.strokePath()

                if isMajor {
                    let value = maxSpeed * Double(step) / Double(total)
                    let at = CGPoint(x: centre.x + cos(theta) * radius * 0.66,
                                     y: centre.y + sin(theta) * radius * 0.66)
                    text(String(Int(value.rounded())), centredAt: at, size: radius * 0.15,
                         font: style.captionFont, color: style.ticks, in: context)
                }
            }
        }

        // The arc that tracks the value.
        if style.arcWidth > 0, style.arc.a > 0, let fraction {
            context.setStrokeColor(style.arc.cgColor)
            context.setLineWidth(style.arcWidth * radius / 100)
            context.setLineCap(.round)
            context.addArc(center: centre, radius: radius * 0.94,
                           startAngle: angle(forFraction: 0),
                           endAngle: angle(forFraction: fraction),
                           clockwise: true)
            context.strokePath()
        }

        // The needle.
        if let fraction {
            let theta = angle(forFraction: fraction)
            let length = radius * 0.72
            let tail = radius * 0.16
            context.setStrokeColor(style.needle.cgColor)
            context.setLineWidth(max(radius * 0.035, 1.5))
            context.setLineCap(.round)
            context.move(to: CGPoint(x: centre.x - cos(theta) * tail,
                                     y: centre.y - sin(theta) * tail))
            context.addLine(to: CGPoint(x: centre.x + cos(theta) * length,
                                        y: centre.y + sin(theta) * length))
            context.strokePath()

            context.setFillColor(style.needle.cgColor)
            let hub = radius * 0.075
            context.fillEllipse(in: CGRect(x: centre.x - hub, y: centre.y - hub,
                                           width: hub * 2, height: hub * 2))
        }

        // The reading, in the gap the scale leaves at the bottom.
        let value = reading.speed.map { String(Int($0.rounded())) } ?? "--"
        text(value, centredAt: CGPoint(x: centre.x, y: centre.y - radius * 0.42),
             size: radius * 0.34, font: style.numberFont, color: style.text, in: context)
        text(config.unit.label,
             centredAt: CGPoint(x: centre.x, y: centre.y - radius * 0.66),
             size: radius * 0.13, font: style.captionFont, color: style.caption, in: context)
    }

    // MARK: - Digital

    private static func drawDigital(_ reading: GaugeReading, in context: CGContext,
                                    rect: CGRect, config: GaugeConfig) {
        let style = config.style
        if style.face.a > 0 {
            let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.08,
                              cornerHeight: rect.width * 0.08, transform: nil)
            context.setFillColor(style.face.cgColor)
            context.addPath(path); context.fillPath()
            if style.bezelWidth > 0, style.bezel.a > 0 {
                context.setStrokeColor(style.bezel.cgColor)
                context.setLineWidth(style.bezelWidth * rect.width / 200)
                context.addPath(path); context.strokePath()
            }
        }
        context.setShadow(offset: .zero, blur: 0, color: nil)

        let value = reading.speed.map { String(Int($0.rounded())) } ?? "--"
        text(value, centredAt: CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.06),
             size: rect.height * 0.46, font: style.numberFont, color: style.text, in: context)
        text(config.unit.label,
             centredAt: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.17),
             size: rect.height * 0.13, font: style.captionFont,
             color: style.caption, in: context)
    }

    // MARK: - Bar

    private static func drawBar(_ reading: GaugeReading, in context: CGContext,
                                rect: CGRect, config: GaugeConfig, maxSpeed: Double) {
        let style = config.style
        let radius = rect.height / 2
        let shell = CGPath(roundedRect: rect, cornerWidth: radius,
                           cornerHeight: radius, transform: nil)
        if style.face.a > 0 {
            context.setFillColor(style.face.cgColor)
            context.addPath(shell); context.fillPath()
        }
        context.setShadow(offset: .zero, blur: 0, color: nil)

        // Numerals get their own third. Drawing them over the fill made the
        // Minimal preset white-on-white and unreadable.
        let readout = CGRect(x: rect.minX + rect.height * 0.20, y: rect.minY,
                             width: rect.width * 0.34, height: rect.height)
        let track = CGRect(x: readout.maxX + rect.height * 0.16,
                           y: rect.midY - rect.height * 0.16,
                           width: rect.maxX - readout.maxX - rect.height * 0.50,
                           height: rect.height * 0.32)

        context.setFillColor(style.ticks.a > 0 ? style.ticks.opacity(0.25).cgColor
                                               : style.text.opacity(0.2).cgColor)
        context.addPath(CGPath(roundedRect: track, cornerWidth: track.height / 2,
                               cornerHeight: track.height / 2, transform: nil))
        context.fillPath()

        if let speed = reading.speed {
            let fraction = min(max(speed / maxSpeed, 0), 1)
            let filled = CGRect(x: track.minX, y: track.minY,
                                width: max(track.height, track.width * fraction),
                                height: track.height)
            context.addPath(CGPath(roundedRect: filled, cornerWidth: track.height / 2,
                                   cornerHeight: track.height / 2, transform: nil))
            context.setFillColor(style.arc.a > 0 ? style.arc.cgColor : style.needle.cgColor)
            context.fillPath()
        }
        if style.bezelWidth > 0, style.bezel.a > 0 {
            context.setStrokeColor(style.bezel.cgColor)
            context.setLineWidth(style.bezelWidth * rect.height / 60)
            context.addPath(shell); context.strokePath()
        }

        let value = reading.speed.map { String(Int($0.rounded())) } ?? "--"
        text(value, centredAt: CGPoint(x: readout.midX, y: rect.midY + rect.height * 0.06),
             size: rect.height * 0.46, font: style.numberFont, color: style.text, in: context)
        text(config.unit.label,
             centredAt: CGPoint(x: readout.midX, y: rect.minY + rect.height * 0.20),
             size: rect.height * 0.17, font: style.captionFont,
             color: style.caption, in: context)
    }

    // MARK: - Text

    /// Draws centred text with CoreText, which works without a view or NSFont.
    private static func text(_ string: String, centredAt point: CGPoint, size: CGFloat,
                             font name: String, color: RGBA, in context: CGContext) {
        guard !string.isEmpty, size > 0, color.a > 0 else { return }
        let font = CTFontCreateWithName(name as CFString, size, nil)
        // CoreText's own attribute keys, not NSAttributedString.Key: those live
        // in AppKit, and MEMBER_IMPORT_VISIBILITY would drag it in for nothing.
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color.cgColor,
        ] as CFDictionary
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, string as CFString, attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: point.x - bounds.width / 2 - bounds.minX,
                                       y: point.y - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }
}
