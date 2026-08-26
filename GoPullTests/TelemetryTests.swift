//
//  TelemetryTests.swift
//  GoPullTests
//
//  GPMF is a binary format from a device, so these build payloads byte by byte
//  rather than leaning on a clip being present.
//

// CoreLocation explicitly: the project enables MEMBER_IMPORT_VISIBILITY, so
// CLLocationCoordinate2D.latitude is invisible without it even though the type
// itself resolves.
import CoreLocation
import Foundation
import Testing
@testable import GoPull

struct TelemetryTests {

    // MARK: - Building GPMF by hand

    /// One KLV item: key, type, struct size, repeat, payload padded to 4 bytes.
    private func item(_ key: String, _ type: Character, _ structSize: Int,
                      _ count: Int, _ body: [UInt8]) -> [UInt8] {
        var out = Array(key.utf8)
        out.append(type == "\0" ? 0 : UInt8(String(type).utf8.first!))
        out.append(UInt8(structSize))
        out.append(UInt8((count >> 8) & 0xFF))
        out.append(UInt8(count & 0xFF))
        out += body
        while out.count % 4 != 0 { out.append(0) }
        return out
    }

    private func be32(_ value: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: value)
        return [UInt8(u >> 24 & 0xFF), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
    }

    private func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

    // MARK: - The reader

    @Test func parsesKeyLengthValue() {
        let data = Data(item("DVNM", "c", 1, 5, Array("HERO\0".utf8)))
        let items = GPMF.parse(data)
        #expect(items.count == 1)
        #expect(items[0].key == "DVNM")
        #expect(items[0].string == "HERO")
    }

    @Test func nestedContainersExposeTheirChildren() {
        let inner = item("TSMP", "L", 4, 1, be32(42).map { $0 })
        let devc = item("DEVC", "\0", 1, inner.count, inner)
        let items = GPMF.parse(Data(devc))
        #expect(items.first?.key == "DEVC")
        #expect(items.first?.isContainer == true)
        #expect(items.first?.first("TSMP") != nil)
    }

    /// A payload claiming more bytes than it has must not read past the end.
    @Test func aTruncatedPayloadStopsCleanly() {
        var bytes = item("GPS9", "?", 32, 10, [])
        bytes.replaceSubrange(6...7, with: be16(9999))
        let items = GPMF.parse(Data(bytes))
        #expect(items.isEmpty)
    }

    // MARK: - GPS9

    /// One GPS9 stream: SCAL, then a sample of 7 int32s and 2 uint16s.
    private func gps9Payload(lat: Int32, lon: Int32, alt: Int32,
                             speed2D: Int32, dop: UInt16, fix: UInt16) -> GPMFPayload {
        let scal = item("SCAL", "l", 4, 9,
                        [10_000_000, 10_000_000, 1000, 1000, 1000, 1, 1000, 100, 1]
                            .flatMap { be32(Int32($0)) })
        var sample: [UInt8] = []
        sample += be32(lat); sample += be32(lon); sample += be32(alt)
        sample += be32(speed2D); sample += be32(0)
        sample += be32(9734); sample += be32(1_067_899)
        sample += be16(dop); sample += be16(fix)
        let gps9 = item("GPS9", "?", 32, 1, sample)
        let strm = item("STRM", "\0", 1, scal.count + gps9.count, scal + gps9)
        let devc = item("DEVC", "\0", 1, strm.count, strm)
        return GPMFPayload(time: 10, duration: 1, data: Data(devc))
    }

    @Test func decodesGPS9AgainstItsScales() throws {
        let payload = gps9Payload(lat: 323_737_900, lon: -1_110_783_700, alt: 735_592,
                                  speed2D: 14_600, dop: 493, fix: 3)
        let samples = TelemetryReader.samples(in: payload)
        let sample = try #require(samples.first)
        #expect(abs(sample.latitude - 32.37379) < 0.00001)
        #expect(abs(sample.longitude - (-111.07837)) < 0.00001)
        #expect(abs(sample.altitude - 735.592) < 0.001)
        #expect(abs(sample.speed2D - 14.6) < 0.001)
        #expect(abs(sample.mph - 32.659) < 0.01)
        #expect(sample.dop == 4.93)
        #expect(sample.fix == 3)
        #expect(sample.isUsable)
    }

