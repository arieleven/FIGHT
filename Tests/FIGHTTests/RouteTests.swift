import XCTest

final class RouteTests: XCTestCase {
    /// Points heading north at `speed` m/s, one per second (1° latitude ≈ 111.2 km).
    private func line(seconds: Int, speed: Double = 3, start: Double = 0) -> [RoutePoint] {
        (0...seconds).map { i in
            RoutePoint(lat: 51.5 + Double(i) * speed / 111_195, lon: -0.12, alt: 20, t: start + Double(i), speed: speed)
        }
    }

    func testDistanceAndPaceText() {
        let pts = line(seconds: 100)
        XCTAssertEqual(RouteMath.totalDistance(pts), 300, accuracy: 1)
        XCTAssertEqual(RouteMath.paceText(328), "5:28")
        XCTAssertEqual(RouteMath.paceText(0), "--:--")
        XCTAssertEqual(RouteMath.distanceText(5020, imperial: false), "5.02")
    }

    func testFilterDropsBadFixesAndJumps() {
        var f = GPSFilter()
        let a = RoutePoint(lat: 51.5, lon: -0.12, t: 10)
        XCTAssertTrue(f.accept(a, accuracy: 5))
        XCTAssertFalse(f.accept(RoutePoint(lat: 51.5001, lon: -0.12, t: 11), accuracy: 60), "poor accuracy")
        XCTAssertFalse(f.accept(RoutePoint(lat: 51.501, lon: -0.12, t: 12), accuracy: 5), "111 m in 2 s is a GPS jump")
        XCTAssertTrue(f.accept(RoutePoint(lat: 51.50003, lon: -0.12, t: 13), accuracy: 5))
    }

    func testAutoPauseAfterSixSecondsStopped() {
        var p = AutoPause()
        for t in 0..<5 { XCTAssertFalse(p.feed(speed: 0.1, t: Double(t))) }
        XCTAssertTrue(p.feed(speed: 0.1, t: 6))
        XCTAssertTrue(p.isPaused)
        XCTAssertFalse(p.feed(speed: 0.8, t: 7), "walking pace jitter doesn't resume")
        XCTAssertTrue(p.feed(speed: 2.5, t: 8))
        XCTAssertFalse(p.isPaused)
    }

    func testSplitsEveryKilometreWithPartialEnd() {
        var s = SplitTracker(unit: 1000)
        var done: [RunSplit] = []
        for i in 1...2500 {
            s.addHeartRate(150)
            if let split = s.update(distance: Double(i), moving: Double(i) * 0.33, altitude: 20) { done.append(split) }
        }
        XCTAssertEqual(done.count, 2)
        XCTAssertEqual(done[0].seconds, 330, accuracy: 1)
        XCTAssertEqual(done[0].avgBPM, 150)
        let all = s.finish(distance: 2500, moving: 825, altitude: 20)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[2].meters, 500, accuracy: 0.1)
        XCTAssertEqual(all[2].pace(unit: 1000), 330, accuracy: 1, "partial split pace is scaled to a full km")
    }

    func testSimplifyKeepsShapeWithFewerPoints() {
        // An L-shaped route: north, then east.
        var pts = line(seconds: 200, speed: 3)
        let corner = pts.last!
        for i in 1...200 {
            pts.append(RoutePoint(lat: corner.lat, lon: corner.lon + Double(i) * 3 / (111_195 * cos(corner.lat * .pi / 180)), t: 200 + Double(i)))
        }
        let simple = RouteMath.simplify(pts)
        XCTAssertLessThan(simple.count, pts.count / 3)
        XCTAssertEqual(RouteMath.totalDistance(simple), RouteMath.totalDistance(pts), accuracy: 5)
        XCTAssertTrue(simple.contains { abs($0.lat - corner.lat) < 1e-7 && abs($0.lon - corner.lon) < 1e-7 }, "keeps the corner")
    }

    func testElevationIgnoresNoise() {
        var e = ElevationGain()
        for a in [10.0, 11, 9, 12, 10, 11, 15, 14, 19, 18, 22] { e.feed(a) }
        XCTAssertEqual(e.total, 12, accuracy: 0.01, "10 → 22 climbed, wobbles under 3 m ignored")
    }

    func testNormalizedFitsInUnitBox() {
        let n = RouteMath.normalized(line(seconds: 50))
        XCTAssertTrue(n.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        XCTAssertEqual(n.first?.y ?? 0, 1, accuracy: 0.001, "start at the bottom when running north")
        XCTAssertEqual(n.last?.y ?? 1, 0, accuracy: 0.001)
    }

    func testDecouplingFlagsHeartRateDrift() {
        let steady = (1...6).map { RunSplit(index: $0, meters: 1000, seconds: 330, avgBPM: 145, elevation: 0) }
        XCTAssertEqual(RouteMath.decoupling(steady) ?? 99, 0, accuracy: 0.01)
        let drift = (1...6).map { RunSplit(index: $0, meters: 1000, seconds: 330, avgBPM: $0 <= 3 ? 140 : 155, elevation: 0) }
        XCTAssertGreaterThan(RouteMath.decoupling(drift) ?? 0, 5)
    }

    func testBluetoothRunSensorParsing() {
        // RSC: total distance present, 3.0 m/s, cadence 172, 1234.5 m.
        let rsc: [UInt8] = [0x02, 0x00, 0x03, 172, 0x39, 0x30, 0x00, 0x00]
        let r = RunSensorParser.runningSpeed(rsc)
        XCTAssertEqual(r?.speed ?? 0, 3.0, accuracy: 0.001)
        XCTAssertEqual(r?.cadence, 172)
        XCTAssertEqual(r?.totalDistance ?? 0, 1234.5, accuracy: 0.01)

        // LNS: speed + location present. 2.5 m/s, 51.5°, -0.12°.
        var lns: [UInt8] = [0x05, 0x00, 0xFA, 0x00]
        func le32(_ v: Int32) -> [UInt8] { let u = UInt32(bitPattern: v); return [UInt8(u & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u >> 16 & 0xFF), UInt8(u >> 24)] }
        lns += le32(515_000_000) + le32(-1_200_000)
        let l = RunSensorParser.locationAndSpeed(lns)
        XCTAssertEqual(l?.speed ?? 0, 2.5, accuracy: 0.001)
        XCTAssertEqual(l?.lat ?? 0, 51.5, accuracy: 1e-7)
        XCTAssertEqual(l?.lon ?? 0, -0.12, accuracy: 1e-7)
        XCTAssertNil(l?.totalDistance)
    }

    func testRouteFileFormatRoundTrips() throws {
        let p = RoutePoint(lat: 51.5012345, lon: -0.1234567, alt: 21.37, t: 12.34, speed: 3.456)
        let back = try JSONDecoder().decode(RoutePoint.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.lat, p.lat, accuracy: 1e-7)
        XCTAssertEqual(back.lon, p.lon, accuracy: 1e-7)
        XCTAssertEqual(back.alt ?? 0, 21.4, accuracy: 0.01)
        XCTAssertEqual(back.speed ?? 0, 3.46, accuracy: 0.001)
    }
}
