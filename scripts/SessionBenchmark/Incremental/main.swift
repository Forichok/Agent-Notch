import Darwin
import Foundation

// Read-only with respect to home. The optional loop writes only the explicit scratch file.
let home = URL(fileURLWithPath: CommandLine.arguments[1])
let mode = CommandLine.arguments[2]
let target = URL(fileURLWithPath: CommandLine.arguments[3])
let count = Int(CommandLine.arguments[4])!
let scanner = LogScanner(home: home, execRuns: { [] }, rolloutParents: { [:] })
var opens = 0, stats = 0, lists = 0, bytes = 0
scanner.didOpen = { _ in opens += 1 }
scanner.didStat = { _ in stats += 1 }
scanner.didList = { _ in lists += 1 }
scanner.didRead = { bytes += $0 }
let initial = scanner.poll(changes: .full)!
opens = 0; stats = 0; lists = 0; bytes = 0
func cpu() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}
let externalWriter = mode.hasPrefix("external-")
if externalWriter { print("READY"); fflush(stdout) }
let startCPU = cpu(), start = Date()
var last = initial
var observedAppends = 0
var expectedPromptAt: Double?
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
for i in 0..<count {
    if externalWriter {
        guard let command = readLine(), let at = LogText.time(command) else { fatalError("missing append timestamp") }
        expectedPromptAt = at
    } else if mode.hasPrefix("loop") {
        precondition(target.path.hasPrefix(home.path + "/") && home.path.contains("/scan-work/"))
        let handle = try FileHandle(forWritingTo: target)
        try handle.seekToEnd()
        let stamp = formatter.string(from: Date())
        expectedPromptAt = LogText.time(stamp)
        let line = target.path.contains("/.codex/") ?
            "{\"type\":\"event_msg\",\"timestamp\":\"\(stamp)\",\"payload\":{\"type\":\"user_message\",\"message\":\"append-\(i)\"}}\n" :
            "{\"type\":\"user\",\"timestamp\":\"\(stamp)\",\"message\":{\"content\":\"append-\(i)\"}}\n"
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
    }
    // Replay exact file and containing-directory notifications separately.
    let vendor = target.path.contains("/.codex/") ? Vendor.codex : .claude
    let logRoot = ConfigRoots(home: home).logs(vendor).path
    let directory = mode == "root" || mode.hasSuffix("loop-root") ? logRoot : target.deletingLastPathComponent().path
    let paths: Set<String> = mode == "exact" ? [target.path] : [target.path, directory]
    last = scanner.poll(changes: .paths(paths))!
    if mode.contains("loop"), let expectedPromptAt,
       last.first(where: { $0.logPath == target.path })?.promptAt == expectedPromptAt { observedAppends += 1 }
    if externalWriter { print("ACK"); fflush(stdout) }
    else if mode.hasPrefix("loop") { Thread.sleep(forTimeInterval: 0.05) }
}
let elapsed = Date().timeIntervalSince(start), used = cpu() - startCPU
let result: [String: Any] = ["mode": mode, "events": count, "wall_ms_per_event": elapsed * 1000 / Double(count),
    "cpu_ms_per_event": used * 1000 / Double(count), "cpu_percent_one_core": used / elapsed * 100,
    "opens_per_event": Double(opens) / Double(count), "stats_per_event": Double(stats) / Double(count),
    "listings_per_event": Double(lists) / Double(count), "bytes_per_event": Double(bytes) / Double(count),
    "initial_agents": initial.count, "final_agents": last.count, "observed_appends": observedAppends,
    "target_title": last.first { $0.logPath == target.path }?.title ?? ""]
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
