import Foundation

/// Finds recently written Claude Code and Codex session logs under a home folder and tails them.
/// Read-only. Overlapping polls share one pending scan; only its owner returns a snapshot.
public final class LogScanner: @unchecked Sendable {
    private struct Tracked {
        var log: SessionLog
        let initial: SessionLog
        var offset: UInt64
        var isSubagent: Bool
        /// A `codex exec --json` event stream rather than a session file.
        var isExec = false
        var device: dev_t?
        var inode: ino_t?
        var modified: Double = 0
        var observed: FileStamp?
        let physicalPath: String

        init(log: SessionLog, offset: UInt64, isSubagent: Bool, isExec: Bool = false, initial: SessionLog? = nil) {
            self.log = log
            physicalPath = log.path.map { ConfigRoots.physical(URL(fileURLWithPath: $0)).path } ?? ""
            self.initial = initial ?? log
            self.offset = offset
            self.isSubagent = isSubagent
            self.isExec = isExec
        }
    }

    // Observers report actual I/O without replacing filesystem operations.
    var didOpen: ((String) -> Void)?
    var didRead: ((Int) -> Void)?
    var didStat: ((String) -> Void)?
    var didList: ((String) -> Void)?

    private var claudeRoot: URL
    private var claudeSessions: URL
    private var codexRoot: URL
    private let config: ConfigRoots
    private let rootEntries: [URL]
    private var rootEntryStamps: [String: FileStamp] = [:]
    private let names = ProjectNames()
    private let fm = FileManager.default
    private var files: [String: Tracked] = [:]
    private let scanLock = NSLock()
    private var scanning = false
    private var pending: (Date, Double, FileChanges?)?
    private var liveFiles: [String: (String, ClaudeLive)] = [:]
    private var runs: [ExecRun] = []
    private var lastDiscovery: Double = 0
    private var lastReconciliation: Double?
    public static let reconciliationInterval: Double = 180
    private var physicalFiles: [String: Set<String>] = [:]
    private var metadata: [String: FileStamp] = [:]
    private var liveMetadata: [String: FileStamp] = [:]
    private struct FileStamp: Equatable {
        let size: Int64
        let modified: timespec
        let changed: timespec
        let inode: ino_t
        let device: dev_t
        let directory: Bool
        static func == (a: Self, b: Self) -> Bool {
            a.size == b.size && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec &&
            a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec &&
            a.inode == b.inode && a.device == b.device && a.directory == b.directory
        }
        var mtime: Double { Double(modified.tv_sec) + Double(modified.tv_nsec) / 1e9 }
    }
    private var listings: [String: (FileStamp, [URL])] = [:]
    public private(set) var nextRetentionExpiry: Date?
    private var lastRetention: Double?
    private let execRuns: () -> [ExecRun]
    private let rolloutParents: () -> [String: [String]]
    /// Keep ancestry after the process exits and across log resets.
    private var threadParents: [String: [String]] = [:]
    /// Exec logs whose process was running at the last discovery.
    private var execAlive: Set<String> = []

