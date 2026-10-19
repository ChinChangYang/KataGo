// PROTOTYPE (wayfinder #37), throwaway: refuse to measure on a busy machine.
//
// Readings, each over a 1 s window while this process sleeps:
//   - GPU "Device Utilization %" from every IOAccelerator's PerformanceStatistics (what `ioreg -r -c IOAccelerator`
//     prints). On the iPad, IOKit is reached through dlsym and may be sandboxed away; then it is reported as unread.
//   - CPU: system-wide busy cores from host_processor_info, minus this process; on the Mac also the top processes
//     (proc_pid_rusage deltas, what `top` shows).
//   - thermal state and Low Power Mode.
// The machine counts as idle when every readable figure is under its threshold and the thermal state is nominal.
import Darwin
import Foundation

struct IdleThresholds {
    var gpuPercent = 10.0       // max GPU device utilization
    var otherCores = 0.5        // max busy cores outside this process
    var topProcess = 0.25       // max cores of any one other process (Mac only)
}

final class IdleGate {
    let thresholds: IdleThresholds
    let allowBusy: Bool
    let waitSeconds: Double
    let pollSeconds: Double

    init(_ o: Options) {
        var t = IdleThresholds()
        if Platform.name == "iOS" { t.otherCores = 0.3 }
        t.gpuPercent = o.double("idle-gpu", t.gpuPercent)
        t.otherCores = o.double("idle-cores", t.otherCores)
        t.topProcess = o.double("idle-top", t.topProcess)
        thresholds = t
        allowBusy = o.has("allow-busy")
        waitSeconds = o.double("idle-wait", 300)
        pollSeconds = o.double("idle-poll", 10)
    }

    /// Blocks until idle; throws (refusing to measure) if it never is within `waitSeconds`, unless `--allow-busy`.
    @discardableResult
    func waitUntilIdle(context: String) throws -> JSON {
        let t0 = Date()
        while true {
            let r = IdleReading.take()
            let problems = r.problems(thresholds)
            if problems.isEmpty {
                log("idle check (\(context)): idle. \(r.summary)")
                return r.json(problems)
            }
            if allowBusy {
                log("idle check (\(context)): BUSY, measuring anyway (--allow-busy): \(problems.joined(separator: "; ")). \(r.summary)")
                return r.json(problems)
            }
            if Date().timeIntervalSince(t0) >= waitSeconds {
                log("idle check (\(context)): REFUSED after \(Int(waitSeconds)) s: \(problems.joined(separator: "; ")). \(r.summary)")
                throw HarnessError("machine not idle: \(problems.joined(separator: "; "))")
            }
            log("idle check (\(context)): waiting: \(problems.joined(separator: "; "))")
            Thread.sleep(forTimeInterval: pollSeconds)
        }
    }
}

struct IdleReading {
    var gpuPercent: Double?
    var otherCores: Double
    var top: [(name: String, cores: Double)]
    var thermal: ProcessInfo.ThermalState
    var lowPower: Bool

