import Foundation
import MacCleanCore

// 개발용 검증 도구. 아무것도 지우지 않는다.
let args = CommandLine.arguments.dropFirst()
let cmd = args.first ?? "help"

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

switch cmd {
case "explain":
    for raw in args.dropFirst() {
        let path = Paths.expand(raw)
        let i = PathKnowledge.shared.insight(for: path, isDirectory: Paths.isDirectory(path))
        print("[\(i.safety.shortLabel)] \(Paths.abbreviate(path))")
        print("   \(i.title)  (\(i.kind.label)\(i.inherited ? ", 상속" : "")\(i.confident ? "" : ", 추정")\(i.isOrphan ? ", 잔여물" : ""))")
        if let a = i.appName { print("   앱: \(a) \(i.appBundleID ?? "")") }
        print("   \(i.detail.replacingOccurrences(of: "\n", with: " ").prefix(160))")
        print("   조치: \(i.action)")
    }

case "scan":
    let root = Paths.expand(args.dropFirst().first ?? "~")
    let scanner = DiskScanner()
    var last = Date()
    guard let r = scanner.scan(root: root, progress: { p in
        if Date().timeIntervalSince(last) > 2 { last = Date(); FileHandle.standardError.write("  \(p.files) files, \(Fmt.bytes(p.bytes))\n".data(using: .utf8)!) }
    }) else { print("scan failed"); exit(1) }
    print("총 \(Fmt.bytes(r.root.size)), 파일 \(Fmt.count(r.fileCount))개, \(String(format: "%.1f", r.duration))초, 접근 거부 \(r.deniedPaths.count)개")
    for c in r.root.children.prefix(25) {
        let i = PathKnowledge.shared.insight(for: c.path, isDirectory: c.isDirectory)
        print("\(lpad(Fmt.bytes(c.size), 10))  [\(i.safety.shortLabel)] \(pad(c.name, 32)) \(i.title)")
    }
    print("--- 큰 파일")
    for f in r.largeFiles.prefix(10) {
        let i = PathKnowledge.shared.insight(for: f.path, isDirectory: false)
        print("\(lpad(Fmt.bytes(f.size), 10))  [\(i.safety.shortLabel)] \(Paths.abbreviate(f.path))  — \(i.title)")
    }

case "cleanup":
    let start = Date()
    let groups = CleanupScanner().scan { FileHandle.standardError.write("· \($0)\n".data(using: .utf8)!) }
    print("검사 \(String(format: "%.1f", Date().timeIntervalSince(start)))초")
    var selectedTotal: Int64 = 0
    for g in groups {
        print("\n■ \(g.title) — \(Fmt.bytes(g.totalSize))  (\(g.summary))")
        for it in g.items.prefix(14) {
            if it.defaultSelected && it.size > 0 { selectedTotal += it.size }
            print("  \(it.defaultSelected ? "☑" : "☐") \(lpad(Fmt.bytes(it.size), 10)) [\(it.safety.shortLabel)] \(it.title)  · \(it.subtitle.prefix(70))")
        }
        if g.items.count > 14 { print("  … 외 \(g.items.count - 14)개") }
    }
    print("\n기본 선택 합계: \(Fmt.bytes(selectedTotal))")

case "memory":
    let s = MemoryReader.read()
    print("전체 \(Fmt.bytes(s.total)) / 사용 \(Fmt.bytes(s.used)) (앱 \(Fmt.bytes(s.appMemory)), 와이어드 \(Fmt.bytes(s.wired)), 압축 \(Fmt.bytes(s.compressed)))")
    print("캐시된 파일 \(Fmt.bytes(s.cached)), 여유 \(Fmt.bytes(s.free)), 스왑 \(Fmt.bytes(s.swapUsed))/\(Fmt.bytes(s.swapTotal)), 압력 \(s.pressureLabel)(\(s.pressureLevel)), 가용 \(s.availablePercent)%")
    let sampler = ProcessSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1)
    let (groups, hidden) = sampler.sample()
    print("프로세스 그룹 \(groups.count)개, 권한 없음 \(hidden)개")
    for g in groups.prefix(15) {
        print("\(lpad(Fmt.bytes(g.memory), 10)) \(lpad(String(format: "%.1f%%", g.cpuPercent), 7)) \(pad(g.name, 34)) x\(g.processCount)  \(g.note?.text.prefix(50) ?? "")")
    }

case "apps":
    let list = AppScanner.listApps()
    let measured = list.prefix(Int(args.dropFirst().first ?? "15") ?? 15).map { AppScanner.measure($0) }
    for a in measured.sorted(by: { $0.totalSize > $1.totalSize }) {
        print("\(lpad(Fmt.bytes(a.totalSize), 10)) (앱 \(lpad(Fmt.bytes(a.appSize), 9)), 데이터 \(lpad(Fmt.bytes(a.dataSize), 9)))  \(pad(a.name, 28)) 마지막 사용: \(Fmt.ago(a.lastUsed))")
    }
    print("총 \(list.count)개 앱")

case "volume":
    if let v = VolumeStats.read() {
        print("전체 \(Fmt.bytes(v.total)), 사용 \(Fmt.bytes(v.used)), 여유 \(Fmt.bytes(v.free)), 퍼지 가능 포함 \(Fmt.bytes(v.freeIncludingPurgeable))")
    }
    print("전체 디스크 접근 권한: \(Permissions.hasFullDiskAccess())")

