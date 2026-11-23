import AppKit
import Foundation

// MARK: - 삭제 (안전장치 포함)

public struct DeletionFailure: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
}

public struct DeletionReport: Sendable {
    public var freedBytes: Int64 = 0
    public var trashedBytes: Int64 = 0
    public var removedCount: Int = 0
    public var failures: [DeletionFailure] = []
    public var commandOutputs: [String] = []
    public init() {}

    public mutating func merge(_ o: DeletionReport) {
        freedBytes += o.freedBytes
        trashedBytes += o.trashedBytes
        removedCount += o.removedCount
        failures += o.failures
        commandOutputs += o.commandOutputs
    }
}

public enum Deleter {
    /// 절대로 통째로 지우면 안 되는 경로
    public static func isProtected(_ rawPath: String) -> Bool {
        let path = (rawPath as NSString).standardizingPath
        let home = Paths.home
        let fixed: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin",
                                  "/sbin", "/opt", "/etc", "/var", "/tmp", "/Volumes", "/cores", home]
        if fixed.contains(path) { return true }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") { return true }
        if path.hasPrefix(home + "/") {
            let rel = String(path.dropFirst(home.count + 1))
            let comps = rel.split(separator: "/").map(String.init)
            // 홈 바로 아래 기본 폴더와 ~/Library 바로 아래 폴더 자체는 보호
            if comps.count == 1 {
                let topProtected: Set<String> = ["Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
                                                 "Public", "Applications", ".Trash", ".ssh", ".gnupg", ".config", ".zshrc", ".bash_profile"]
                if topProtected.contains(comps[0]) { return true }
            }
            if comps.first == "Library" && comps.count <= 2 { return true }
            if comps.first == "Library" && comps.count >= 2 && comps[1] == "Keychains" { return true }
            if comps.first == ".ssh" || comps.first == ".gnupg" { return true }
            return false
        }
        // 홈 밖에서는 /Applications 안의 앱만 허용
        if path.hasPrefix("/Applications/") { return false }
        return true
    }

    /// 항목 하나를 지운다. permanent=false면 휴지통으로.
    public static func remove(_ path: String, permanent: Bool, knownSize: Int64? = nil) -> DeletionReport {
        var report = DeletionReport()
        if isProtected(path) {
            report.failures.append(DeletionFailure(path: path, reason: "보호된 경로라 지우지 않았습니다"))
            return report
        }
        let size = knownSize ?? DirSize.measure(path).bytes
        let url = URL(fileURLWithPath: path)
        do {
            if permanent {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    // Go 모듈 캐시처럼 읽기 전용 폴더가 있으면 쓰기 권한을 준 뒤 다시 시도
                    makeWritable(path)
                    try FileManager.default.removeItem(at: url)
                }
                report.freedBytes += size
            } else {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                report.trashedBytes += size
            }
            report.removedCount += 1
        } catch {
            report.failures.append(DeletionFailure(path: path, reason: friendly(error)))
        }
        return report
    }

    /// 폴더는 남기고 안의 내용만 지운다.
    public static func removeContents(of dir: String, permanent: Bool) -> DeletionReport {
        var report = DeletionReport()
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            if Paths.exists(dir) {
                report.failures.append(DeletionFailure(path: dir, reason: "폴더를 읽을 권한이 없습니다 (전체 디스크 접근 권한 필요)"))
            }
            return report
        }
        let paths = items.map { dir + "/" + $0 }
        for r in parallelMap(paths, { remove($0, permanent: permanent) }) { report.merge(r) }
        return report
    }

    static func makeWritable(_ path: String) {
        guard let e = FileManager.default.enumerator(atPath: path) else { return }
        _ = chmod(path, 0o755)
        while let rel = e.nextObject() as? String {
            let p = path + "/" + rel
            var st = stat()
            if lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                _ = chmod(p, 0o755)
            }
        }
    }

    static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return "권한이 없습니다 (시스템이 보호하거나 다른 사용자 소유)"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "이미 없는 파일입니다"
            default: break
            }
        }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain {
            if u.code == Int(EPERM) || u.code == Int(EACCES) { return "권한이 없습니다 (시스템이 보호하는 항목)" }
            if u.code == Int(EBUSY) { return "사용 중인 파일입니다" }
        }
        return ns.localizedDescription
    }

    /// Finder를 통해 휴지통 비우기 (권한 문제로 직접 못 지울 때)
    public static func emptyTrashWithFinder() -> (Bool, String) {
        let r = Shell.run("/usr/bin/osascript -e 'tell application \"Finder\" to empty trash'")
        return (r.status == 0, r.output)
    }

    /// Finder를 통해 휴지통으로 이동 (관리자 소유 앱 등은 Finder가 암호를 물어 처리)
    public static func trashWithFinder(_ path: String) -> (Bool, String) {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to delete (POSIX file \"\(escaped)\" as alias)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - 셸 명령

public enum Shell {
    static let extraPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:\(Paths.home)/.orbstack/bin:/Applications/Docker.app/Contents/Resources/bin:\(Paths.home)/go/bin:/usr/local/go/bin"

    @discardableResult
    public static func run(_ command: String, timeout: TimeInterval = 900) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// 관리자 암호를 묻는 대화상자를 띄워 실행
    @discardableResult
    public static func runAdmin(_ command: String) -> (status: Int32, output: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    public static func which(_ tool: String) -> String? {
        let r = run("command -v \(tool)", timeout: 10)
        let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !out.isEmpty ? out : nil
    }
}

// MARK: - 디스크 용량

public struct VolumeStats: Sendable {
    public let total: Int64
    /// 지금 바로 쓸 수 있는 공간
    public let free: Int64
    /// macOS가 필요하면 비울 수 있는 공간(퍼지 가능)까지 포함한 여유 공간
    public let freeIncludingPurgeable: Int64
    public var purgeable: Int64 { max(0, freeIncludingPurgeable - free) }
    public var used: Int64 { total - free }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public static func read(path: String = "/") -> VolumeStats? {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                         .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity else { return nil }
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        let important = v.volumeAvailableCapacityForImportantUsage ?? free
        return VolumeStats(total: Int64(total), free: free, freeIncludingPurgeable: max(free, important))
    }
}

// MARK: - 권한

public enum Permissions {
    /// 전체 디스크 접근 권한이 있는지 (보호된 파일을 열어 보는 방식)
    public static func hasFullDiskAccess() -> Bool {
        let probes = [
            Paths.home + "/Library/Application Support/com.apple.TCC/TCC.db",
            Paths.home + "/Library/Safari/Bookmarks.plist",
            Paths.home + "/Library/Containers/com.apple.stocks",
        ]
        for p in probes where FileManager.default.fileExists(atPath: p) {
            let fd = open(p, O_RDONLY)
            if fd >= 0 { close(fd); return true }
            if errno == EPERM || errno == EACCES { return false }
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: Paths.home + "/Library/Safari")) != nil
    }

    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
