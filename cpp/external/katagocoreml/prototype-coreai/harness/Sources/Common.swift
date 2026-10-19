// PROTOTYPE (wayfinder #37), throwaway: shared plumbing for the stage 1 harness (Mac CLI and iPad app).
import Foundation

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Where compiled Core ML models are kept between runs (`--cache`; never inside the results directory).
nonisolated(unsafe) var cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("coreai-gate")

/// Monotonic nanoseconds.
@inline(__always) func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// Everything goes to stdout, flushed per line: on the iPad that stream is what `devicectl --console` relays.
nonisolated(unsafe) var logSink: ((String) -> Void)? = nil
func log(_ s: String) {
    print(s)
    fflush(stdout)
    logSink?(s)
}

func fmt(_ v: Double, _ digits: Int = 3) -> String {
    if v.isNaN { return "nan" }
    if v.isInfinite { return v > 0 ? "inf" : "-inf" }
    let a = abs(v)
    if a != 0 && (a < 1e-3 || a >= 1e6) { return String(format: "%.\(digits)e", v) }
    return String(format: "%.\(digits)g", v)
}

func pct(_ v: Double) -> String { String(format: "%.2f%%", v * 100) }

enum Platform {
#if os(iOS)
    static let name = "iOS"
#else
    static let name = "macOS"
#endif
}

func machineModel() -> String {
    var size = 0
    let key = Platform.name == "iOS" ? "hw.machine" : "hw.model"
    sysctlbyname(key, nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname(key, &buf, &size, nil, 0)
    return String(cString: buf)
}

func osBuild() -> String {
    var size = 0
    sysctlbyname("kern.osversion", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("kern.osversion", &buf, &size, nil, 0)
    return String(cString: buf)
}

func thermalName(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

/// Command-line options: `--key value` pairs and bare `--flag`s.
struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    values[key] = args[i + 1]; i += 2; continue
                }
                flags.insert(key)
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func string(_ k: String, _ d: String) -> String { values[k] ?? d }
    func int(_ k: String, _ d: Int) -> Int { values[k].flatMap(Int.init) ?? d }
    func double(_ k: String, _ d: Double) -> Double { values[k].flatMap(Double.init) ?? d }
    func ints(_ k: String, _ d: [Int]) -> [Int] {
        guard let v = values[k] else { return d }
        return v.split(separator: ",").compactMap { Int($0) }
    }
    func has(_ k: String) -> Bool { flags.contains(k) || values[k] != nil }
}

/// A JSON-able result tree.
typealias JSON = [String: Any]

func writeJSON(_ obj: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func timestamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}

func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }

// MARK: - Statistics

func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// Linear-interpolated percentile, p in [0, 100], of an already sorted array.
func percentileSorted(_ s: [Double], _ p: Double) -> Double {
    guard !s.isEmpty else { return .nan }
    if s.count == 1 { return s[0] }
    let r = p / 100 * Double(s.count - 1)
    let lo = Int(r.rounded(.down)), hi = min(lo + 1, s.count - 1)
    return s[lo] + (s[hi] - s[lo]) * (r - Double(lo))
}

func mean(_ xs: [Double]) -> Double { xs.isEmpty ? .nan : xs.reduce(0, +) / Double(xs.count) }

// MARK: - Positions (parity_<board>/ from export_assets.py)

struct Positions {
    let board: Int
    let labels: [String]
    let count: Int
    let spatial: [Float]   // [n, C, H, W]
    let global: [Float]    // [n, G]
    let mask: [Float]      // [n, 1, H, W]
    let refs: [String: [Float]]
    let shapes: [String: [Int]]
    var numSpatial: Int { shapes["spatial_input"]![1] }
    var numGlobal: Int { shapes["global_input"]![1] }

    init(dir: URL) throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) as! JSON
        labels = manifest["labels"] as! [String]
        let arrays = manifest["arrays"] as! [String: [Int]]
        shapes = arrays
        func load(_ name: String) throws -> [Float] {
            let d = try Data(contentsOf: dir.appendingPathComponent("\(name).f32"))
            return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        spatial = try load("spatial_input")
        global = try load("global_input")
        mask = try load("input_mask")
        var r: [String: [Float]] = [:]
        for h in Heads.all { r[h] = try load("ref_\(h)") }
        refs = r
        count = labels.count
        board = arrays["spatial_input"]![2]
    }
}

enum Heads {
    static let policy = "policy_p2_conv"
    static let pass = "policy_pass"
    static let value = "value_v3_bias"
    static let score = "value_sv3_bias"
    static let ownership = "value_ownership_conv"
    static let all = [policy, pass, value, score, ownership]
}

/// Batch buffers shaped like the C++ NN server thread's: row-major, one row per position.
final class RowBuffers: @unchecked Sendable {
    let rows: Int
    let board: Int
    let numSpatial: Int, numGlobal: Int
    let outSizes: [String: Int]   // per row
    var spatial: UnsafeMutablePointer<Float>
    var global: UnsafeMutablePointer<Float>
    var meta: UnsafeMutablePointer<Float>
    var mask: UnsafeMutablePointer<Float>
    var outs: [String: UnsafeMutablePointer<Float>] = [:]

