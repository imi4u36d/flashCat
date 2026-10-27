import Foundation

// MARK: - Identity

/// The inference backends flashCat can drive. Each one is a peer: its own
/// runtime installation, port, log file, model directory and status schema.
public enum EngineID: String, Codable, CaseIterable, Identifiable, Sendable {
    case splash
    case omlx
    case mtplx

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .splash: return "Splash"
        case .omlx: return "oMLX"
        case .mtplx: return "MTPLX"
        }
    }

    /// Fixed port bands keep the three engines from fighting over one port and
    /// stay clear of the defaults the upstream apps use (oMLX 8099, MTPLX 8000).
    public var defaultPort: Int {
        switch self {
        case .splash: return 8000
        case .omlx: return 8100
        case .mtplx: return 8200
        }
    }

    public var portRange: ClosedRange<Int> {
        defaultPort...(defaultPort + 19)
    }

    /// Startup budget. MTPLX re-warms its Metal kernels for every model load,
    /// oMLX paged-weights takes a while, splash can pull from the hub.
    public var startupTimeout: TimeInterval {
        switch self {
        case .splash: return 300
        case .omlx: return 180
        case .mtplx: return 300
        }
    }

    public var switchMode: ModelSwitchMode {
        switch self {
        case .omlx: return .hot
        case .splash, .mtplx: return .restart
        }
    }

    public var capabilities: Set<EngineCapability> {
        switch self {
        case .splash:
            return [.chat, .streaming, .vision, .reasoning, .singleModel, .draft]
        case .omlx:
            return [.chat, .streaming, .vision, .reasoning, .multiModel, .hotLoad, .hotUnload, .modelRescan]
        case .mtplx:
            return [.chat, .streaming, .vision, .reasoning, .singleModel, .mtp]
        }
    }
}

public enum EngineCapability: String, Codable, Hashable, Sendable {
    case chat
    case streaming
    case vision
    case reasoning
    case multiModel
    case hotLoad
    case hotUnload
    case modelRescan
    case singleModel
    case draft
    case mtp

    /// Short label for the console UI; the manifest only carries the raw token.
    public var displayName: String {
        switch self {
        case .chat: return "对话"
        case .streaming: return "流式"
        case .vision: return "视觉"
        case .reasoning: return "推理"
        case .multiModel: return "多模型"
        case .hotLoad: return "热加载"
        case .hotUnload: return "热卸载"
        case .modelRescan: return "模型重扫"
        case .singleModel: return "单模型"
        case .draft: return "DFlash2"
        case .mtp: return "MTP"
        }
    }

    /// Decoding an unknown capability must not fail the whole manifest: a pack
    /// built by a newer flashCat may advertise something this build predates.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EngineCapability(rawValue: raw) ?? .chat
    }
}

public enum EnginePackKind: String, Codable, Sendable {
    case bundled
    case download
}

/// How a launch profile wants the model handed to it: oMLX indexes by directory
/// name, MTPLX expects a path, splash's own serve script names the model itself.
public enum EngineModelArgument: String, Codable, Sendable {
    case name
    case path
    case id

    /// A pack built by a newer flashCat may name a style this build predates;
    /// falling back to `name` keeps the engine launchable instead of failing.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EngineModelArgument(rawValue: raw) ?? .name
    }
}

public enum ModelSwitchMode: String, Codable, Sendable {
    /// Swap the `model` field per request; no process restart.
    case hot
    /// Stop the process, relaunch with a different `--model`.
    case restart
}

public enum EngineRunState: String, Codable, Sendable {
    case stopped
    case starting
    case loading
    case ready
    case stopping
    case failed
}

// MARK: - Manifest

public struct EngineHealthSpec: Codable, Sendable {
    public let path: String
    public let readyStatus: Int
    public let loadingStatus: Int?

    public init(path: String, readyStatus: Int = 200, loadingStatus: Int? = nil) {
        self.path = path
        self.readyStatus = readyStatus
        self.loadingStatus = loadingStatus
    }
}

public struct EngineModelsSpec: Codable, Sendable {
    public let path: String

    public init(path: String) { self.path = path }
}

public struct EngineLaunchProfile: Codable, Sendable {
    public let args: [String]
    public let environment: [String: String]?

    public init(args: [String], environment: [String: String]? = nil) {
        self.args = args
        self.environment = environment
    }
}

