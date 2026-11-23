import Foundation
import Darwin

/// 스캔 결과 트리의 노드. 작은 파일은 개별 노드 대신 폴더별 합계로만 보관해 메모리를 아낀다.
public final class FileNode: Identifiable, @unchecked Sendable {
    public let name: String
    public fileprivate(set) weak var parent: FileNode?
    public fileprivate(set) var size: Int64 = 0
    public fileprivate(set) var fileCount: Int = 0
    public let isDirectory: Bool
    public fileprivate(set) var children: [FileNode] = []
    public fileprivate(set) var smallFilesSize: Int64 = 0
    public fileprivate(set) var smallFilesCount: Int = 0
    public fileprivate(set) var newest: TimeInterval = 0
    public fileprivate(set) var accessDenied = false
    public fileprivate(set) var notScanned = false
    fileprivate var level: Int = 0

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, isDirectory: Bool, parent: FileNode?) {
        self.name = name
        self.isDirectory = isDirectory
        self.parent = parent
    }

    public var path: String {
        var parts: [String] = []
        var n: FileNode? = self
        while let cur = n { parts.append(cur.name); n = cur.parent }
        parts.reverse()
        guard var result = parts.first else { return "" }
        for p in parts.dropFirst() {
            if !result.hasSuffix("/") { result += "/" }
            result += p
        }
        return result
    }

    public var displayName: String {
        parent == nil ? Paths.abbreviate(name) : name
    }

    public var modifiedDate: Date? { newest > 0 ? Date(timeIntervalSince1970: newest) : nil }

    public var ancestors: [FileNode] {
        var list: [FileNode] = []
        var n: FileNode? = self
        while let cur = n { list.append(cur); n = cur.parent }
        return list.reversed()
    }

    public var isPackage: Bool {
        guard isDirectory else { return false }
        let packageExts: Set<String> = ["app", "photoslibrary", "bundle", "framework", "fcpbundle", "imovielibrary", "musiclibrary",
                                        "tvlibrary", "xcarchive", "sparsebundle", "pvm", "utm", "vmwarevm", "logicx", "band",
                                        "xcodeproj", "xcworkspace", "plugin", "kext", "appex", "rtfd", "pages", "numbers", "key"]
        return packageExts.contains(Paths.ext(name))
    }

    /// 트리에서 이 노드를 떼어내고 상위 폴더 크기를 갱신한다.
    public func detachFromParent() {
        guard let p = parent else { return }
        p.children.removeAll { $0 === self }
        var a: FileNode? = p
        while let n = a {
            n.size -= size
            n.fileCount -= fileCount
            a = n.parent
        }
        parent = nil
    }

    /// 폴더 내용을 비운 뒤 트리 반영. remaining = 남은 크기(지우지 못한 것)
    public func markEmptied(remaining: Int64) {
        let removed = size - remaining
        children.removeAll()
        smallFilesSize = 0
        smallFilesCount = 0
        let removedCount = fileCount
        fileCount = 0
        size = remaining
        var a = parent
        while let n = a {
            n.size -= removed
            n.fileCount -= removedCount
            a = n.parent
        }
    }
}

public struct ScanProgress: Sendable {
    public var files: Int = 0
    public var bytes: Int64 = 0
    public var currentPath: String = ""
    public var denied: Int = 0
    public init() {}
}

public struct ScanResult: @unchecked Sendable {
    public let root: FileNode
    public let largeFiles: [FileNode]
    public let deniedPaths: [String]
    public let fileCount: Int
    public let duration: TimeInterval
    public let date: Date
}

struct InodeKey: Hashable {
    let dev: Int32
    let ino: UInt64
}

private let SF_DATALESS_FLAG: UInt32 = 0x4000_0000

/// iCloud 등 클라우드 전용 파일을 열거하다가 다운로드가 일어나지 않도록 막는다.
public func disableDatalessMaterialization() {
    _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
}

public final class DiskScanner: @unchecked Sendable {
    private let cancelFlag = Locked(false)
    public var isCancelled: Bool { cancelFlag.get() }
    public func cancel() { cancelFlag.mutate { $0 = true } }

