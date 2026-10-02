import Foundation
import Darwin

/// Cheap kernel queries used to label tabs and the status bar without shell integration.
enum ProcInfo {
    static func name(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
        // proc_name is denied for setuid/root processes (top, sudo…); sysctl still reports p_comm.
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return withUnsafePointer(to: &info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    static func cwd(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Current branch for a directory, read straight from `.git/HEAD`.
    static func gitBranch(in dir: String) -> String? {
        var url = URL(fileURLWithPath: dir)
        let fm = FileManager.default
        for _ in 0..<40 {
            let git = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
                var headURL = git.appendingPathComponent("HEAD")
                if !isDir.boolValue, let s = try? String(contentsOf: git, encoding: .utf8),
                   s.hasPrefix("gitdir:") {
                    let p = s.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    headURL = URL(fileURLWithPath: p, relativeTo: url).appendingPathComponent("HEAD")
                }
                guard let head = try? String(contentsOf: headURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst(16)) }
                return String(head.prefix(7))
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static var loginShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return "/bin/zsh"
    }

    static func shellEscape(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+,@%:~"))
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
