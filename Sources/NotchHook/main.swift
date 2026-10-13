import Foundation
import NotchCore

// notch-hook <claude|codex>: Claude Code or Codex runs this for every hook event, with the event JSON on stdin.
// It hands the event to Agents Notch. For a permission request it waits for a click in the notch and prints the
// decision; when the app is not running or nobody clicks, it prints nothing and the agent asks as usual.
// It always exits 0: a broken notch must never break an agent.
// notch-hook --uninstall-hooks: takes our entries out of the Claude Code and Codex hook files, like the app flag.
// `brew uninstall --zap` runs it from this copy, because by then the app bundle is already gone.

let args = CommandLine.arguments
if args.count == 2 && args[1] == "--uninstall-hooks" {
    // The home is where this copy lives, so the paths match the installed commands exactly; $HOME is the fallback.
    let suffix = "/Library/Application Support/AgentsNotch/notch-hook"
    // realpath, not URL.resolvingSymlinksInPath: that one drops /private and the paths stop matching.
    let me = Bundle.main.executablePath.flatMap { realpath($0, nil) }.map { p in defer { free(p) }; return String(cString: p) } ?? ""
    let home = me.hasSuffix(suffix) ? String(me.dropLast(suffix.count))
        : ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
    let inst = home.map { HookInstaller(home: URL(fileURLWithPath: $0)) } ?? HookInstaller()
    // One vendor failing must not leave the other's hooks behind: zap trashes this helper right after.
    var failed = false
    for v in [Vendor.claude, .codex] {
        do {
            try inst.uninstall(v)
            print("\(v.rawValue): \(inst.isInstalled(v) ? "installed" : "removed") in \(inst.file(v).path)")
        } catch {
            print("\(v.rawValue): \(error.localizedDescription)")
            failed = true
        }
    }
    exit(failed ? 1 : 0)
}
guard args.count > 1, let vendor = Vendor(rawValue: args[1]) else { exit(0) }
let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count < HookServer.maxLine - 4096,
      let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
      let event = payload["hook_event_name"] as? String else { exit(0) }
let parsed = HookEvent(vendor: vendor, payload: payload)
// PreToolUse holds the call only for the entry installed with --wait and only for a question or plan; the async one reports and leaves.
let holds = event == "PermissionRequest" || (args.contains("--wait") && parsed?.waitsForAnswer == true)
let wait = holds ? Double(HookInstaller.wait) : 0
if let decision = HookClient.send(vendor: vendor, payload: input, wait: wait),
   let out = HookReply.helperStdout(event: parsed, name: event, decision: decision) {
    FileHandle.standardOutput.write(Data((out + "\n").utf8))
}
exit(0)