    init(rows: Int, board: Int, numSpatial: Int, numGlobal: Int, outSizes: [String: Int]) {
        self.rows = rows; self.board = board; self.numSpatial = numSpatial; self.numGlobal = numGlobal
        self.outSizes = outSizes
        let area = board * board
        spatial = .allocate(capacity: rows * numSpatial * area); spatial.initialize(repeating: 0, count: rows * numSpatial * area)
        global = .allocate(capacity: rows * numGlobal); global.initialize(repeating: 0, count: rows * numGlobal)
        meta = .allocate(capacity: 1); meta.initialize(to: 0)
        mask = .allocate(capacity: rows * area); mask.initialize(repeating: 0, count: rows * area)
        for (k, n) in outSizes {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: rows * n)
            p.initialize(repeating: 0, count: rows * n)
            outs[k] = p
        }
    }

    /// Fill row r with position i.
    func load(row r: Int, from pos: Positions, index i: Int) {
        let area = board * board
        pos.spatial.withUnsafeBufferPointer { s in
            (spatial + r * numSpatial * area).update(from: s.baseAddress! + i * numSpatial * area, count: numSpatial * area)
        }
        pos.global.withUnsafeBufferPointer { g in
            (global + r * numGlobal).update(from: g.baseAddress! + i * numGlobal, count: numGlobal)
        }
        pos.mask.withUnsafeBufferPointer { m in
            (mask + r * area).update(from: m.baseAddress! + i * area, count: area)
        }
    }

    func output(_ head: String, row r: Int) -> [Float] {
        let n = outSizes[head]!
        return Array(UnsafeBufferPointer(start: outs[head]! + r * n, count: n))
    }

    deinit {
        spatial.deallocate(); global.deallocate(); meta.deallocate(); mask.deallocate()
        for p in outs.values { p.deallocate() }
    }
}

/// Copy a strided tensor (any rank) into a contiguous destination, row-major.
func copyStrided(from src: UnsafePointer<Float>, shape: [Int], strides: [Int], to dst: UnsafeMutablePointer<Float>) {
    let rank = shape.count
    var contiguous = true
    var expect = 1
    for i in stride(from: rank - 1, through: 0, by: -1) {
        if shape[i] != 1 && strides[i] != expect { contiguous = false; break }
        expect *= shape[i]
    }
    let total = shape.reduce(1, *)
    if contiguous { dst.update(from: src, count: total); return }
    var idx = [Int](repeating: 0, count: rank)
    for n in 0..<total {
        var off = 0
        for d in 0..<rank { off += idx[d] * strides[d] }
        dst[n] = src[off]
        var d = rank - 1
        while d >= 0 { idx[d] += 1; if idx[d] < shape[d] { break }; idx[d] = 0; d -= 1 }
    }
}

/// Copy a contiguous source into a strided destination tensor.
func copyIntoStrided(from src: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, shape: [Int], strides: [Int]) {
    let rank = shape.count
    var contiguous = true
    var expect = 1
    for i in stride(from: rank - 1, through: 0, by: -1) {
        if shape[i] != 1 && strides[i] != expect { contiguous = false; break }
        expect *= shape[i]
    }
    let total = shape.reduce(1, *)
    if contiguous { dst.update(from: src, count: total); return }
    var idx = [Int](repeating: 0, count: rank)
    for n in 0..<total {
        var off = 0
        for d in 0..<rank { off += idx[d] * strides[d] }
        dst[off] = src[n]
        var d = rank - 1
        while d >= 0 { idx[d] += 1; if idx[d] < shape[d] { break }; idx[d] = 0; d -= 1 }
    }
}

func contiguousStrides(_ shape: [Int]) -> [Int] {
    var s = [Int](repeating: 1, count: shape.count)
    var acc = 1
    for i in stride(from: shape.count - 1, through: 0, by: -1) { s[i] = acc; acc *= shape[i] }
    return s
}

/// Elements a strided tensor spans.
func spanElements(_ shape: [Int], _ strides: [Int]) -> Int {
    var m = 0
    for i in 0..<shape.count { m += (shape[i] - 1) * strides[i] }
    return m + 1
}

/// Runs blocking measurement code on a plain thread, the way KataGo's NN server threads are plain C++ threads, and
/// keeps it off Swift's cooperative pool (which the measured TaskGroup children use).
func onDedicatedThread<T>(_ body: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
        let t = Thread {
            do { c.resume(returning: try body()) } catch { c.resume(throwing: error) }
        }
        t.qualityOfService = .userInitiated
        t.stackSize = 8 << 20
        t.start()
    }
}

/// Rethrows with a label, so an error that carries no description of its own (Foundation's `nilError`) says where it
/// came from.
func step<T>(_ label: String, _ body: () throws -> T) throws -> T {
    do { return try body() } catch let e as HarnessError { throw e } catch { throw HarnessError("\(label): \(error)") }
}
func step<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch let e as HarnessError { throw e } catch { throw HarnessError("\(label): \(error)") }
}
