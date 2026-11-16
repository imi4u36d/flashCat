import Foundation
import FlashCatKit

/// 引擎会话状态聚合：服务状态、指标、当前模型、切换/确认流程与生命周期心跳。
///
/// 「聚合」是关键：这些值彼此有先后关系（切换中 → 新模型 → 指标归零），拆成
/// 多个 store 只会让它们在两个发布周期之间闪一下。真正会改它们的是 AppState 的
/// 编排（启动、切换、轮询），所以这里只有状态，没有方法。
///
/// 视图仍然只订阅 AppState：`AppState.engineSessionBridge` 把这里的发布桥回去。
@MainActor
final class EngineSessionStore: ObservableObject {
    @Published var serverState: ServerState = .stopped
    @Published var stats: ServerStats?
    /// 当前选中的模型 id。空串表示还没有（没装引擎、或首次启动等你选）。
    @Published var selectedModel: String = ""
    /// Bumped when the startup engine/model preference changes. The value lives
    /// in `EngineStore` (and is written with the *current* engine untouched),
    /// so the settings row needs this tick to re-render.
    @Published var defaultRevision = 0
    /// Non-nil while newly selected weights are loading. The switchers show an
    /// inline spinner and the overview swaps live metrics for skeletons.
    @Published var switchingModel: String?
    /// Stage the running switch is in ("卸载旧模型" / "加载新模型"). Shown in the
    /// switcher instead of a generic spinner so the wait is explainable.
    @Published var switchStage: String = ""
    /// 「已等待 m:ss」读的是时钟，不是任何 `@Published` 字段：引擎安静加载的几
    /// 分钟里 `syncController` 的「只有真的变了才发布」会把每一秒都挡掉，灵动岛的
    /// 秒数就停住，等下一行日志或一个指标变化才跳一大截。这个计数器只在模型忙的
    /// 时候每秒推一格，专门让读时钟的文案重算。
    @Published var lifecycleTick: Int = 0
    /// Non-nil while a model switch is waiting for the reader to confirm that
    /// the model that is loaded now gets stopped first. Switching weights means
    /// unloading the resident model, so the engine is briefly unusable — that is
    /// worth one click, not a silent stall.
    @Published var confirmingModelSwitch: String?
    /// Set when a switch targets an engine whose pack is not installed. The
    /// weights can be on disk (browsing works without the runtime), so without
    /// this the switch would silently do nothing while claiming success.
    @Published var pendingEngineInstall: EngineID?
}
