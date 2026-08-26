//
//  MapRenderer.swift
//  GoPull
//
//  Draws the route and where the rider is on it.
//
//  A vector trace rather than map tiles, for the export path: it needs no
//  network, renders identically every time, carries no attribution obligation
//  into a published video, and composites over footage far better than a
//  photographic basemap. A tile backdrop can sit behind this for personal
//  viewing -- the drawing here is the same either way.
//
//  The disc feathers out to nothing at its edge instead of ending on a hard
//  circle, so it sits on the footage rather than on top of it.
//

import CoreGraphics
import CoreLocation
import Foundation

enum MapMode: String, CaseIterable, Identifiable, Codable {
    /// The whole route, fixed, with the rider moving along it.
    case wholeRoute
    /// Centred on the rider at a constant zoom.
    case follow

    var id: String { rawValue }
    var label: String { self == .wholeRoute ? "Whole Route" : "Follow" }
}

struct MapStyle: Equatable, Codable {
    /// The disc behind the trace.
    var backing: RGBA
    /// The part of the route not yet reached.
    var route: RGBA
    var routeWidth: Double
    /// The part already ridden.
    var travelled: RGBA
    var travelledWidth: Double
    /// The rider.
    var marker: RGBA
    var markerRing: RGBA
    /// How much of the radius fades out. 0 is a hard edge, 1 fades throughout.
    var feather: Double
    /// A soft ring just inside the rim.
    ///
    /// A translucent dark disc is invisible against dark footage -- measured on
    /// this ride, the bottom-right corner sits at 2-4% brightness, so the
    /// backing changed it by ~1%. The route line still read, but the disc did
    /// not, and it looked like stray lines on the frame. A light ring gives the
    /// map an edge whatever is behind it, and the feather keeps that edge soft.
    var rim: RGBA
    var rimWidth: Double
    var shadow: Double

    static func matching(_ preset: GaugePreset) -> MapStyle {
        let gauge = GaugeStyle.preset(preset)
        switch preset {
        case .modern:
            return MapStyle(backing: RGBA(0.06, 0.07, 0.09, 0.45),
                            route: RGBA(1, 1, 1, 0.35), routeWidth: 2.2,
                            travelled: gauge.arc, travelledWidth: 3.4,
                            marker: gauge.needle, markerRing: RGBA(1, 1, 1, 0.9),
                            feather: 0.34, rim: RGBA(1, 1, 1, 0.30), rimWidth: 1.6,
                            shadow: 0.5)
        case .classic:
            return MapStyle(backing: RGBA(0.94, 0.91, 0.83, 0.55),
                            route: RGBA(0.30, 0.27, 0.22, 0.40), routeWidth: 2.2,
                            travelled: RGBA(0.78, 0.10, 0.09, 0.95), travelledWidth: 3.4,
                            marker: RGBA(0.78, 0.10, 0.09), markerRing: RGBA(0.98, 0.96, 0.90, 0.95),
                            feather: 0.30, rim: RGBA(0.99, 0.97, 0.92, 0.45), rimWidth: 2.2,
                            shadow: 0.35)
        case .hiTech:
            return MapStyle(backing: RGBA(0.02, 0.04, 0.06, 0.55),
                            route: RGBA(0.0, 0.85, 0.95, 0.28), routeWidth: 2.0,
                            travelled: RGBA(0.0, 0.95, 0.85, 1), travelledWidth: 3.6,
                            marker: RGBA(0.85, 1.0, 1.0), markerRing: RGBA(0.0, 0.85, 0.95, 0.9),
                            feather: 0.40, rim: RGBA(0.0, 0.90, 1.0, 0.42), rimWidth: 1.4,
                            shadow: 0.7)
        case .minimal:
            return MapStyle(backing: RGBA(0, 0, 0, 0),
                            route: RGBA(1, 1, 1, 0.28), routeWidth: 1.8,
                            travelled: RGBA(1, 1, 1, 0.95), travelledWidth: 3.0,
                            marker: RGBA(1, 1, 1), markerRing: RGBA(0, 0, 0, 0.35),
                            feather: 0.45, rim: RGBA(1, 1, 1, 0.22), rimWidth: 1.2,
                            shadow: 0.8)
        }
    }
}

struct MapConfig: Equatable, Codable {
    var mode: MapMode = .wholeRoute
    var preset: GaugePreset = .modern
    var style: MapStyle = .matching(.modern)
    var placement: OverlayPlacement = .corner(.bottomRight, scale: 0.24)
    /// Metres across the disc in `.follow` mode.
    var followSpan: Double = 400
    /// Rotate so the direction of travel points up.
    var headingUp: Bool = false

    mutating func apply(_ preset: GaugePreset) {
        self.preset = preset
        self.style = .matching(preset)
    }
}

enum MapRenderer {

    static func frame(in size: CGSize, config: MapConfig) -> CGRect {
        config.placement.rect(in: size)
    }

    /// Draws the route disc.
    ///
    /// `progress` is how far along `route` the rider is, as an index; it is a
    /// Double so the marker moves smoothly between fixes rather than hopping.
    static func draw(route: [CLLocationCoordinate2D], progress: Double,
                     in context: CGContext, frameSize: CGSize, config: MapConfig) {
        guard route.count > 1 else { return }
        let rect = frame(in: frameSize, config: config)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let style = config.style

        context.saveGState()
        defer { context.restoreGState() }

        if style.shadow > 0 {
            context.setShadow(offset: CGSize(width: 0, height: -radius * 0.03),
                              blur: radius * 0.10,
                              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: style.shadow))
        }

