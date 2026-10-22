import Foundation
#if canImport(NotchCore)
import NotchCore
#endif

struct HouseSnapshotChecks {
    /// What the app writes is what the screen saver reads, until the file goes stale.
    func roundTrip() throws {
        let written = Date(timeIntervalSince1970: 1_800_000_000)
        let snap = HouseSnapshot(agents: #"[{"id":"a","state":"working","title":"Тест"}]"#, usage: #"{"claude":{"used":42},"warning":80}"#,
                                 config: #"{"layout":"steps","themes":{}}"#, fps: 60, written: written)
        let data = try XCTUnwrap(snap.encoded())
        let read = try XCTUnwrap(HouseSnapshot.decode(data, now: written.addingTimeInterval(HouseSnapshot.heartbeat)))
        XCTAssertEqual(read, snap)
        XCTAssertTrue(read.sameHouse(as: HouseSnapshot(agents: snap.agents, usage: snap.usage, config: snap.config, fps: 60, written: .distantPast)))
        // the app quit or hung: the saver shows an empty house
        XCTAssertNil(HouseSnapshot.decode(data, now: written.addingTimeInterval(HouseSnapshot.staleAfter + 1)))
        // the heartbeat keeps a running app fresh with room to spare
        XCTAssertTrue(HouseSnapshot.heartbeat * 3 <= HouseSnapshot.staleAfter)
    }

    func badInput() throws {
        let now = Date()
        XCTAssertNil(HouseSnapshot.decode(Data("not json".utf8), now: now))
        XCTAssertNil(HouseSnapshot.decode(Data(#"{"written":1}"#.utf8), now: now))
        let noUsage = HouseSnapshot(agents: "[]", usage: nil, config: "{}", fps: 500, written: now)
        let read = try XCTUnwrap(HouseSnapshot.decode(try XCTUnwrap(noUsage.encoded()), now: now))
        XCTAssertNil(read.usage)
        XCTAssertEqual(read.fps, 60)
        XCTAssertEqual(HouseSnapshot.url(home: URL(fileURLWithPath: "/Users/x")).path, "/Users/x/Library/Application Support/AgentsNotch/house.json")
    }
}
