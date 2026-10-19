// PROTOTYPE (wayfinder #37), throwaway: energy counters, where the device exposes them (recorded, never gating).
//
// The SoC's "Energy Model" IOReport channels (CPU, GPU, ANE, DRAM energy) come through the private libIOReport, the
// source `powermetrics` reads. Only categories whose counters move during a probe of busy work are kept: on macOS 27,
// an unprivileged process reads 0 from every channel but GPU, so ANE energy needs the harness run as root
// (`stage1.sh` does that for the power mode when SUDO_POWER=1). On iOS the library may be missing or sandboxed; then
// `make()` returns nil and power is reported as not exposed.
import Foundation

private typealias CopyChannelsInGroupFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
private typealias CreateSubscriptionFn = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
private typealias CreateSamplesFn = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias CreateSamplesDeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias ChannelStringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
private typealias SimpleIntegerFn = @convention(c) (CFDictionary, Int32) -> Int64

final class PowerSampler {
    private let sub: OpaquePointer
    private let subbed: CFMutableDictionary
    private let createSamples: CreateSamplesFn
    private let createDelta: CreateSamplesDeltaFn
    private let channelName: ChannelStringFn
    private let unitLabel: ChannelStringFn
    private let integer: SimpleIntegerFn
    private(set) var channels: [String] = []
    private(set) var unread: [String] = []

    static func make() -> PowerSampler? {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
        guard let copy = sym("IOReportCopyChannelsInGroup", CopyChannelsInGroupFn.self),
              let create = sym("IOReportCreateSubscription", CreateSubscriptionFn.self),
              let samples = sym("IOReportCreateSamples", CreateSamplesFn.self),
              let delta = sym("IOReportCreateSamplesDelta", CreateSamplesDeltaFn.self),
              let name = sym("IOReportChannelGetChannelName", ChannelStringFn.self),
              let unit = sym("IOReportChannelGetUnitLabel", ChannelStringFn.self),
              let integer = sym("IOReportSimpleGetIntegerValue", SimpleIntegerFn.self),
              let chans = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, chans) else { return nil }
        var subbedOut: Unmanaged<CFMutableDictionary>?
        guard let s = create(nil, mutable, &subbedOut, 0, nil), let subbed = subbedOut?.takeRetainedValue() else { return nil }
        let p = PowerSampler(sub: s, subbed: subbed, createSamples: samples, createDelta: delta, channelName: name,
                             unitLabel: unit, integer: integer)
        guard let probe = p.sample() else { return nil }
        var spin = 0.0
        let t0 = nowNs()
        while nowNs() - t0 < 300_000_000 { spin += sin(spin) + 1 }  // keep a core busy so CPU energy has to move
        let d = p.delta(since: probe)
        p.channels = d.filter { $0.value > 0 }.keys.sorted()
        p.unread = d.filter { $0.value <= 0 }.keys.sorted()
        if spin == 0 { log("") }
        return p.channels.isEmpty ? nil : p
    }

    private init(sub: OpaquePointer, subbed: CFMutableDictionary, createSamples: CreateSamplesFn,
                 createDelta: CreateSamplesDeltaFn, channelName: ChannelStringFn, unitLabel: ChannelStringFn,
                 integer: SimpleIntegerFn) {
        self.sub = sub; self.subbed = subbed; self.createSamples = createSamples; self.createDelta = createDelta
        self.channelName = channelName; self.unitLabel = unitLabel; self.integer = integer
    }

    var describe: String {
        "IOReport Energy Model: reads \(channels.joined(separator: ", "))"
            + (unread.isEmpty ? "" : "; reads 0 for \(unread.joined(separator: ", ")) (needs root on macOS 27)")
    }

    func sample() -> CFDictionary? { createSamples(sub, subbed, nil)?.takeRetainedValue() }

    /// Joules since `prev`, summed into CPU, GPU, ANE and DRAM.
    func delta(since prev: CFDictionary) -> [String: Double] {
        guard let cur = sample(), let d = createDelta(prev, cur, nil)?.takeRetainedValue(),
              let items = (d as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return [:] }
        var out: [String: Double] = [:]
        for ch in items {
            let cf = ch as CFDictionary
            guard let name = channelName(cf)?.takeUnretainedValue() as String? else { continue }
            let unit = (unitLabel(cf)?.takeUnretainedValue() as String?) ?? ""
            let scale: Double
            switch unit.trimmingCharacters(in: .whitespaces) {
            case "mJ": scale = 1e-3
            case "uJ", "µJ": scale = 1e-6
            case "nJ": scale = 1e-9
            default: continue
            }
            let key: String
            if name == "CPU Energy" { key = "CPU" }
            else if name == "GPU Energy" { key = "GPU" }
            else if name.hasPrefix("ANE") { key = "ANE" }
            else if name.hasPrefix("DRAM") { key = "DRAM" }
            else { continue }
            out[key, default: 0] += Double(integer(cf, 0)) * scale
        }
        if !channels.isEmpty { out = out.filter { channels.contains($0.key) } }
        return out
    }
}
