import Foundation
import NotchCore

// notch-hook <claude|codex>: Claude Code or Codex runs this for every hook event, with the event JSON on stdin.
// It hands the event to Agents Notch. For a permission request it waits for a click in the notch and prints the
// decision; when the app is not running or nobody clicks, it prints nothing and the agent asks as usual.
// It always exits 0: a broken notch must never break an agent.
// notch-hook --uninstall-hooks: takes our entries out of the Claude Code and Codex hook files, like the app flag.
// `brew uninstall --zap` runs it from this copy, because by then the app bundle is already gone.

let args = CommandLine.arguments
if args.contains("--uninstall-hooks") {
    // $HOME first: the zap script finds this helper through it, and a test can point it at a scratch home.
    let inst = ProcessInfo.processInfo.environment["HOME"].map { HookInstaller(home: URL(fileURLWithPath: $0)) } ?? HookInstaller()
    do {
        for v in [Vendor.claude, .codex] {
            try inst.uninstall(v)
            print("\(v.rawValue): \(inst.isInstalled(v) ? "installed" : "removed") in \(inst.file(v).path)")
        }
        exit(0)
    } catch {
        print("hooks: \(error.localizedDescription)")
        exit(1)
    }
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