    public init() {}

    /// 전체 디스크(/)를 훑을 때 건너뛸 경로
    public static let skipPaths: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/automount", "/Network"]

    public func scan(root: String, fileThreshold: Int64 = 1_000_000, largeThreshold: Int64 = 50_000_000,
                     progress: @escaping (ScanProgress) -> Void) -> ScanResult? {
        disableDatalessMaterialization()
        let start = Date()
        guard let rootC = strdup(root) else { return nil }
        defer { free(rootC) }
        var argv: [UnsafeMutablePointer<CChar>?] = [rootC, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }

        var stack: [FileNode] = []
        var rootNode: FileNode?
        var seen = Set<InodeKey>()
        var large: [FileNode] = []
        var denied: [String] = []
        var prog = ScanProgress()
        var lastReport = DispatchTime.now().uptimeNanoseconds
        var counter = 0

        func attach(_ node: FileNode) {
            if let p = stack.last {
                p.children.append(node)
                p.size += node.size
                p.fileCount += node.fileCount
                if node.newest > p.newest { p.newest = node.newest }
            } else {
                rootNode = node
            }
        }

        while let entPtr = fts_read(fts) {
            counter += 1
            if counter & 0x3FF == 0 {
                if isCancelled { return nil }
                let now = DispatchTime.now().uptimeNanoseconds
                if now - lastReport > 120_000_000 {
                    lastReport = now
                    prog.currentPath = String(cString: entPtr.pointee.fts_path)
                    progress(prog)
                }
            }

            let ent = entPtr.pointee
            let info = Int32(ent.fts_info)
            let level = Int(ent.fts_level)

            switch info {
            case FTS_D:
                let name = level == 0 ? root : Self.name(ent)
                let node = FileNode(name: name, isDirectory: true, parent: stack.last)
                node.level = level
                if let st = ent.fts_statp?.pointee {
                    node.size = Int64(st.st_blocks) * 512
                    node.newest = TimeInterval(st.st_mtimespec.tv_sec)
                    if (st.st_flags & SF_DATALESS_FLAG) != 0 {
                        node.notScanned = true
                        _ = fts_set(fts, entPtr, FTS_SKIP)
                        attach(node)
                        continue
                    }
                }
                if level > 0, Self.skipPaths.contains(String(cString: ent.fts_path)) {
                    node.notScanned = true
                    _ = fts_set(fts, entPtr, FTS_SKIP)
                    attach(node)
                    continue
                }
                stack.append(node)

            case FTS_DP:
                guard let top = stack.last, top.level == level else { continue }
                stack.removeLast()
                top.children.sort { $0.size > $1.size }
                attach(top)

            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = ent.fts_statp?.pointee else { continue }
                var size = Int64(st.st_blocks) * 512
                if st.st_nlink > 1 && (st.st_mode & S_IFMT) == S_IFREG {
                    if !seen.insert(InodeKey(dev: st.st_dev, ino: st.st_ino)).inserted { size = 0 }
                }
                let mtime = TimeInterval(st.st_mtimespec.tv_sec)
                prog.files += 1
                prog.bytes += size
                guard let parent = stack.last else {
                    let n = FileNode(name: root, isDirectory: false, parent: nil)
                    n.size = size; n.fileCount = 1; n.newest = mtime
                    rootNode = n
                    continue
                }
                if size >= fileThreshold {
                    let n = FileNode(name: Self.name(ent), isDirectory: false, parent: parent)
                    n.size = size
                    n.fileCount = 1
                    n.newest = mtime
                    parent.children.append(n)
                    if size >= largeThreshold { large.append(n) }
                } else {
                    parent.smallFilesSize += size
                    parent.smallFilesCount += 1
                }
                parent.size += size
                parent.fileCount += 1
                if mtime > parent.newest { parent.newest = mtime }

            case FTS_DNR, FTS_ERR:
                let path = String(cString: ent.fts_path)
                // 읽을 수 없는 폴더는 FTS_D로 한 번 나온 뒤 FTS_DP 대신 FTS_DNR로 다시 나온다.
                // 이미 스택에 올린 같은 폴더라면 꺼내서 마무리해야 형제 폴더가 그 안에 잘못 들어가지 않는다.
                if let top = stack.last, top.level == level {
                    stack.removeLast()
                    top.accessDenied = true
                    top.children.sort { $0.size > $1.size }
                    attach(top)
                } else if info == FTS_DNR || (ent.fts_statp.map { ($0.pointee.st_mode & S_IFMT) == S_IFDIR } ?? false) {
                    let node = FileNode(name: level == 0 ? root : Self.name(ent), isDirectory: true, parent: stack.last)
                    node.accessDenied = true
                    node.level = level
                    attach(node)
                } else {
                    continue
                }
                prog.denied += 1
                if denied.count < 500 { denied.append(path) }

            default:
                continue
            }
        }

        // 취소 없이 끝났다면 스택이 비어 있어야 정상. 남아 있으면 정리.
        while let top = stack.popLast() {
            top.children.sort { $0.size > $1.size }
            if let p = stack.last {
                p.children.append(top); p.size += top.size; p.fileCount += top.fileCount
            } else { rootNode = top }
        }

        guard let rootNode else { return nil }
        progress(prog)
        large.sort { $0.size > $1.size }
        return ScanResult(root: rootNode, largeFiles: Array(large.prefix(1000)), deniedPaths: denied,
                          fileCount: prog.files, duration: Date().timeIntervalSince(start), date: Date())
    }

