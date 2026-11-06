import Foundation

// MARK: - Open enums

/// Capabilities are open tokens rather than a closed enum. A newer pack can
/// advertise a feature this build does not render yet without making the pack
/// undecodable.
public struct EngineCapability: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases = [
            "multimodel": "multi-model",
            "hotload": "hot-load",
            "hotunload": "hot-unload",
            "modelrescan": "model-rescan",
            "singlemodel": "single-model",
            "tooluse": "tool-use",
        ]
        self.rawValue = aliases[normalized] ?? normalized
    }

    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let chat = EngineCapability("chat")
    public static let streaming = EngineCapability("streaming")
    public static let vision = EngineCapability("vision")
    public static let reasoning = EngineCapability("reasoning")
    public static let multiModel = EngineCapability("multi-model")
    public static let hotLoad = EngineCapability("hot-load")
    public static let hotUnload = EngineCapability("hot-unload")
    public static let modelRescan = EngineCapability("model-rescan")
    public static let singleModel = EngineCapability("single-model")
    public static let draft = EngineCapability("draft")
    public static let mtp = EngineCapability("mtp")
    public static let toolUse = EngineCapability("tool-use")
    public static let serial = EngineCapability("serial")

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
        case .toolUse: return "工具调用"
        case .serial: return "仅支持串行"
        default: return rawValue.replacingOccurrences(of: "-", with: " ")
        }
    }
}

/// Identifies the small compiled adapter used for lifecycle differences that
/// cannot be expressed by the manifest. Unknown adapters fall back to the
/// generic manifest-driven adapter.
public struct EngineAdapterID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let standard = EngineAdapterID("standard")
    public static let splash = EngineAdapterID("splash")
    public static let omlx = EngineAdapterID("omlx")
    public static let mtplx = EngineAdapterID("mtplx")
    public static let mlxServe = EngineAdapterID("mlx-serve")
    public static let strata = EngineAdapterID("strata")
}

public enum EngineModelLayout: String, Codable, Sendable {
    /// `<models>/<owner--repo>`.
    case flat
    /// Hugging Face layout: `<models>/<owner>/<repo>`.
    case nested
    /// The engine owns its model store and only exposes model ids.
    case external
}

public enum EngineTelemetryRole: String, Codable, Sendable {
    case health
    case status
    case inventory
    case metrics
    case props
}

public enum EngineTelemetryFormat: String, Codable, Sendable {
    case splashStatus = "splash.status"
    case omlxStatus = "omlx.status"
    case omlxModels = "omlx.models"
    case mtplxSnapshot = "mtplx.snapshot"
    case openAIModels = "openai.models"
    case prometheusJSON = "prometheus.json"
    case llamaProps = "llama.props"
    case strataHealth = "strata.health"
    case strataStatus = "strata.status"
    case strataMetrics = "strata.metrics"
}

public struct EngineTelemetrySource: Codable, Hashable, Sendable {
    public let role: EngineTelemetryRole
    public let path: String
    public let format: EngineTelemetryFormat

    public init(role: EngineTelemetryRole, path: String, format: EngineTelemetryFormat) {
        self.role = role
        self.path = path
        self.format = format
    }
}

public enum EngineHTTPMethod: String, Codable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

public enum EngineJSONTemplateValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public func jsonObject(context: [String: String]) -> Any {
        switch self {
        case .string(let value): return EngineTemplate.expand(value, context: context)
        case .int(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }
}

public struct EngineModelAction: Codable, Hashable, Sendable {
    public let method: EngineHTTPMethod
    public let path: String
    public let body: [String: EngineJSONTemplateValue]?

    public init(method: EngineHTTPMethod = .post,
                path: String,
                body: [String: EngineJSONTemplateValue]? = nil) {
        self.method = method
        self.path = path
        self.body = body
    }
}

public struct EngineModelControlSpec: Codable, Hashable, Sendable {
    public let load: EngineModelAction?
    public let unload: EngineModelAction?
    public let rescan: EngineModelAction?

    public init(load: EngineModelAction? = nil,
                unload: EngineModelAction? = nil,
                rescan: EngineModelAction? = nil) {
        self.load = load
        self.unload = unload
        self.rescan = rescan
    }
}

// MARK: - Presentation and runtime descriptor

public struct EngineDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: EngineID
    public let displayName: String
    public let summary: String
    public let accentColor: String
    public let adapter: EngineAdapterID
    public let defaultPort: Int
    public let minMacOS: String
    public let portRangeSize: Int
    public let startupTimeout: TimeInterval
    public let switchMode: ModelSwitchMode
    public let capabilities: [EngineCapability]
    public let modelLayout: EngineModelLayout
    public let modelControl: EngineModelControlSpec?
    public let telemetry: [EngineTelemetrySource]
    public let license: String?
    public let upstreamRepository: String?

