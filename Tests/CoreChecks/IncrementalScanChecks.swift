import Foundation

struct IncrementalScanChecks {
    func eventsAndReconciliation() throws {
        let fm = FileManager.default
        let home = ConfigRoots.physical(fm.temporaryDirectory.appendingPathComponent("scan-perf-\(UUID().uuidString)"))
        defer { try? fm.removeItem(at: home) }
        let dir = home.appendingPathComponent(".claude/projects/p")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        func row(_ text: String) -> Data {
            Data("{\"type\":\"user\",\"timestamp\":\"\(stamp)\",\"message\":{\"content\":\"\(text)\"}}\n{\"type\":\"last-prompt\",\"lastPrompt\":\"\(text)\"}\n".utf8)
        }
        let a = dir.appendingPathComponent("a.jsonl"), b = dir.appendingPathComponent("b.jsonl")
        try row("first").write(to: a)
        try row("second").write(to: b)
        for i in 0..<50 {
            let old = dir.appendingPathComponent("old-\(i).jsonl")
            try row("archive").write(to: old)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-100_000)], ofItemAtPath: old.path)
        }
        let scanner = LogScanner(home: home, execRuns: { [] }, rolloutParents: { [:] })
        XCTAssertEqual(scanner.poll(now: now, changes: .full)!.count, 2)
        var lists = 0, bytes = 0, opens = 0, stats: [String] = []
        scanner.didOpen = { _ in opens += 1 }
        scanner.didList = { _ in lists += 1 }
        scanner.didRead = { bytes += $0 }
        scanner.didStat = { stats.append($0) }
        let h = try FileHandle(forWritingTo: a)
        try h.seekToEnd(); try h.write(contentsOf: row("appended")); try h.close()
        let result = scanner.poll(now: now.addingTimeInterval(1), changes: .paths([a.path, home.appendingPathComponent(".claude").path]))!
        XCTAssertEqual(result.first { $0.id == "a" }?.title, "appended")
        XCTAssertEqual(bytes, row("appended").count, "tail only")
        XCTAssertEqual(opens, 1, "only the appended log is opened")
        XCTAssertEqual(lists, 0, "a shallow config event must not rewalk unchanged log directories")
        XCTAssertEqual(stats.contains(b.path), false, "unrelated logs must not be statted")
        let added = dir.appendingPathComponent("added.jsonl")
        try row("new").write(to: added)
        XCTAssertEqual(scanner.poll(now: now.addingTimeInterval(2), changes: .paths([added.path]))!.count, 3)
        let renamed = dir.appendingPathComponent("renamed.jsonl")
        try fm.moveItem(at: added, to: renamed)
        let moved = scanner.poll(now: now.addingTimeInterval(3), changes: .paths([added.path, renamed.path]))!
        XCTAssertEqual(Set(moved.map(\.id)), ["a", "b", "renamed"])
        try fm.removeItem(at: b)
        XCTAssertFalse(scanner.poll(now: now.addingTimeInterval(4), changes: .paths([b.path]))!.contains { $0.id == "b" })
        bytes = 0; opens = 0
        _ = scanner.poll(now: now.addingTimeInterval(5), changes: .full)
        XCTAssertEqual(bytes, 0, "reconciliation must not reread unchanged or archived content")
        XCTAssertEqual(opens, 0, "metadata reconciliation must not open unchanged content")
        // Miss all events: append in place, create a file, and delete another.
        let missed = dir.appendingPathComponent("missed.jsonl")
        try row("missed new").write(to: missed)
        let append = try FileHandle(forWritingTo: a)
        try append.seekToEnd(); try append.write(contentsOf: row("healed")); try append.close()
        try fm.removeItem(at: renamed)
        let healed = scanner.poll(now: now.addingTimeInterval(200), changes: .processes)!
        XCTAssertEqual(Set(healed.map(\.id)), ["a", "missed"])
        XCTAssertEqual(healed.first { $0.id == "a" }?.title, "healed")
        XCTAssertEqual(bytes, row("healed").count + row("missed new").count)
    }
}