    private static func name(_ ent: FTSENT) -> String {
        let base = ent.fts_path!
        let offset = Int(ent.fts_pathlen) - Int(ent.fts_namelen)
        return String(cString: base + max(0, offset))
    }
}

// MARK: - 단순 크기 계산

public struct SizeInfo: Sendable {
    public var bytes: Int64 = 0
    public var files: Int = 0
    public var newest: TimeInterval = 0
    public var denied = false
    public var exists = true
    public var newestDate: Date? { newest > 0 ? Date(timeIntervalSince1970: newest) : nil }
}

public enum DirSize {
    /// 경로 하나의 실제 디스크 사용량(할당 크기)
    public static func measure(_ path: String) -> SizeInfo {
        var info = SizeInfo()
        guard Paths.exists(path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil else {
            info.exists = false
            return info
        }
        guard let c = strdup(path) else { return info }
        defer { free(c) }
        var argv: [UnsafeMutablePointer<CChar>?] = [c, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return info }
        defer { fts_close(fts) }
        var seen = Set<InodeKey>()
        while let e = fts_read(fts) {
            let ent = e.pointee
            switch Int32(ent.fts_info) {
            case FTS_D:
                if let st = ent.fts_statp?.pointee {
                    info.bytes += Int64(st.st_blocks) * 512
                    if (st.st_flags & SF_DATALESS_FLAG) != 0 { _ = fts_set(fts, e, FTS_SKIP) }
                }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = ent.fts_statp?.pointee else { continue }
                if st.st_nlink > 1 && (st.st_mode & S_IFMT) == S_IFREG {
                    if !seen.insert(InodeKey(dev: st.st_dev, ino: st.st_ino)).inserted { continue }
                }
                info.bytes += Int64(st.st_blocks) * 512
                info.files += 1
                let m = TimeInterval(st.st_mtimespec.tv_sec)
                if m > info.newest { info.newest = m }
            case FTS_DNR, FTS_ERR:
                info.denied = true
            default:
                break
            }
        }
        return info
    }

    public static func measure(_ paths: [String]) -> SizeInfo {
        var total = SizeInfo()
        total.exists = false
        for s in parallelMap(paths, { measure($0) }) where s.exists {
            total.exists = true
            total.bytes += s.bytes
            total.files += s.files
            total.newest = max(total.newest, s.newest)
            total.denied = total.denied || s.denied
        }
        return total
    }
}