case "clean":
    // mccheck clean [--default] [--include 문자열]... [--exclude 문자열]... [--trash] [--yes]
    // --yes 가 없으면 무엇을 할지 보여 주기만 한다.
    let a = Array(args.dropFirst())
    func values(_ flag: String) -> [String] { a.indices.filter { a[$0] == flag && $0 + 1 < a.count }.map { a[$0 + 1] } }
    let includes = values("--include"), excludes = values("--exclude")
    let useDefault = a.contains("--default"), go = a.contains("--yes"), forceTrash = a.contains("--trash")
    let groups = CleanupScanner().scan { FileHandle.standardError.write("· \($0)\n".data(using: .utf8)!) }
    let items = groups.flatMap(\.items).filter { it in
        guard it.isActionable else { return false }
        let picked = (useDefault && it.defaultSelected) || includes.contains { it.id.contains($0) || it.title.contains($0) }
        return picked && !excludes.contains { it.id.contains($0) || it.title.contains($0) }
    }
    var total: Int64 = 0
    for it in items {
        total += max(0, it.size)
        let how: String
        switch it.method {
        case .command(let c, _): how = "명령: \(c)"
        case .emptyTrash: how = "휴지통 비우기"
        default: how = (it.permanent && !forceTrash) ? "바로 삭제" : "휴지통"
        }
        print("  \(lpad(Fmt.bytes(it.size), 10)) [\(it.safety.shortLabel)] \(pad(it.title, 36)) \(how)")
    }
    print("합계 \(items.count)개 · \(Fmt.bytes(total))")
    guard go else { print("(미리보기입니다. 실행하려면 --yes)"); exit(0) }
    let before = VolumeStats.read()?.free ?? 0
    let rep = CleanupScanner.execute(items, forceTrash: forceTrash) { FileHandle.standardError.write("  \($0)\n".data(using: .utf8)!) }
    Thread.sleep(forTimeInterval: 2)
    let after = VolumeStats.read()?.free ?? 0
    print("바로 삭제 \(Fmt.bytes(rep.freedBytes)) · 휴지통 \(Fmt.bytes(rep.trashedBytes)) · 실패 \(rep.failures.count)개")
    print("여유 공간: \(Fmt.bytes(before)) → \(Fmt.bytes(after)) (+\(Fmt.bytes(after - before)))")
    var reasons: [String: Int] = [:]
    for f in rep.failures { reasons[f.reason, default: 0] += 1 }
    for (r, n) in reasons.sorted(by: { $0.value > $1.value }).prefix(6) { print("  실패 \(n)개: \(r)") }
    for o in rep.commandOutputs { print(o.split(separator: "\n").prefix(3).joined(separator: "\n")) }

case "selftest":
    // 홈 아래 임시 폴더만 만들고 지운다. 실제 사용자 파일은 건드리지 않는다.
    var ok = true
    func check(_ cond: Bool, _ label: String) { print((cond ? "  ✓ " : "  ✗ ") + label); if !cond { ok = false } }
    let h = Paths.home
    print("보호 경로 판정")
    for p in ["/", "/System/Library", "/Applications", h, h + "/Library", h + "/Library/Caches", h + "/Documents", h + "/Downloads",
              h + "/.ssh/id_rsa", h + "/Library/Keychains/login.keychain-db", "/usr/local/bin/x", "/Library/Caches/x", h + "/.Trash"] {
        check(Deleter.isProtected(p), "보호됨: \(Paths.abbreviate(p))")
    }
    for p in [h + "/Library/Caches/com.foo.bar", h + "/Downloads/a.dmg", "/Applications/Foo.app", h + "/.npm/_cacache/x", h + "/.Trash/old.txt"] {
        check(!Deleter.isProtected(p), "허용됨: \(Paths.abbreviate(p))")
    }
    print("실제 삭제 (임시 폴더)")
    let base = h + "/.macclean-selftest-\(getpid())"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: base + "/cache/sub", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: base + "/ro/inner", withIntermediateDirectories: true)
    for f in ["cache/a.bin", "cache/sub/b.bin", "ro/inner/c.bin"] {
        fm.createFile(atPath: base + "/" + f, contents: Data(repeating: 7, count: 300_000))
    }
    chmod(base + "/ro/inner/c.bin", 0o444); chmod(base + "/ro/inner", 0o555); chmod(base + "/ro", 0o555)
    let before = DirSize.measure(base + "/cache").bytes
    check(before >= 600_000, "크기 측정 \(Fmt.bytes(before))")
    let item = CleanupItem(id: "t", title: "t", subtitle: "", detail: "", safety: .safe, kind: .cache, size: before,
                           method: .deleteContents([base + "/cache"]), permanent: true, defaultSelected: true)
    let rep = CleanupScanner.execute([item], forceTrash: false) { _ in }
    check(rep.failures.isEmpty && rep.freedBytes >= 600_000, "내용 비우기: \(Fmt.bytes(rep.freedBytes)) 확보, 실패 \(rep.failures.count)")
    check(Paths.isDirectory(base + "/cache") && Paths.children(base + "/cache").isEmpty, "폴더 자체는 남음")
    let r2 = Deleter.remove(base + "/ro", permanent: true)
    check(r2.failures.isEmpty && !Paths.exists(base + "/ro"), "읽기 전용 폴더 삭제 (Go 모듈 캐시 같은 경우)")
    let r3 = Deleter.remove(h + "/Library", permanent: true)
    check(!r3.failures.isEmpty && Paths.exists(h + "/Library"), "보호 경로 삭제 거부")
    try? fm.removeItem(atPath: base)
    check(!Paths.exists(base), "임시 폴더 정리")
    print(ok ? "모두 통과" : "실패 있음")
    exit(ok ? 0 : 1)

default:
    print("usage: mccheck explain <path>... | scan <dir> | cleanup | memory | apps [n] | volume")
}