public struct EngineManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let id: EngineID
    public let name: String
    public let version: String
    public let kind: EnginePackKind
    public let arch: String
    public let minMacOS: String
    public let minAppVersion: String?
    public let entrypoint: String
    public let workingDirectory: String?
    public let modelsSubdirectory: String?
    public let launchProfiles: [String: EngineLaunchProfile]
    public let health: EngineHealthSpec
    public let status: [String]?
    public let models: EngineModelsSpec?
    public let defaultPort: Int
    public let modelSwitch: ModelSwitchMode
    /// Optional so manifests written before this key existed still decode.
    public let modelArgument: EngineModelArgument?
    public let capabilities: [EngineCapability]
    public let license: String?

    public init(schemaVersion: Int = 1,
                id: EngineID,
                name: String,
                version: String,
                kind: EnginePackKind,
                arch: String = "arm64",
                minMacOS: String = "14.0",
                minAppVersion: String? = nil,
                entrypoint: String,
                workingDirectory: String? = nil,
                modelsSubdirectory: String? = nil,
                launchProfiles: [String: EngineLaunchProfile],
                health: EngineHealthSpec,
                status: [String]? = nil,
                models: EngineModelsSpec? = nil,
                defaultPort: Int,
                modelSwitch: ModelSwitchMode,
                modelArgument: EngineModelArgument? = nil,
                capabilities: [EngineCapability],
                license: String? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.kind = kind
        self.arch = arch
        self.minMacOS = minMacOS
        self.minAppVersion = minAppVersion
        self.entrypoint = entrypoint
        self.workingDirectory = workingDirectory
        self.modelsSubdirectory = modelsSubdirectory
        self.launchProfiles = launchProfiles
        self.health = health
        self.status = status
        self.models = models
        self.defaultPort = defaultPort
        self.modelSwitch = modelSwitch
        self.modelArgument = modelArgument
        self.capabilities = capabilities
        self.license = license
    }

    public var capabilitySet: Set<EngineCapability> { Set(capabilities) }

    public var modelArgumentStyle: EngineModelArgument { modelArgument ?? .name }
}

// MARK: - Installation

public struct EngineInstallation: Sendable {
    public let id: EngineID
    public let manifest: EngineManifest
    public let root: URL

    public init(id: EngineID, manifest: EngineManifest, root: URL) {
        self.id = id
        self.manifest = manifest
        self.root = root
    }

    public var entrypoint: URL {
        root.appendingPathComponent(manifest.entrypoint)
    }

    public var version: String { manifest.version }

    public static func manifestURL(root: URL) -> URL {
        root.appendingPathComponent("manifest.json")
    }

    /// Read a pack manifest off disk. Tolerant: a broken manifest yields nil so
    /// the engine page can show "damaged install" instead of crashing.
    public static func load(root: URL) -> EngineInstallation? {
        guard let data = try? Data(contentsOf: manifestURL(root: root)),
              let manifest = try? JSONDecoder().decode(EngineManifest.self, from: data) else {
            return nil
        }
        return EngineInstallation(id: manifest.id, manifest: manifest, root: root)
    }
}

// MARK: - Template expansion

/// Launch profiles carry `{root}`, `{port}` … placeholders so a pack can
/// describe its command line without knowing where flashCat put it.
public enum EngineTemplate {
    public static func expand(_ value: String, context: [String: String]) -> String {
        var result = value
        for (key, replacement) in context {
            result = result.replacingOccurrences(of: "{\(key)}", with: replacement)
        }
        return result
    }

    public static func expand(_ values: [String], context: [String: String]) -> [String] {
        values.map { expand($0, context: context) }
    }

    /// Placeholders left in the result mean the profile asked for something the
    /// caller did not supply (usually `{model}` before a model is picked).
    public static func unresolvedPlaceholders(_ values: [String]) -> [String] {
        var found: [String] = []
        for value in values {
            for match in matches(in: value) where !found.contains(match) {
                found.append(match)
            }
        }
        return found
    }

    private static func matches(in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: "\\{[a-zA-Z][a-zA-Z0-9_]*\\}") else {
            return []
        }
        let range = NSRange(location: 0, length: value.utf16.count)
        return expression.matches(in: value, options: [], range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: value) else { return nil }
            return String(value[swiftRange])
        }
    }
}

// MARK: - Version comparison

public enum EngineVersionOrder {
    /// Numeric-aware comparison ("0.7.10" > "0.7.2") that does not choke on
    /// pre-release suffixes: anything after `-` sorts below the bare release.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = split(lhs)
        let right = split(rhs)
        for index in 0..<max(left.numbers.count, right.numbers.count) {
            let a = index < left.numbers.count ? left.numbers[index] : 0
            let b = index < right.numbers.count ? right.numbers[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        if left.isPrerelease != right.isPrerelease {
            return left.isPrerelease ? .orderedAscending : .orderedDescending
        }
        return left.suffix.compare(right.suffix)
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    private static func split(_ value: String) -> (numbers: [Int], isPrerelease: Bool, suffix: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = String(parts.first ?? "")
        let suffix = parts.count > 1 ? String(parts[1]) : ""
        var numbers: [Int] = []
        for piece in core.split(whereSeparator: { $0 == "." || $0 == "_" }) {
            let digits = piece.prefix { $0.isNumber }
            numbers.append(Int(digits) ?? 0)
        }
        return (numbers, !suffix.isEmpty, suffix)
    }
}

// MARK: - Ports

public enum EnginePortAllocator {
    /// Pick the first free port at or above the requested one. `taken` is what
    /// the app itself is already using for other engines; `isOpen` reports
    /// whether a foreign process is listening. A custom preferred port moves the
    /// whole band instead of being ignored, which is what the settings page
    /// implies when it lets the reader type a port.
    public static func allocate(for engine: EngineID,
                                preferred: Int?,
                                taken: Set<Int>,
                                isOpen: (Int) -> Bool) -> Int? {
        let start = max(1024, min(preferred ?? engine.defaultPort, 65535))
        let band = Array(start...min(start + engine.portRange.count - 1, 65535))
        for candidate in band where !taken.contains(candidate) && !isOpen(candidate) {
            return candidate
        }
        return nil
    }
}