    public init(id: EngineID,
                displayName: String,
                summary: String = "",
                accentColor: String = "#767676",
                adapter: EngineAdapterID = .standard,
                defaultPort: Int,
                minMacOS: String = "26.0",
                portRangeSize: Int = 20,
                startupTimeout: TimeInterval = 300,
                switchMode: ModelSwitchMode,
                capabilities: [EngineCapability],
                modelLayout: EngineModelLayout = .flat,
                modelControl: EngineModelControlSpec? = nil,
                telemetry: [EngineTelemetrySource] = [],
                license: String? = nil,
                upstreamRepository: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.accentColor = accentColor
        self.adapter = adapter
        self.defaultPort = defaultPort
        self.minMacOS = minMacOS
        self.portRangeSize = portRangeSize
        self.startupTimeout = startupTimeout
        self.switchMode = switchMode
        self.capabilities = capabilities
        self.modelLayout = modelLayout
        self.modelControl = modelControl
        self.telemetry = telemetry
        self.license = license
        self.upstreamRepository = upstreamRepository
    }

    public var capabilitySet: Set<EngineCapability> { Set(capabilities) }
    public var portRange: ClosedRange<Int> {
        defaultPort...(defaultPort + max(portRangeSize, 1) - 1)
    }

    /// Build a descriptor from a pack. Explicit manifest fields win; otherwise
    /// first-party defaults are used, and unknown engines receive safe defaults.
    public static func resolve(manifest: EngineManifest) -> EngineDescriptor {
        let base = EngineCatalog.descriptor(for: manifest.id)
        let inferredTelemetry: [EngineTelemetrySource]
        if let telemetry = manifest.telemetry, !telemetry.isEmpty {
            inferredTelemetry = telemetry
        } else if !base.telemetry.isEmpty {
            inferredTelemetry = base.telemetry
        } else if let status = manifest.status, !status.isEmpty {
            let format: EngineTelemetryFormat
            switch base.adapter {
            case .omlx: format = .omlxStatus
            case .mtplx: format = .mtplxSnapshot
            case .strata: format = .strataMetrics
            default: format = .splashStatus
            }
            inferredTelemetry = [EngineTelemetrySource(role: .status, path: status[0], format: format)]
        } else {
            inferredTelemetry = base.telemetry
        }
        return EngineDescriptor(
            id: manifest.id,
            displayName: manifest.name.isEmpty ? base.displayName : manifest.name,
            summary: base.summary,
            accentColor: base.accentColor,
            adapter: manifest.adapter ?? base.adapter,
            defaultPort: manifest.defaultPort,
            minMacOS: manifest.minMacOS,
            portRangeSize: manifest.portRangeSize ?? base.portRangeSize,
            startupTimeout: manifest.startupTimeout ?? base.startupTimeout,
            switchMode: manifest.modelSwitch,
            capabilities: Array(base.capabilitySet.union(manifest.capabilitySet)),
            modelLayout: manifest.modelLayout ?? base.modelLayout,
            modelControl: manifest.modelControl ?? base.modelControl,
            telemetry: inferredTelemetry,
            license: manifest.license ?? base.license,
            upstreamRepository: base.upstreamRepository)
    }
}

// MARK: - Catalog

