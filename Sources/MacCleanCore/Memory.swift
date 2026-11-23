import AppKit
import Darwin

public struct MemoryStats: Sendable {
    public var total: UInt64 = 0
    public var appMemory: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    public var cached: UInt64 = 0
    public var free: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0
    /// 1: 정상, 2: 경고, 4: 위험
    public var pressureLevel: Int = 1
    /// 커널이 보는 '사용 가능한 메모리' 비율(0~100)
    public var availablePercent: Int = 100
    public var used: UInt64 { appMemory + wired + compressed }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public var pressureLabel: String {
        switch pressureLevel {
        case 4: "위험"
        case 2: "경고"
        default: "정상"
        }
    }
}

public enum MemoryReader {
    public static func read() -> MemoryStats {
        var s = MemoryStats()
        s.total = ProcessInfo.processInfo.physicalMemory

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            s.appMemory = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            s.wired = UInt64(vm.wire_count) * page
            s.compressed = UInt64(vm.compressor_page_count) * page
            s.cached = (UInt64(vm.external_page_count) + purgeable) * page
            let accounted = s.used + s.cached
            s.free = s.total > accounted ? s.total - accounted : 0
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            s.swapUsed = swap.xsu_used
            s.swapTotal = swap.xsu_total
        }
        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { s.pressureLevel = Int(level) }
        var avail: Int32 = 100
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &avail, &size, nil, 0) == 0 { s.availablePercent = Int(avail) }
        return s
    }
}

// MARK: - 프로세스

public struct ProcessGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let bundlePath: String?
    public let bundleID: String?
    public var pids: [pid_t]
    public var memory: UInt64
    public var cpuPercent: Double
    public let isApp: Bool
    public let isSystem: Bool
    public let note: ProcessNote?
    /// 이 앱이 실행한 가상머신이 차지한 메모리
    public var vmMemory: UInt64 = 0
    public var processCount: Int { pids.count }
}

public struct ProcessNote: Sendable {
    public let text: String
    public let canQuit: Bool
}

public final class ProcessSampler: @unchecked Sendable {
    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastTime: UInt64 = 0
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(max(1, tb.denom)))
    }()
    private var bundleCache: [String: (name: String, id: String?)] = [:]

    public init() {}

    /// 프로세스를 앱 단위로 묶어 메모리 사용량순으로 돌려준다. hidden = 권한 때문에 읽지 못한 프로세스 수
    public func sample() -> (groups: [ProcessGroup], hidden: Int) {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return ([], 0) }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return ([], 0) }
        pids = Array(pids.prefix(Int(got)))

        let now = mach_absolute_time()
        let wallNs = lastTime > 0 ? Double(now - lastTime) * Double(timebase.numer) / Double(timebase.denom) : 0
        var newCPU: [pid_t: UInt64] = [:]
        var groups: [String: ProcessGroup] = [:]
        var hidden = 0
        let me = getpid()

        for pid in pids where pid > 0 {
            var info = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if r != 0 { hidden += 1; continue }
            let footprint = info.ri_phys_footprint
            let cpuTicks = info.ri_user_time + info.ri_system_time
            newCPU[pid] = cpuTicks
            var cpu = 0.0
            if wallNs > 0, let prev = lastCPU[pid], cpuTicks >= prev {
                let ns = Double(cpuTicks - prev) * Double(timebase.numer) / Double(timebase.denom)
                cpu = ns / wallNs * 100
            }

            var pathBuf = [CChar](repeating: 0, count: 4096)
            let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = pathLen > 0 ? String(cString: pathBuf) : nil
            var pname = path.map(Paths.name) ?? ""
            if pname.isEmpty {
                var nameBuf = [CChar](repeating: 0, count: 256)
                proc_name(pid, &nameBuf, UInt32(nameBuf.count))
                pname = String(cString: nameBuf)
            }
            if pname.isEmpty { pname = "pid \(pid)" }

            // 가상머신·XPC 서비스는 실행을 요청한 앱(책임 프로세스) 밑으로 묶는다.
            var bundle = path.flatMap(Self.outerAppBundle)
            if bundle == nil || bundle!.hasPrefix("/System/Library/"), let resp = Self.responsiblePid(pid), resp != pid {
                var rbuf = [CChar](repeating: 0, count: 4096)
                if proc_pidpath(resp, &rbuf, UInt32(rbuf.count)) > 0, let rb = Self.outerAppBundle(String(cString: rbuf)),
                   !rb.hasPrefix("/System/Library/") {
                    bundle = rb
                }
            }
            let key: String
            let display: String
            var bundleID: String? = nil
            if let bundle {
                key = bundle
                if let c = bundleCache[bundle] { display = c.name; bundleID = c.id }
                else {
                    var nm = FileManager.default.displayName(atPath: bundle)
                    if nm.hasSuffix(".app") { nm.removeLast(4) }
                    let id = Bundle(path: bundle)?.bundleIdentifier
                    bundleCache[bundle] = (nm, id)
                    display = nm; bundleID = id
                }
            } else {
                key = "proc:\(pid)"
                display = pname
            }
            if var g = groups[key] {
                g.pids.append(pid); g.memory += footprint; g.cpuPercent += cpu
                if pname == "com.apple.Virtualization.VirtualMachine" { g.vmMemory += footprint }
                groups[key] = g
            } else {
                let userApp = bundle.map { $0.hasPrefix("/Applications/") || $0.hasPrefix("/System/Applications/") || $0.hasPrefix(Paths.home) } ?? false
                let isSystem = !userApp && ((path?.hasPrefix("/System/") ?? true) || (path?.hasPrefix("/usr/") ?? false) || (path?.hasPrefix("/sbin/") ?? false))
                let note = ProcessKnowledge.note(name: bundle != nil ? display : pname, path: path, isSystem: isSystem)
                groups[key] = ProcessGroup(id: key, name: display, bundlePath: bundle, bundleID: bundleID, pids: [pid],
                                           memory: footprint, cpuPercent: cpu, isApp: bundle != nil, isSystem: isSystem,
                                           note: pid == me ? ProcessNote(text: "이 앱(MacClean)입니다.", canQuit: false) : note,
                                           vmMemory: pname == "com.apple.Virtualization.VirtualMachine" ? footprint : 0)
            }
        }
        lastCPU = newCPU
        lastTime = now
        return (groups.values.sorted { $0.memory > $1.memory }, hidden)
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    static func responsiblePid(_ pid: pid_t) -> pid_t? {
        guard let f = responsibleFn else { return nil }
        let r = f(pid)
        return r > 0 ? r : nil
    }

    static func outerAppBundle(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}