    /// The camera emits samples while it is still searching; those carry fix 0
    /// and a huge DOP, and plotting them puts a false point on the map.
    @Test func samplesWithoutAFixAreNotUsable() throws {
        let searching = gps9Payload(lat: 323_737_900, lon: -1_110_783_700, alt: 735_592,
                                    speed2D: 0, dop: 9999, fix: 0)
        let sample = try #require(TelemetryReader.samples(in: searching).first)
        #expect(!sample.isUsable)

        var track = TelemetryTrack()
        track.samples = [sample]
        #expect(track.usable.isEmpty)
        #expect(!track.hasFix)
    }

    @Test func samplesAreTimedWithinTheirPayload() {
        let payload = gps9Payload(lat: 1, lon: 1, alt: 0, speed2D: 0, dop: 100, fix: 3)
        let sample = TelemetryReader.samples(in: payload).first
        #expect(sample?.time == 10)  // payload starts at 10s
    }

    // MARK: - Driving an overlay

    private func track(_ points: [(t: Double, speed: Double, alt: Double)]) -> TelemetryTrack {
        var track = TelemetryTrack()
        track.samples = points.map {
            GPSSample(latitude: 32.0 + $0.t / 10_000, longitude: -111.0,
                      altitude: $0.alt, speed2D: $0.speed, speed3D: $0.speed,
                      time: $0.t, timestamp: nil, dop: 2, fix: 3)
        }
        return track
    }

    @Test func readingsAreInterpolatedBetweenSamples() throws {
        let t = track([(0, 10, 100), (1, 20, 100)])
        let mid = try #require(t.sample(at: 0.5))
        #expect(abs(mid.speed2D - 15) < 0.0001)
        #expect(mid.time == 0.5)
    }

    /// Before the first fix the gauge must read nothing, not the first fix.
    @Test func thereIsNoReadingOutsideTheFixWindow() {
        let t = track([(10, 5, 100), (20, 6, 100)])
        #expect(t.sample(at: 0) == nil)
        #expect(t.sample(at: 25) == nil)
        #expect(t.sample(at: 15) != nil)
        #expect(t.fixWindow == 10...20)
    }

    /// Summing 10 Hz steps measures noise; a real ride reported 1 m of climb.
    @Test func ascentIsMeasuredPerSecondNotPerSample() {
        var jittery: [(Double, Double, Double)] = []
        for i in 0..<100 {
            let t = Double(i) / 10
            jittery.append((t, 5, 100 + (i % 2 == 0 ? 0.2 : -0.2)))   // noise only
        }
        #expect(track(jittery).ascent == 0)

        var climbing: [(Double, Double, Double)] = []
        for i in 0..<100 {
            let t = Double(i) / 10
            climbing.append((t, 5, 100 + t * 2))                       // 2 m/s up
        }
        #expect(climbing.count == 100)
        #expect(track(climbing).ascent > 15)
    }

    @Test func boundsFrameTheWholeTrack() throws {
        let t = track([(0, 5, 100), (10, 5, 100), (20, 5, 100)])
        let bounds = try #require(t.bounds)
        #expect(bounds.southWest.latitude < bounds.northEast.latitude)
        #expect(t.route.count == 3)
    }

    @Test func anEmptyTrackAnswersSafely() {
        let empty = TelemetryTrack()
        #expect(empty.sample(at: 5) == nil)
        #expect(empty.bounds == nil)
        #expect(empty.fixWindow == nil)
        #expect(empty.distance == 0)
        #expect(empty.ascent == 0)
        #expect(empty.topSpeed == 0)
    }
}