    /// A file not written for this long is neither picked up nor kept.
    public static let window: Double = SessionLog.keepDone
    /// First read of a long log starts this far from its end.
    static let tailBytes: UInt64 = 2 << 20

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, execRuns: @escaping () -> [ExecRun] = ExecRun.running,
                rolloutParents: (() -> [String: [String]])? = nil) {
        self.execRuns = execRuns
        config = ConfigRoots(home: home)
        rootEntries = [config.root(.claude), config.root(.codex), config.logs(.claude), config.logs(.codex),
                       config.root(.claude).appendingPathComponent("sessions")]
        claudeRoot = ConfigRoots.physical(ConfigRoots(home: home).logs(.claude))
        claudeSessions = ConfigRoots.physical(ConfigRoots(home: home).root(.claude).appendingPathComponent("sessions"))
        codexRoot = ConfigRoots.physical(ConfigRoots(home: home).logs(.codex))
        let root = ConfigRoots(home: home).logs(.codex)
        self.rolloutParents = rolloutParents ?? { Proc.rolloutParents(in: ConfigRoots.physical(root)) }
    }

    /// Roots include configured locations even when they do not exist yet.
    public var watchRootPaths: [String] { [config.root(.claude).path, config.root(.codex).path] }

    public var watchPaths: [String] {
        // Keep logical config entries as well as independently symlinked log/status directories.
        ([config.root(.claude).path, config.root(.codex).path,
          claudeRoot.path, claudeSessions.path, codexRoot.path] +
            Set(runs.map(\.log)).sorted()).sorted()
    }

    public func poll(now: Date = Date(), finishedRetention: Double = SessionLog.keepDone,
                     changes: FileChanges? = nil) -> [Agent]? {
        scanLock.lock()
        if scanning {
            let merged: FileChanges?
            if let old = pending { merged = (old.2 ?? .full).merging(changes ?? .full) }
            else { merged = changes }
            pending = (now, finishedRetention, merged)
            scanLock.unlock()
            return nil
        }
        scanning = true
        scanLock.unlock()
        var request = (now, finishedRetention, changes)
        while true {
            let result = scan(now: request.0, finishedRetention: request.1, changes: request.2)
            scanLock.lock()
            if let next = pending {
                pending = nil
                scanLock.unlock()
                request = next
            } else {
                scanning = false
                scanLock.unlock()
                return result
            }
        }
    }

    private func scan(now: Date, finishedRetention: Double, changes: FileChanges?) -> [Agent] {
        let t = now.timeIntervalSince1970
        let window = max(finishedRetention, SessionLog.longTool, 3_600)
        let changed = changes?.changedPaths.map { paths in
            Set(paths.map { path in
                // FSEvents already supplies canonical paths. Resolve only unfamiliar aliases.
                if files[path] != nil || metadata[path] != nil || listings[path] != nil || physicalFiles[path] != nil { return path }
                return ConfigRoots.physical(URL(fileURLWithPath: path)).path
            })
        }
        var full = changes == .full
        let due = lastReconciliation == nil ||
            t - (lastReconciliation ?? t) >= (changes == nil ? 55 : Self.reconciliationInterval) ||
            lastRetention != finishedRetention
        if full || due || changed?.isEmpty == false {
            let entriesChanged = configurationChanged()
            if full || due || entriesChanged {
                let claude = ConfigRoots.physical(config.logs(.claude))
                let codex = ConfigRoots.physical(config.logs(.codex))
                let sessions = ConfigRoots.physical(config.root(.claude).appendingPathComponent("sessions"))
                if claude.path != claudeRoot.path || codex.path != codexRoot.path || sessions.path != claudeSessions.path {
                    claudeRoot = claude
                    codexRoot = codex
                    claudeSessions = sessions
                    for path in files.keys.filter({ files[$0]?.isExec != true }) { untrack(path) }
                    listings.removeAll()
                    metadata.removeAll()
                    liveMetadata.removeAll()
                    full = true
                }
            }
        }
        let reconcile = full || due
        var dirty: Set<String> = []
        if reconcile {
            lastReconciliation = t
            lastDiscovery = t
            lastRetention = finishedRetention
            let previous = Set(runs.map(\.log))
            discoverProcesses()
            dirty.formUnion(previous.union(runs.map(\.log)))
            dirty.formUnion(discoverIndexed(paths: [claudeRoot.path, codexRoot.path], now: t, window: window, reconcile: true))
            refreshLiveDirectory(reconcile: true)
        } else if changes == nil && t - lastDiscovery >= 5 {
            lastDiscovery = t
            discoverProcesses()
            dirty.formUnion(discoverIndexed(paths: [claudeRoot.path, codexRoot.path], now: t, window: window, reconcile: false, sweep: true))
        }
        if let changed, !full {
            dirty.formUnion(discoverIndexed(paths: changed, now: t, window: window, reconcile: false))
            for path in changed {
                if contains(path, claudeSessions.path) { refreshLiveDirectory(reconcile: false) }
                else if contains(claudeSessions.path, path) {
                    let url = URL(fileURLWithPath: path)
                    if url.pathExtension == "json" { refreshLive(url) }
                    else { refreshLiveDirectory(reconcile: false) }
                }
            }
        }
        if changes?.refreshProcesses == true, !reconcile {
            let previous = Set(runs.map(\.log))
            discoverProcesses()
            dirty.formUnion(previous.union(runs.map(\.log)))
        }
        // Legacy callers have no event source, so check retained files on each poll.
        if changes == nil {
            dirty.formUnion(files.keys)
            if !reconcile { refreshLiveDirectory(reconcile: true) }
        }
        for path in dirty { read(path, now: t) }
        // No directory listing or JSON parsing on liveness-only ticks.
        for path in Array(liveFiles.keys) {
            if let pid = liveFiles[path]?.1.pid { liveFiles[path]?.1.alive = pid > 0 && ClaudeLive.isRunning(pid) }
        }
        let live = Dictionary(liveFiles.values.map { ($0.0, $0.1) }, uniquingKeysWith: { a, b in a.alive ? a : b })
        execAlive = Set(runs.filter { ClaudeLive.isRunning($0.pid) }.map(\.log))
        for path in Array(files.keys) {
            if files[path]?.inode == nil { read(path, now: t) }
            if let f = files[path], f.log.vendor == .codex, !f.isExec {
                files[path]?.log.parentCandidates = threadParents[f.log.id] ?? []
            }
            if let f = files[path], f.log.vendor == .claude {
                let l = live[f.log.parentId ?? f.log.id]
                files[path]?.log.live = l
                if f.log.parentId == nil, let pid = l?.pid, pid > 0, l?.alive == true { files[path]?.log.parentCandidates = parents(of: pid) }
            }
            if let f = files[path], f.isExec {
                // Legacy callers inject process snapshots; event callers check the cached pids.
                let alive = changes == nil ? runs.contains { $0.log == path } : execAlive.contains(path)
                files[path]?.log.live = ClaudeLive(status: f.log.turnEnded ? "idle" : "busy", waitingFor: nil, name: nil, alive: alive)
            }
        }
        readCodexParents(now: t)
        let threads = Set(files.values.filter { $0.log.vendor == .codex }.map { $0.log.id })
        threadParents = threadParents.filter { threads.contains($0.key) }
        // A retained exec thread has both a rollout and a stdout stream. Keep the rollout for
        // prompts, approvals and resuming; the stream still supplies its process ancestry.
        let logs = Dictionary(grouping: files.values, by: { "\($0.log.vendor.rawValue):\($0.log.id)" }).values.map { sources in
            let ordered = sources.sorted { a, b in
                if a.isExec != b.isExec { return !a.isExec }
                if a.log.live?.alive != b.log.live?.alive { return a.log.live?.alive == true }
                if a.log.lastAt != b.log.lastAt { return a.log.lastAt > b.log.lastAt }
                return (a.log.path ?? "") < (b.log.path ?? "")
            }
            var log = ordered[0].log
            if !ordered[0].isExec, let exec = ordered.first(where: { $0.isExec }) {
                let busy = exec.log.live?.alive == true && !exec.log.turnEnded
                let laterTurn = log.turnStartedAt.map { $0 > exec.modified } ?? false
                if busy || !laterTurn {
                    log.live = exec.log.live
                    log.turnEnded = exec.log.turnEnded
                    log.interrupted = exec.log.interrupted
                    log.lastAt = max(log.lastAt, exec.log.lastAt)
                    if log.ask != nil, busy { log.live?.status = "waiting" }
                }
            }
            for source in ordered {
                log.model = log.model ?? source.log.model
                log.effort = log.effort ?? source.log.effort
                for parent in source.log.parentCandidates where !log.parentCandidates.contains(parent) {
                    log.parentCandidates.append(parent)
                }
            }
            return log
        }
        var agents = logs.compactMap { $0.agent(now: t, finishedRetention: finishedRetention, project: names.name(for:)) }
        // Retention cannot remove an ancestor while one of its descendants still works.
        let byId = Dictionary(logs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var known = Set(agents.map(\.id))
        var pending = agents.flatMap { a in [a.parentId].compactMap { $0 } + (byId[a.id]?.parentCandidates ?? []) }
        while let id = pending.popLast() {
            guard known.insert(id).inserted, let log = byId[id],
                  let parent = log.agent(now: t, finishedRetention: .infinity, project: names.name(for:)) else { continue }
            agents.append(parent)
            pending += [parent.parentId].compactMap { $0 } + log.parentCandidates
        }
        let candidates = Dictionary(logs.filter { !$0.parentCandidates.isEmpty }.map { ($0.id, $0.parentCandidates) },
                                    uniquingKeysWith: { a, _ in a })
        let picked = Lineage.resolve(candidates, known: Set(agents.map(\.id)))
        for i in agents.indices where agents[i].parentId == nil { agents[i].parentId = picked[agents[i].id] }
        agents = Tree.withHelpers(agents).filter { $0.state.isLive || t - $0.retainedAt < finishedRetention }
        nextRetentionExpiry = agents.filter { !$0.state.isLive }
            .map { Date(timeIntervalSince1970: $0.retainedAt + finishedRetention) }.min()
        let retained = Set(agents.map(\.id))
        let expired = files.compactMap { path, f in
            !retained.contains(f.log.id) && f.modified <= t - window ? path : nil
        }
        for path in expired { untrack(path) }
        return agents
    }

    /// A fresh Codex helper names its parent even when the parent's rollout is cold.
    private func readCodexParents(now: Double) {
        var searched: Set<String> = []
        while true {
            let known = Set(files.values.map { $0.log.id })
            let missing = Set(files.values.compactMap { $0.log.vendor == .codex ? $0.log.parentId : nil })
                .subtracting(known).subtracting(searched)
            if missing.isEmpty { return }
            searched.formUnion(missing)
            for file in listings.values.flatMap({ $0.1 }) where contains(codexRoot.path, file.path) && file.pathExtension == "jsonl" && files[file.path] == nil {
                guard missing.contains(where: { file.lastPathComponent.hasSuffix("-\($0).jsonl") }) else { continue }
                track(codex: file)
                read(file.path, now: now)
            }
        }
    }

    // MARK: discovery

    /// Directory notifications describe structure. Appends are handled by exact file events;
    /// reconciliation checks file metadata even when the directory stamp has not changed.
    private func discoverIndexed(paths: Set<String>, now: Double, window: Double, reconcile: Bool, sweep: Bool = false) -> Set<String> {
        var dirty: Set<String> = []
        var visited: Set<String> = []
        func remove(_ path: String) {
            for key in files.keys.filter({ contains(path, $0) }) { untrack(key) }
            for key in metadata.keys.filter({ contains(path, $0) }) { metadata.removeValue(forKey: key) }
            for key in listings.keys.filter({ contains(path, $0) }) { listings.removeValue(forKey: key) }
        }
        func visit(_ url: URL) {
            let path = url.path
            guard visited.insert(path).inserted else { return }
            guard let stamp = fileStamp(path) else { remove(path); return }
            if stamp.directory {
                guard sessionDirectory(url) else { return }
                let previous = listings[path]
                let relist = reconcile || previous?.0 != stamp
                let items: [URL]
                if relist {
                    didList?(path)
                    guard let found = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
                    items = found
                    listings[path] = (stamp, items)
                    let present = Set(items.map(\.path))
                    for old in previous?.1 ?? [] where !present.contains(old.path) { remove(old.path) }
                } else { items = previous?.1 ?? [] }
                if !relist, !reconcile, !sweep { return }
                for child in items {
                    // Known files require no metadata work for a directory-only event.
                    if !reconcile, metadata[child.path] != nil { continue }
                    if !reconcile, !relist, listings[child.path] == nil { continue }
                    visit(child)
                }
                return
            }
            guard url.pathExtension == "jsonl" else { return }
            let previous = metadata.updateValue(stamp, forKey: path)
            if files[path] == nil, stamp.mtime > now - window {
                if contains(codexRoot.path, path) {
                    let parts = Array(url.pathComponents.dropFirst(codexRoot.pathComponents.count))
                    guard parts.count == 4, zip(parts.prefix(3), [4, 2, 2]).allSatisfy({ $0.0.count == $0.1 && $0.0.allSatisfy(\.isNumber) }) else { return }
                    track(codex: url)
                } else {
                    let parts = Array(url.pathComponents.dropFirst(claudeRoot.pathComponents.count))
                    if parts.count == 2 { track(claude: url, parent: nil) }
                    else if parts.count >= 4, parts[2] == "subagents", url.lastPathComponent.hasPrefix("agent-") {
                        let parent = claudeRoot.appendingPathComponent(parts[0]).appendingPathComponent(parts[1] + ".jsonl")
                        if files[parent.path] == nil, fileStamp(parent.path) != nil {
                            track(claude: parent, parent: nil)
                            dirty.insert(parent.path)
                        }
                        track(claude: url, parent: parts[1])
                    }
                }
            }
            if files[path] != nil, previous != stamp || files[path]?.observed != stamp { dirty.insert(path) }
        }
        for path in paths.sorted() {
            dirty.formUnion(physicalFiles[path] ?? [])
            if contains(path, claudeRoot.path) { visit(claudeRoot) }
            if contains(path, codexRoot.path) { visit(codexRoot) }
            if contains(claudeRoot.path, path) || contains(codexRoot.path, path) {
                visit(URL(fileURLWithPath: path))
            } else if files[path]?.isExec == true { dirty.insert(path) }
        }
        return dirty
    }

    private func sessionDirectory(_ url: URL) -> Bool {
        if contains(codexRoot.path, url.path) {
            let parts = Array(url.pathComponents.dropFirst(codexRoot.pathComponents.count))
            return parts.count <= 3 && zip(parts, [4, 2, 2]).allSatisfy {
                $0.0.count == $0.1 && $0.0.allSatisfy(\.isNumber)
            }
        }
        let parts = Array(url.pathComponents.dropFirst(claudeRoot.pathComponents.count))
        if parts.count <= 2 { return true }
        guard parts[2] == "subagents" else { return false }
        return parts.count == 3 || ((parts.count == 4 || parts.count == 5) && parts[3] == "workflows")
    }

    private func configurationChanged() -> Bool {
        var stamps: [String: FileStamp] = [:]
        for entry in rootEntries {
            if let stamp = fileStamp(entry.path, followLinks: false) { stamps[entry.path] = stamp }
        }
        guard stamps != rootEntryStamps else { return false }
        rootEntryStamps = stamps
        return true
    }

    private func fileStamp(_ path: String, followLinks: Bool = true) -> FileStamp? {
        didStat?(path)
        var info = stat()
        let result = followLinks ? stat(path, &info) : lstat(path, &info)
        guard result == 0 else { return nil }
        return FileStamp(size: info.st_size, modified: info.st_mtimespec, changed: info.st_ctimespec,
                         inode: info.st_ino, device: info.st_dev, directory: info.st_mode & S_IFMT == S_IFDIR)
    }

    private func discoverProcesses() {
        for (id, parents) in rolloutParents() {
            for parent in parents where !threadParents[id, default: []].contains(parent) {
                threadParents[id, default: []].append(parent)
            }
        }
        runs = execRuns()
        execAlive = Set(runs.map(\.log))
        for run in runs where files[run.log] == nil { track(exec: run) }
    }

    private func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private func refreshLive(_ file: URL) {
        guard let stamp = fileStamp(file.path) else {
            liveFiles.removeValue(forKey: file.path)
            liveMetadata.removeValue(forKey: file.path)
            return
        }
        guard liveMetadata[file.path] != stamp else { return }
        liveFiles[file.path] = ClaudeLive.readFile(file)
        liveMetadata[file.path] = stamp
    }

    private func refreshLiveDirectory(reconcile: Bool) {
        let path = claudeSessions.path
        guard let stamp = fileStamp(path) else {
            liveFiles.removeAll(); liveMetadata.removeAll(); listings.removeValue(forKey: path)
            return
        }
        let items: [URL]
        if !reconcile, let cached = listings[path], cached.0 == stamp { items = cached.1 }
        else {
            didList?(path)
            guard let found = try? fm.contentsOfDirectory(at: claudeSessions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
            items = found
            listings[path] = (stamp, items)
        }
        let present = Set(items.map(\.path))
        liveFiles = liveFiles.filter { present.contains($0.key) }
        liveMetadata = liveMetadata.filter { present.contains($0.key) }
        for file in items where file.pathExtension == "json" { refreshLive(file) }
    }

    private func untrack(_ path: String) {
        guard let file = files.removeValue(forKey: path) else { return }
        physicalFiles[file.physicalPath]?.remove(path)
        if physicalFiles[file.physicalPath]?.isEmpty == true { physicalFiles.removeValue(forKey: file.physicalPath) }
    }

    private func track(claude file: URL, parent: String?) {
        let base = file.deletingPathExtension().lastPathComponent
        var log: SessionLog
        if let parent {
            let meta = try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("meta.json"))
            let agentId = String(base.dropFirst("agent-".count))
            log = SessionLog(id: "\(parent)/\(agentId)", vendor: .claude, parentId: parent,
                             subTitle: ClaudeLine.subagentTitle(meta: meta))
        } else {
            log = SessionLog(id: base, vendor: .claude)
        }
        log.path = file.path
        files[file.path] = Tracked(log: log, offset: startOffset(file.path), isSubagent: parent != nil)
        physicalFiles[files[file.path]!.physicalPath, default: []].insert(file.path)
    }

    private func track(codex file: URL) {
        var log = SessionLog(id: file.deletingPathExtension().lastPathComponent, vendor: .codex)
        log.path = file.path
        let initial = log
        // The thread's identity and parent live in the first line, which a tail read would skip.
        if let first = firstLine(file.path), let r = try? JSONSerialization.jsonObject(with: first) as? Rec {
            CodexLine.apply(r, to: &log)
        }
        files[file.path] = Tracked(log: log, offset: startOffset(file.path), isSubagent: false, initial: initial)
        physicalFiles[files[file.path]!.physicalPath, default: []].insert(file.path)
    }

    private func track(exec run: ExecRun) {
        // Under a parent from another project the row says which project it works in.
        let folder = run.cwd.map { ($0 as NSString).lastPathComponent }
        let project = names.name(for: run.cwd)
        let title = folder == nil || folder == project ? project : "\(project) · \(folder ?? "")"
        var log = SessionLog(id: "exec:" + (run.log as NSString).lastPathComponent, vendor: .codex, subTitle: title)
        log.parentCandidates = run.parents
        log.resumable = false
        log.cwd = run.cwd
        log.model = run.model
        log.effort = run.effort
        log.path = run.log
        // A bounded tail can skip thread.started; identity must survive long exec streams.
        if let first = firstLine(run.log), let r = try? JSONSerialization.jsonObject(with: first) as? Rec,
           r["type"] as? String == "thread.started", let id = r["thread_id"] as? String, !id.isEmpty {
            log.id = id
        }
        files[run.log] = Tracked(log: log, offset: startOffset(run.log), isSubagent: false, isExec: true)
        physicalFiles[files[run.log]!.physicalPath, default: []].insert(run.log)
    }

    private func parents(of pid: Int32) -> [String] {
        Lineage.parents(env: Proc.argsAndEnv(pid).1)
    }

    // MARK: reading

    private func read(_ path: String, now: Double) {
        guard var f = files[path] else { return }
        guard let stamp = fileStamp(path) else { untrack(path); metadata.removeValue(forKey: path); return }
        // Avoid opening unchanged logs, including retained ancestors and exec streams.
        if f.inode == stamp.inode, f.device == stamp.device,
           f.observed == stamp { return }
        didOpen?(path)
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        var info = stat()
        didStat?(path)
        guard fstat(h.fileDescriptor, &info) == 0 else { return }
        let size = UInt64(max(0, info.st_size))
        if size < f.offset || (f.inode != nil && (f.inode != info.st_ino || f.device != info.st_dev)) {
            f.log = f.initial
            if f.log.vendor == .codex, let first = firstLine(h, chunkBytes: 1),
               let r = try? JSONSerialization.jsonObject(with: first) as? Rec {
                if f.isExec { ExecLine.apply(r, to: &f.log, at: now) }
                else { CodexLine.apply(r, to: &f.log) }
            }
            f.offset = size > Self.tailBytes ? size - Self.tailBytes : 0
        }
        f.modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        f.inode = info.st_ino
        f.device = info.st_dev
        f.observed = stamp
        files[path] = f
        guard (try? h.seek(toOffset: f.offset)) != nil, let data = try? h.read(upToCount: Int(size - f.offset)), !data.isEmpty else { return }
        didRead?(data.count)
        // A tail read may start mid-line: that fragment fails to parse and is skipped like any bad line.
        var consumed = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while consumed < raw.count, let newline = memchr(base.advanced(by: consumed), 0x0A, raw.count - consumed) {
                let end = base.distance(to: UnsafeRawPointer(newline))
                let line = data[(data.startIndex + consumed)..<(data.startIndex + end)]
                if let r = try? JSONSerialization.jsonObject(with: line) as? Rec {
                    switch f.log.vendor {
                    case .claude: ClaudeLine.apply(r, to: &f.log, isSubagent: f.isSubagent)
                    case .codex where f.isExec: ExecLine.apply(r, to: &f.log, at: now)
                    case .codex: CodexLine.apply(r, to: &f.log)
                    }
                }
                consumed = end + 1
            }
        }
        f.offset += UInt64(consumed)
        files[path] = f
    }

    private func startOffset(_ path: String) -> UInt64 {
        didStat?(path)
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        return size > Self.tailBytes ? size - Self.tailBytes : 0
    }

    private func firstLine(_ path: String) -> Data? {
        didOpen?(path)
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        return firstLine(h, chunkBytes: 64 << 10)
    }

    private func firstLine(_ h: FileHandle, chunkBytes: Int) -> Data? {
        guard (try? h.seek(toOffset: 0)) != nil else { return nil }
        var buf = Data()
        // Resets read exactly through the newline; discovery keeps its chunked reads.
        while buf.count < 1 << 20, let chunk = try? h.read(upToCount: chunkBytes), !chunk.isEmpty {
            didRead?(chunk.count)
            if let nl = chunk.firstIndex(of: 0x0A) { return buf + chunk[..<nl] }
            buf += chunk
        }
        return buf.isEmpty ? nil : buf
    }

}
