import Foundation

/// 引擎运行阶段。保留 `loading`：它和 `starting` 在文档里是同一种「还没起来」，
/// 但 `ControlEngineState.isRunning` 已经把它算作运行中，丢掉这一档会让「正在
/// 加载权重」的引擎在文档里看起来像已经停了。
public enum ControlEnginePhase: String, Sendable, CaseIterable {
    case starting
    case loading
    case ready
    case stopping
    case failed
    case stopped
}

/// 引擎文档的输入。壳层只负责把「手上有什么」填进来：在线时有控制器，离线时
/// 没有，但两份文档的字段规则必须是同一份。
public struct ControlEngineDocumentInput: Sendable, Equatable {
    public var id: EngineID
    public var installedVersion: String?
    public var installedVersions: [String]
    public var isActive: Bool
    public var phase: ControlEnginePhase
    public var configuredPort: Int?
    public var boundPort: Int?
    public var selectedModel: String
    public var lastModel: String?
    public var stage: String
    public var uptimeSeconds: Int?
    public var pid: Int?

    public init(id: EngineID,
                installedVersion: String? = nil,
                installedVersions: [String] = [],
                isActive: Bool = false,
                phase: ControlEnginePhase = .stopped,
                configuredPort: Int? = nil,
                boundPort: Int? = nil,
                selectedModel: String = "",
                lastModel: String? = nil,
                stage: String = "",
                uptimeSeconds: Int? = nil,
                pid: Int? = nil) {
        self.id = id
        self.installedVersion = installedVersion
        self.installedVersions = installedVersions
        self.isActive = isActive
        self.phase = phase
        self.configuredPort = configuredPort
        self.boundPort = boundPort
        self.selectedModel = selectedModel
        self.lastModel = lastModel
        self.stage = stage
        self.uptimeSeconds = uptimeSeconds
        self.pid = pid
    }
}

/// 引擎文档的唯一产出方。App 的 `/v1/engines`、`/status` 与 CLI 的离线
/// `status` / `engines list` 以前各写一份 map，已经漂移过一次：离线列表在
/// active 引擎没有选中模型时不会回退到 `lastModel`，和在线文档对不上。
public enum ControlEngineDocuments {
    /// 端口只有一个优先级：真实监听端口 > 用户配置 > 引擎默认。归一交给
    /// `ControlConfigGrammar.port`，所以 `0` 在两个调用点都等于「没配置」。
    public static func port(_ input: ControlEngineDocumentInput) -> Int {
        if let boundPort = input.boundPort { return boundPort }
        return ControlConfigGrammar.port(input.configuredPort, fallback: input.id.defaultPort)
    }

    /// active 引擎优先用用户当前选择的模型；还没选过（首次启动）就退回上次用
    /// 的模型，否则文档会显示一个空模型而界面显示上次那个。
    public static func model(_ input: ControlEngineDocumentInput) -> String {
        if input.isActive, !input.selectedModel.isEmpty { return input.selectedModel }
        return input.lastModel ?? ""
    }

    public static func engine(_ input: ControlEngineDocumentInput) -> ControlEngineState {
        ControlEngineState(id: input.id.rawValue,
                           name: input.id.displayName,
                           // 未安装时显示占位符而不是空串：表格列需要一个非空值。
                           version: input.installedVersion ?? "—",
                           installedVersions: input.installedVersions,
                           isActive: input.isActive,
                           isInstalled: input.installedVersion != nil,
                           state: input.phase.rawValue,
                           port: port(input),
                           model: model(input),
                           stage: input.stage,
                           uptimeSeconds: input.uptimeSeconds,
                           pid: input.pid,
                           capabilities: input.id.descriptor.capabilities.map(\.rawValue).sorted())
    }

    public static func engines(_ inputs: [ControlEngineDocumentInput]) -> [ControlEngineState] {
        inputs.map(engine)
    }

    /// `status.engine` 的口径：active 优先，没有 active 就第一个。两处各写一遍
    /// `first { $0.isActive } ?? first` 迟早会有一处忘记后半句。
    public static func primary(_ engines: [ControlEngineState]) -> ControlEngineState? {
        engines.first { $0.isActive } ?? engines.first
    }
}
