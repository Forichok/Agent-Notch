import Foundation

/// Names a working directory after its git repository, so worktrees land in their main project.
public final class ProjectNames: @unchecked Sendable {
    private var cache: [String: String] = [:]
    private let fm = FileManager.default

    public init() {}

    public func name(for cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return Loc.t("no project", "без проекта") }
        if let hit = cache[cwd] { return hit }
        let name = resolve(cwd)
        cache[cwd] = name
        return name
    }

    private func resolve(_ cwd: String) -> String {
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        while dir.path != "/" {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
                if isDir.boolValue { return dir.lastPathComponent }
                // A worktree: ".git" is a file "gitdir: /main/repo/.git/worktrees/<name>".
                if let text = try? String(contentsOf: git, encoding: .utf8),
                   let range = text.range(of: "gitdir:") {
                    let gitdir = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if let cut = gitdir.range(of: "/.git/") {
                        return URL(fileURLWithPath: String(gitdir[..<cut.lowerBound])).lastPathComponent
                    }
                }
                return dir.lastPathComponent
            }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}
