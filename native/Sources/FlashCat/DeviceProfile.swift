import Foundation

/// How well one suggestion fits the machine flashCat runs on.
enum DeviceFit: Int {
    /// Memory floor is met and the weights fit on disk.
    case good
    /// Not enough facts (Hub page states neither size nor memory floor).
    case unknown
    /// The pack wants more unified memory than this Mac has.
    case tight
    /// The download is bigger than the free disk space.
    case diskShort
}

/// What the model page knows about this Mac, so its suggestions carry a
/// "fits / does not fit" verdict instead of raw numbers only.
struct DeviceProfile: Equatable {
    let chipName: String
    let memoryGB: Int
    let freeDiskBytes: Int64

    static func current() -> DeviceProfile {
        DeviceProfile(chipName: chipName(),
                      memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
                      freeDiskBytes: freeDiskBytes())
    }

    /// `machdep.cpu.brand_string` — "Apple M4 Pro" and friends.
    private static func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Apple Silicon" : name
    }

    private static func freeDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        var stat = statfs()
        if statfs(NSHomeDirectory(), &stat) == 0 {
            return Int64(stat.f_bavail) * Int64(stat.f_bsize)
        }
        return 0
    }

    /// One line for the page: chip, memory, free disk.
    var summary: String {
        var parts = [chipName, "\(memoryGB) GB 统一内存"]
        if freeDiskBytes > 0 { parts.append("可用 " + Format.size(Int(freeDiskBytes))) }
        return parts.joined(separator: " · ")
    }

    func fit(_ recommendation: ModelRecommendation) -> DeviceFit {
        fit(bytes: recommendation.bytes, minimumMemory: recommendation.minimumMemory)
    }

    func fit(bytes: Int, minimumMemory: Int) -> DeviceFit {
        guard bytes > 0 || minimumMemory > 0 else { return .unknown }
        if bytes > 0, freeDiskBytes > 0, Int64(bytes) > freeDiskBytes { return .diskShort }
        if minimumMemory > 0, minimumMemory > memoryGB { return .tight }
        return .good
    }
}