/// Process-wide view over first-party engine descriptors plus descriptors
/// discovered in installed packs or the pack index.
public enum EngineCatalog {
    public static let builtIns: [EngineDescriptor] = [
        EngineDescriptor(
            id: .splash, displayName: "Splash",
            summary: "单模型 GGUF 运行时，专注 DFlash2 投机解码与视觉。",
            accentColor: "#D26A20", adapter: .splash,
            // Splash 自己的 supervision 给「spawn → Ready（含模型加载与预热）」
            // 的预算是 600 秒（server/supervision.py）。应用这一侧不能更短，
            // 否则大型 MoE 还在预热就被按 300 秒判超时，表现就是卡在「预热」。
            defaultPort: 8000, minMacOS: "26.0", startupTimeout: 660, switchMode: .restart,
            capabilities: [.chat, .streaming, .vision, .reasoning, .singleModel, .draft],
            modelLayout: .nested,
            license: "Apache-2.0", upstreamRepository: "incoai/splash"),
        EngineDescriptor(
            id: .omlx, displayName: "oMLX",
            summary: "通用 MLX 引擎，多模型热切换，MTP / DFlash2 按模型配置。",
            accentColor: "#177F86", adapter: .omlx,
            defaultPort: 8100, minMacOS: "15.0", startupTimeout: 180, switchMode: .hot,
            capabilities: [.chat, .streaming, .vision, .reasoning, .multiModel,
                           .hotLoad, .hotUnload, .modelRescan],
            modelLayout: .flat,
            modelControl: EngineModelControlSpec(
                load: EngineModelAction(path: "/v1/models/{model}/load"),
                unload: EngineModelAction(path: "/v1/models/{model}/unload"),
                rescan: EngineModelAction(path: "/v1/models/rescan")),
            telemetry: [
                EngineTelemetrySource(role: .status, path: "/api/status", format: .omlxStatus),
                EngineTelemetrySource(role: .inventory, path: "/v1/models/status", format: .omlxModels),
            ],
            license: "Apache-2.0", upstreamRepository: "jundot/omlx"),
        EngineDescriptor(
            id: .mtplx, displayName: "MTPLX",
            summary: "专注 Qwen MTP 投机解码的单模型运行时。",
            accentColor: "#5B57C9", adapter: .mtplx,
            defaultPort: 8200, minMacOS: "26.0", startupTimeout: 300, switchMode: .restart,
            capabilities: [.chat, .streaming, .vision, .reasoning, .singleModel, .mtp, .serial],
            telemetry: [
                EngineTelemetrySource(role: .status, path: "/v1/mtplx/snapshot", format: .mtplxSnapshot),
            ],
            license: "Apache-2.0", upstreamRepository: "youssofal/mtplx"),
        EngineDescriptor(
            id: .mlxServe, displayName: "MLX-Serve",
            summary: "原生 MLX / GGUF 通用引擎，多模型热加载，无需 Python。",
            accentColor: "#0A84FF", adapter: .mlxServe,
            defaultPort: 8300, minMacOS: "26.4", startupTimeout: 600, switchMode: .hot,
            capabilities: [.chat, .streaming, .vision, .reasoning, .multiModel,
                           .hotLoad, .hotUnload, .modelRescan, .toolUse],
            modelLayout: .nested,
            modelControl: EngineModelControlSpec(
                load: EngineModelAction(
                    path: "/v1/load-model",
                    body: ["model": .string("{model}"), "default": .bool(true)]),
                unload: EngineModelAction(
                    path: "/v1/unload-model",
                    body: ["model": .string("{model}")]),
                rescan: EngineModelAction(path: "/v1/models/rescan")),
            telemetry: [
                EngineTelemetrySource(role: .inventory, path: "/v1/models", format: .openAIModels),
                EngineTelemetrySource(role: .metrics, path: "/metrics.json", format: .prometheusJSON),
                EngineTelemetrySource(role: .props, path: "/props", format: .llamaProps),
            ],
            license: "MIT", upstreamRepository: "ddalcu/mlx-serve"),
        EngineDescriptor(
            id: .strata, displayName: "Strata",
            summary: "面向大规模 MoE 的 SSD 流式推理引擎，支持 Metal / CUDA / HIP。",
            accentColor: "#0AB887", adapter: .strata,
            defaultPort: 8400, minMacOS: "15.0", startupTimeout: 1800, switchMode: .restart,
            capabilities: [.chat, .streaming, .vision, .reasoning, .singleModel, .mtp],
            modelLayout: .external,
            telemetry: [
                EngineTelemetrySource(role: .health, path: "/health", format: .strataHealth),
                EngineTelemetrySource(role: .status, path: "/v1/status", format: .strataStatus),
                EngineTelemetrySource(role: .metrics, path: "/metrics", format: .strataMetrics),
                EngineTelemetrySource(role: .props, path: "/props", format: .llamaProps),
                EngineTelemetrySource(role: .inventory, path: "/v1/models", format: .openAIModels),
            ],
            license: "MIT", upstreamRepository: "Niko1221/Strata"),
    ]

    /// The complete set of engines supported by this application. Adding an
    /// engine is a source change here, never a runtime scan of user folders.
    public static var allIDs: [EngineID] { builtIns.map(\.id) }

    public static func descriptor(for id: EngineID) -> EngineDescriptor {
        if let first = builtIns.first(where: { $0.id == id }) { return first }
        return EngineDescriptor(
            id: id,
            displayName: id.rawValue.replacingOccurrences(of: "-", with: " ").capitalized,
            summary: "通过运行时 pack 接入的引擎。",
            defaultPort: 8500,
            switchMode: .restart,
            capabilities: [.chat, .streaming, .singleModel])
    }
}