        // Everything inside the disc goes into a transparency layer, so the
        // feather can be applied to the result in one pass rather than to each
        // stroke. Without the layer, masking would knock out the footage too.
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        if style.backing.a > 0 {
            context.setFillColor(style.backing.cgColor)
            context.fillEllipse(in: rect)
        }
        context.setShadow(offset: .zero, blur: 0, color: nil)

        let index = min(max(progress, 0), Double(route.count - 1))
        let points = project(route, into: rect, config: config, at: index)

        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()

        if style.rim.a > 0, style.rimWidth > 0 {
            // Sit the ring where the fade begins, so it survives the feather
            // instead of being erased with the outermost pixels.
            let solid = max(0.2, 1 - min(style.feather, 1))
            let ringRadius = radius * (solid + (1 - solid) * 0.45)
            context.setStrokeColor(style.rim.cgColor)
            context.setLineWidth(style.rimWidth * radius / 100)
            context.strokeEllipse(in: CGRect(x: centre.x - ringRadius, y: centre.y - ringRadius,
                                             width: ringRadius * 2, height: ringRadius * 2))
        }

        stroke(points, from: 0, to: points.count - 1, colour: style.route,
               width: style.routeWidth * radius / 100, in: context)
        stroke(points, from: 0, to: Int(index), colour: style.travelled,
               width: style.travelledWidth * radius / 100, in: context)

        // The rider, interpolated between the two fixes either side.
        let here = interpolate(points, at: index)
        let dot = radius * 0.075
        context.setFillColor(style.markerRing.cgColor)
        context.fillEllipse(in: CGRect(x: here.x - dot * 1.45, y: here.y - dot * 1.45,
                                       width: dot * 2.9, height: dot * 2.9))
        context.setFillColor(style.marker.cgColor)
        context.fillEllipse(in: CGRect(x: here.x - dot, y: here.y - dot,
                                       width: dot * 2, height: dot * 2))
        context.restoreGState()

        // Fade the disc out at its rim: an opaque white centre going to clear,
        // composited with destinationIn so it eats alpha rather than paint.
        if style.feather > 0 {
            context.saveGState()
            context.setBlendMode(.destinationIn)
            let solid = max(0, 1 - min(style.feather, 1))
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            if let gradient = CGGradient(colorsSpace: space,
                                         colors: [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                                                  CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                                                  CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)] as CFArray,
                                         locations: [0, solid, 1]) {
                context.drawRadialGradient(gradient,
                                           startCenter: centre, startRadius: 0,
                                           endCenter: centre, endRadius: radius,
                                           options: [.drawsAfterEndLocation])
            }
            context.restoreGState()
        }

        context.endTransparencyLayer()
    }

    // MARK: - Projection

    /// Latitude and longitude onto the disc.
    ///
    /// Equirectangular with a cosine correction on longitude: over a route a
    /// few kilometres across the error is far below a pixel, and it keeps the
    /// shape of the ride honest without pulling in a projection library.
    private static func project(_ route: [CLLocationCoordinate2D], into rect: CGRect,
                                config: MapConfig, at index: Double) -> [CGPoint] {
        let centreLat: Double
        let centreLon: Double
        let span: Double     // metres across the disc

        let here = interpolateCoordinate(route, at: index)

        switch config.mode {
        case .follow:
            centreLat = here.latitude
            centreLon = here.longitude
            span = max(config.followSpan, 20)
        case .wholeRoute:
            var minLat = route[0].latitude, maxLat = route[0].latitude
            var minLon = route[0].longitude, maxLon = route[0].longitude
            for point in route {
                minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
                minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
            }
            centreLat = (minLat + maxLat) / 2
            centreLon = (minLon + maxLon) / 2
            let metresPerDegLat = 111_320.0
            let metresPerDegLon = metresPerDegLat * cos(centreLat * .pi / 180)
            let height = (maxLat - minLat) * metresPerDegLat
            let width = (maxLon - minLon) * metresPerDegLon
            // A margin so the trace does not run into the feathered rim.
            span = max(max(width, height) * 1.25, 50)
        }

        let metresPerDegLat = 111_320.0
        let metresPerDegLon = metresPerDegLat * cos(centreLat * .pi / 180)
        let scale = rect.width / span

        return route.map { point in
            let dx = (point.longitude - centreLon) * metresPerDegLon * scale
            let dy = (point.latitude - centreLat) * metresPerDegLat * scale
            return CGPoint(x: rect.midX + dx, y: rect.midY + dy)
        }
    }

    private static func interpolateCoordinate(_ route: [CLLocationCoordinate2D],
                                              at index: Double) -> CLLocationCoordinate2D {
        let clamped = min(max(index, 0), Double(route.count - 1))
        let low = Int(clamped)
        guard low + 1 < route.count else { return route[low] }
        let t = clamped - Double(low)
        let a = route[low], b = route[low + 1]
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    private static func interpolate(_ points: [CGPoint], at index: Double) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let clamped = min(max(index, 0), Double(points.count - 1))
        let low = Int(clamped)
        guard low + 1 < points.count else { return points[low] }
        let t = CGFloat(clamped - Double(low))
        let a = points[low], b = points[low + 1]
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func stroke(_ points: [CGPoint], from: Int, to: Int,
                               colour: RGBA, width: CGFloat, in context: CGContext) {
        guard colour.a > 0, width > 0, to > from, from >= 0, to < points.count else { return }
        context.setStrokeColor(colour.cgColor)
        context.setLineWidth(max(width, 0.5))
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.move(to: points[from])
        for i in (from + 1)...to { context.addLine(to: points[i]) }
        context.strokePath()
    }
}