    static func take() -> IdleReading {
        let cpu0 = systemBusyTicks(), self0 = selfCPUSeconds(), procs0 = processTimes(), w0 = nowNs()
        Thread.sleep(forTimeInterval: 1.0)
        let cpu1 = systemBusyTicks(), self1 = selfCPUSeconds(), procs1 = processTimes(), w1 = nowNs()
        let wall = Double(w1 - w0) / 1e9
        var busyCores = 0.0
        if let a = cpu0, let b = cpu1, b.total > a.total {
            busyCores = Double(b.busy - a.busy) / Double(b.total - a.total) * Double(b.cpus)
        }
        let others = max(0, busyCores - (self1 - self0) / wall)
        var top: [(String, Double)] = []
        let me = getpid()
        for (pid, t1) in procs1 where pid != me {
            if let t0 = procs0[pid], t1.ns > t0.ns { top.append((t1.name, Double(t1.ns - t0.ns) / 1e9 / wall)) }
        }
        top.sort { $0.1 > $1.1 }
        return IdleReading(gpuPercent: gpuUtilization(), otherCores: others, top: Array(top.prefix(5)),
                           thermal: ProcessInfo.processInfo.thermalState,
                           lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    func problems(_ t: IdleThresholds) -> [String] {
        var p: [String] = []
        if let g = gpuPercent, g > t.gpuPercent { p.append("GPU \(fmt(g, 3))% > \(fmt(t.gpuPercent, 3))%") }
        if otherCores > t.otherCores { p.append("other processes use \(fmt(otherCores, 2)) cores > \(fmt(t.otherCores, 2))") }
        if let first = top.first, first.cores > t.topProcess {
            p.append("\(first.name) uses \(fmt(first.cores, 2)) cores > \(fmt(t.topProcess, 2))")
        }
        if thermal != .nominal { p.append("thermal state \(thermalName(thermal))") }
        if lowPower { p.append("Low Power Mode on") }
        return p
    }

    var summary: String {
        let g = gpuPercent.map { "\(fmt($0, 3))%" } ?? "unread"
        let t = top.prefix(3).map { "\($0.name) \(fmt($0.cores, 2))" }.joined(separator: ", ")
        return "GPU \(g), other cores \(fmt(otherCores, 2))\(t.isEmpty ? "" : " (top: \(t))"), thermal \(thermalName(thermal)), low power \(lowPower)"
    }

    func json(_ problems: [String]) -> JSON {
        var j: JSON = ["otherCores": otherCores, "thermal": thermalName(thermal), "lowPower": lowPower,
                       "top": top.map { ["name": $0.name, "cores": $0.cores] }, "problems": problems, "time": isoNow()]
        if let g = gpuPercent { j["gpuPercent"] = g }
        return j
    }
}

private func systemBusyTicks() -> (busy: UInt64, total: UInt64, cpus: Int)? {
    var count: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
          let info else { return nil }
    defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
    var busy: UInt64 = 0, total: UInt64 = 0
    for c in 0..<Int(count) {
        let base = c * Int(CPU_STATE_MAX)
        let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
        let sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
        let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
        busy += user + sys + nice
        total += user + sys + nice + idle
    }
    return (busy, total, Int(count))
}

private func selfCPUSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

#if os(macOS)
private func processTimes() -> [pid_t: (name: String, ns: UInt64)] {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [:] }
    var pids = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var out: [pid_t: (String, UInt64)] = [:]
    for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
        var ri = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard ok == 0 else { continue }
        var nameBuf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        let ticks = ri.ri_user_time + ri.ri_system_time
        out[pid] = (String(cString: nameBuf), ticks * UInt64(tb.numer) / UInt64(tb.denom))
    }
    return out
}
#else
private func processTimes() -> [pid_t: (name: String, ns: UInt64)] { [:] }  // other processes are invisible on iOS
#endif

// MARK: - IOKit, through dlsym so the same code builds for iOS (whose SDK has no IOKit headers)

private typealias IOServiceMatchingFn = @convention(c) (UnsafePointer<CChar>) -> Unmanaged<CFMutableDictionary>?
private typealias IOServiceGetMatchingServicesFn = @convention(c) (UInt32, CFDictionary, UnsafeMutablePointer<UInt32>) -> Int32
private typealias IOIteratorNextFn = @convention(c) (UInt32) -> UInt32
private typealias IORegistryEntryCreateCFPropertyFn = @convention(c) (UInt32, CFString, CFAllocator?, UInt32) -> Unmanaged<CFTypeRef>?
private typealias IOObjectReleaseFn = @convention(c) (UInt32) -> Int32

func gpuUtilization() -> Double? {
    guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
          let m = dlsym(h, "IOServiceMatching"), let g = dlsym(h, "IOServiceGetMatchingServices"),
          let nx = dlsym(h, "IOIteratorNext"), let p = dlsym(h, "IORegistryEntryCreateCFProperty"),
          let rel = dlsym(h, "IOObjectRelease") else { return nil }
    let matching = unsafeBitCast(m, to: IOServiceMatchingFn.self)
    let getServices = unsafeBitCast(g, to: IOServiceGetMatchingServicesFn.self)
    let next = unsafeBitCast(nx, to: IOIteratorNextFn.self)
    let prop = unsafeBitCast(p, to: IORegistryEntryCreateCFPropertyFn.self)
    let release = unsafeBitCast(rel, to: IOObjectReleaseFn.self)
    // IOServiceGetMatchingServices consumes the +1 reference IOServiceMatching returns.
    guard let dict = matching("IOAccelerator")?.takeUnretainedValue() else { return nil }
    var iter: UInt32 = 0
    guard getServices(0, dict, &iter) == 0 else { return nil }
    defer { _ = release(iter) }
    var best: Double?
    while case let entry = next(iter), entry != 0 {
        defer { _ = release(entry) }
        guard let stats = prop(entry, "PerformanceStatistics" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any],
              let u = stats["Device Utilization %"] as? NSNumber else { continue }
        best = max(best ?? 0, u.doubleValue)
    }
    return best
}