extension IncrementalScanChecks {
    func reconciliationRemapsRootsAndDrainsExec() throws {
        let fm = FileManager.default
        let home = ConfigRoots.physical(fm.temporaryDirectory.appendingPathComponent("scan-heal-\(UUID().uuidString)"))
        defer { try? fm.removeItem(at: home) }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        for name in ["old", "new"] {
            let dir = home.appendingPathComponent(name + "/projects/p")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{\"type\":\"user\",\"timestamp\":\"\(stamp)\",\"message\":{\"content\":\"\(name)\"}}\n".utf8).write(to: dir.appendingPathComponent(name + ".jsonl"))
        }
        let link = home.appendingPathComponent(".claude")
        try fm.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("old"))
        let stdout = home.appendingPathComponent("stdout.jsonl")
        try Data("{\"type\":\"thread.started\",\"thread_id\":\"exec-heal\"}\n{\"type\":\"turn.started\"}\n".utf8).write(to: stdout)
        var runs = [ExecRun(pid: getpid(), log: stdout.path, cwd: nil, model: nil, effort: nil)]
        let scanner = LogScanner(home: home, execRuns: { runs }, rolloutParents: { [:] })
        XCTAssertEqual(Set(scanner.poll(now: now, changes: .full)!.map(\.id)), ["old", "exec-heal"])
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("new"))
        let h = try FileHandle(forWritingTo: stdout)
        try h.seekToEnd(); try h.write(contentsOf: Data("{\"type\":\"turn.completed\"}\n".utf8)); try h.close()
        runs = []
        let healed = scanner.poll(now: now.addingTimeInterval(181), changes: .processes)!
        XCTAssertEqual(Set(healed.map(\.id)), ["new", "exec-heal"])
        XCTAssertEqual(healed.first { $0.id == "exec-heal" }?.state, .done)
        XCTAssertEqual(healed.first { $0.id == "exec-heal" }?.turnEnded, true)
        XCTAssertTrue(scanner.watchPaths.contains(home.appendingPathComponent("new/projects").path))
    }
}

extension IncrementalScanChecks {
    func aliasesAndLegacyStatus() throws {
        let fm = FileManager.default
        let home = ConfigRoots.physical(fm.temporaryDirectory.appendingPathComponent("scan-alias-\(UUID().uuidString)"))
        defer { try? fm.removeItem(at: home) }
        let dir = home.appendingPathComponent(".claude/projects/p")
        let status = home.appendingPathComponent(".claude/sessions/live.json")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: status.deletingLastPathComponent(), withIntermediateDirectories: true)
        let real = home.appendingPathComponent("external.jsonl")
        let alias = dir.appendingPathComponent("alias.jsonl")
        let now = Date(), stamp = ISO8601DateFormatter().string(from: Date())
        func row(_ text: String) -> Data { Data("{\"type\":\"user\",\"timestamp\":\"\(stamp)\",\"message\":{\"content\":\"\(text)\"}}\n{\"type\":\"last-prompt\",\"lastPrompt\":\"\(text)\"}\n".utf8) }
        try row("initial").write(to: real)
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        let secondAlias = dir.appendingPathComponent("second-alias.jsonl")
        try fm.createSymbolicLink(at: secondAlias, withDestinationURL: real)
        try Data("{\"sessionId\":\"alias\",\"status\":\"waiting\",\"pid\":\(getpid())}".utf8).write(to: status)
        let scanner = LogScanner(home: home, execRuns: { [] }, rolloutParents: { [:] })
        XCTAssertEqual(scanner.poll(now: now)!.first { $0.id == "alias" }?.state, .waiting)
        let h = try FileHandle(forWritingTo: real)
        try h.seekToEnd(); try h.write(contentsOf: row("aliased append")); try h.close()
        XCTAssertEqual(scanner.poll(now: now.addingTimeInterval(1), changes: .paths([real.path]))!.first { $0.id == "alias" }?.title, "aliased append")
        try fm.removeItem(at: status)
        XCTAssertEqual(scanner.poll(now: now.addingTimeInterval(2))!.first { $0.id == "alias" }?.state, .working)
        try fm.removeItem(at: alias)
        _ = scanner.poll(now: now.addingTimeInterval(3), changes: .paths([alias.path]))
        let more = try FileHandle(forWritingTo: real)
        try more.seekToEnd(); try more.write(contentsOf: row("remaining alias")); try more.close()
        let remaining = scanner.poll(now: now.addingTimeInterval(4), changes: .paths([real.path]))!
        XCTAssertEqual(remaining.map(\.id), ["second-alias"])
        XCTAssertEqual(remaining.first?.title, "remaining alias")
    }
}

extension IncrementalScanChecks {
    func discoveryStaysWithinSessionLayout() throws {
        let fm = FileManager.default
        let home = ConfigRoots.physical(fm.temporaryDirectory.appendingPathComponent("scan-layout-\(UUID().uuidString)"))
        defer { try? fm.removeItem(at: home) }
        let dir = home.appendingPathComponent(".claude/projects/p")
        let unrelated = dir.appendingPathComponent("cache/nested")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: unrelated.appendingPathComponent("cycle"), withDestinationURL: dir)
        let scanner = LogScanner(home: home, execRuns: { [] }, rolloutParents: { [:] })
        var listed: [String] = []
        scanner.didList = { listed.append($0) }
        XCTAssertEqual(scanner.poll(changes: .full)!.count, 0)
        XCTAssertFalse(listed.contains(unrelated.path))
        XCTAssertTrue(listed.count < 10, "unexpected directories and symlink cycles must not expand a session scan")
    }
}