public enum ProcessKnowledge {
    static let notes: [String: (String, Bool)] = [
        "kernel_task": ("macOS 커널입니다. 메모리를 많이 써도 정상이며 종료할 수 없습니다. 기기가 뜨거우면 일부러 CPU를 점유해 온도를 낮추기도 합니다.", false),
        "WindowServer": ("화면에 창을 그리는 시스템 프로세스입니다. 모니터가 많거나 해상도가 높고 창이 많을수록 메모리를 더 씁니다. 종료하면 로그아웃됩니다.", false),
        "launchd": ("모든 프로세스를 시작·관리하는 시스템의 뿌리 프로세스입니다.", false),
        "loginwindow": ("로그인 세션을 관리합니다. 종료하면 로그아웃됩니다.", false),
        "Finder": ("Finder입니다. 종료해도 자동으로 다시 실행됩니다.", true),
        "Dock": ("Dock과 Mission Control입니다. 종료해도 자동으로 다시 실행됩니다.", true),
        "mds": ("Spotlight 검색 색인 관리자입니다. 파일이 많이 바뀐 직후 잠시 바쁠 수 있습니다.", false),
        "mds_stores": ("Spotlight 검색 색인을 만드는 프로세스입니다. 큰 파일 복사·업데이트 후 잠시 바쁩니다.", false),
        "mdworker_shared": ("Spotlight가 파일 내용을 읽어 색인하는 작업자입니다.", false),
        "photoanalysisd": ("사진 앱의 얼굴·장면 분석입니다. 사진을 많이 가져온 뒤 한동안 바쁠 수 있습니다.", false),
        "mediaanalysisd": ("사진·동영상 분석(텍스트 인식 등)입니다. 일시적으로 바쁠 수 있습니다.", false),
        "backupd": ("Time Machine 백업 중입니다.", false),
        "bird": ("iCloud Drive 동기화를 담당합니다.", false),
        "cloudd": ("iCloud 동기화를 담당합니다.", false),
        "fileproviderd": ("iCloud·클라우드 파일 동기화를 담당합니다.", false),
        "softwareupdated": ("macOS 업데이트를 확인·다운로드합니다.", false),
        "XprotectService": ("macOS 기본 악성코드 검사입니다.", false),
        "syspolicyd": ("앱 실행 허가(Gatekeeper)를 검사합니다.", false),
        "coreaudiod": ("소리 출력·입력을 담당합니다.", false),
        "com.apple.WebKit.WebContent": ("Safari나 앱 안의 웹 페이지(탭) 하나입니다. 탭을 닫으면 사라집니다.", false),
        "com.apple.WebKit.GPU": ("Safari·WebKit의 그래픽 처리 프로세스입니다.", false),
        "com.apple.WebKit.Networking": ("Safari·WebKit의 네트워크 처리 프로세스입니다.", false),
        "com.apple.Virtualization.VirtualMachine": ("가상머신(Docker, UTM, Claude 등)이 실행 중입니다. 가상머신에 할당한 메모리를 통째로 차지합니다.", true),
        "node": ("Node.js 프로그램입니다 (개발 서버, 빌드 도구, 에디터 확장 등). 무엇을 실행 중인지 확인 후 종료하세요.", true),
        "python": ("Python 프로그램입니다.", true),
        "python3": ("Python 프로그램입니다.", true),
        "Python": ("Python 프로그램입니다.", true),
        "java": ("Java 프로그램입니다 (Gradle 데몬, IDE 등). Gradle 데몬은 종료해도 다음 빌드 때 다시 실행됩니다.", true),
        "qemu-system-aarch64": ("가상머신 에뮬레이터입니다 (Android 에뮬레이터 등).", true),
        "ollama": ("로컬 AI 모델 서버입니다. 모델을 불러오면 모델 크기만큼 메모리를 씁니다.", true),
        "SourceKitService": ("Xcode의 코드 분석 서비스입니다.", true),
        "sourcekit-lsp": ("Swift 코드 분석 서버입니다.", true),
        "swift-frontend": ("Swift 컴파일러입니다. 빌드가 끝나면 사라집니다.", true),
        "clang": ("C/C++ 컴파일러입니다. 빌드가 끝나면 사라집니다.", true),
    ]

    public static func note(name: String, path: String?, isSystem: Bool) -> ProcessNote? {
        if let n = notes[name] { return ProcessNote(text: n.0, canQuit: n.1) }
        let lower = name.lowercased()
        if lower.contains("chrome") || lower.contains("whale") || lower.contains("edge") || lower.contains("brave") || lower.contains("arc") {
            return ProcessNote(text: "브라우저입니다. 탭·확장마다 별도 프로세스가 생겨 합계가 큽니다. 안 쓰는 탭을 닫으면 줄어듭니다.", canQuit: true)
        }
        if lower == "code" || lower.contains("visual studio code") || lower == "cursor" {
            return ProcessNote(text: "코드 에디터입니다. 열린 창·확장·언어 서버가 메모리를 씁니다.", canQuit: true)
        }
        if lower.contains("docker") {
            return ProcessNote(text: "Docker Desktop입니다. 가상머신에 할당한 메모리를 차지합니다. 컨테이너를 안 쓰면 종료하세요.", canQuit: true)
        }
        if lower.contains("slack") || lower.contains("discord") || lower.contains("teams") || lower.contains("kakao") {
            return ProcessNote(text: "메신저입니다. 대화방·미디어를 많이 열어 둘수록 메모리를 더 씁니다.", canQuit: true)
        }
        if isSystem {
            return ProcessNote(text: "macOS 구성요소입니다. 필요할 때 시스템이 실행하고 관리합니다.", canQuit: false)
        }
        return nil
    }

    public static let critical: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow"]
}

// MARK: - 프로세스 종료

public enum ProcessControl {
    /// 앱이면 정상 종료 요청(저장 확인 대화상자 표시), 아니면 SIGTERM
    @MainActor
    public static func quit(_ g: ProcessGroup, force: Bool) -> Bool {
        if ProcessKnowledge.critical.contains(g.name) { return false }
        if let id = g.bundleID {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            if !apps.isEmpty {
                for app in apps {
                    if force { app.forceTerminate() } else { app.terminate() }
                }
                return true
            }
        }
        var ok = false
        for pid in g.pids where pid != getpid() {
            if kill(pid, force ? SIGKILL : SIGTERM) == 0 { ok = true }
        }
        return ok
    }

    /// 파일 캐시를 비우는 purge 명령 (관리자 암호 필요)
    public static func purge() -> (Bool, String) {
        let r = Shell.runAdmin("/usr/sbin/purge")
        return (r.status == 0, r.output)
    }
}
