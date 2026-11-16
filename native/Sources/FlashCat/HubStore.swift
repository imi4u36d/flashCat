import Foundation
import FlashCatKit

/// Hugging Face 浏览器的状态与请求。
///
/// 模型广场有两个「先看一眼再决定」的入口：列表/仓库详情（`hubDetail`）和手填
/// 仓库 id 的预检（`repoProbe`）。两者互不相干，弹层同时开着也不该互相挤掉，
/// 所以两组状态并存；三个请求任务各自取消，票号只用于按引擎的搜索——它的答案
/// 最慢，也最容易被下一次输入超过。
///
/// 搬出 AppState 是为了让「浏览」这条线和引擎/下载彻底解耦：这里不碰磁盘、不
/// 写设置，只发 HTTP 并把结果摆出来。结果能不能用（在不在本机、能不能装进这个
/// 引擎）仍由 AppState 判断。
@MainActor
final class HubStore: ObservableObject {
    /// Hugging Face 浏览器的列表状态。列表与单个仓库详情分开存——弹层里翻 tab
    /// 不该把列表挤掉，两者也都只是「看一眼」，不持久化、不碰磁盘。
    @Published private(set) var hubResults: [HubModel] = []
    /// 手填仓库 id 的预检结果：输入停下后查一次 Hub，弹层里显示体积/参数量/
    /// 文件清单/README 摘要，看清了再按下「开始下载」。和模型广场的 `hubDetail`
    /// 分开存，两边同时在屏上也不会互相挤掉。
    @Published private(set) var repoProbe: HubModel?
    @Published private(set) var repoProbeLoading = false
    @Published private(set) var repoProbeError: String?
    /// 当前这份预检结果属于哪个仓库。界面拿它对输入框：用户还在改 id 时，
    /// 旧结果不能被当成新仓库的结果显示出来。
    @Published private(set) var repoProbeRepo = ""
    @Published private(set) var hubDetail: HubModel?
    @Published private(set) var hubQuery = ""
    @Published private(set) var hubSort: HubSort = .trending
    @Published private(set) var hubFilter: HubFilter = .all
    /// 0 起的页码。HF 的 skip 是纯偏移，所以页码就是 skip / pageSize。
    @Published private(set) var hubPage = 0
    /// 这一页满了就认为还有下一页（HF 不给总数，模型列表也没有 count 接口）。
    @Published private(set) var hubHasMore = false
    @Published private(set) var hubLoading = false
    @Published private(set) var hubDetailLoading = false
    @Published private(set) var hubError: String?
    /// Hub search for the model page. Session-scoped: the results live in
    /// memory only, so switching engines or relaunching drops them.
    @Published private(set) var hubSearch = HubSearchState()

    private var repoProbeTask: Task<Void, Never>?
    private var repoProbeKey = ""
    private var hubSearchTask: Task<Void, Never>?
    private var hubDetailTask: Task<Void, Never>?
    /// Bumped on every keystroke that starts a search so a slow answer cannot
    /// overwrite a newer one.
    private var hubSearchTicket = 0

    private static let hubClient = HubSearchClient()

    /// 换引擎栏时把按引擎的搜索清空。
    ///
    /// 搜索是「这一栏里的这次查询」：换栏就散，否则新栏会顶着一次它从没被输入
    /// 过的查询，把别的引擎的命中当成自己的结果。票号一并作废，免得还在路上的
    /// 答案落进新栏。
    func resetSearch() {
        hubSearchTicket += 1
        hubSearch = HubSearchState()
    }

    /// Search the Hub for repositories the current column can serve.
    ///
    /// Two requests, not one: the list endpoint's `siblings[].size` is always
    /// null, so sizes only come from the per-repository endpoint, fetched
    /// concurrently for the handful of hits that survive the format filter.
    func searchHub(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hubSearchTicket += 1
        let ticket = hubSearchTicket
        guard !trimmed.isEmpty else {
            hubSearch = HubSearchState()
            return
        }
        hubSearch = HubSearchState(query: trimmed, phase: .loading)
        Task { [weak self] in
            guard let self else { return }
            do {
                let hits = try await Self.hubClient.search(trimmed)
                let enriched = await Self.hubClient.enrich(hits)
                let results = enriched.compactMap { HubSearchState.result(for: $0) }
                guard ticket == self.hubSearchTicket else { return }
                self.hubSearch = HubSearchState(query: trimmed, phase: .idle, results: results)
            } catch {
                guard ticket == self.hubSearchTicket else { return }
                let message = (error as? HubError)?.errorDescription ?? "\(error)"
                self.hubSearch = HubSearchState(query: trimmed, phase: .failed, error: message)
            }
        }
    }

    /// The search hits the given column may show. Ownership comes from the
    /// repository's own format, so a row never appears in two columns.
    func hubResults(for engine: EngineID) -> [HubSearchResult] {
        hubSearch.results
            .filter { $0.engines.contains(engine) }
            .map { $0.targeting(engine) }
    }

    /// 搜索/推荐列表。请求会被下一次调用取消，所以连点排序按钮不会乱序上屏。
    /// 翻页/换筛选走同一个入口，只是把 page 与 filter 一起带下去。
    func searchHub(_ query: String, sort: String, filter: String? = nil, page: Int = 0) {
        let value = HubSort(rawValue: sort) ?? .trending
        let bucket = filter.flatMap(HubFilter.init(rawValue:)) ?? hubFilter
        hubQuery = query
        hubSort = value
        hubFilter = bucket
        hubPage = max(0, page)
        hubSearchTask?.cancel()
        hubError = nil
        hubLoading = true
        let current = hubPage
        hubSearchTask = Task { [weak self] in
            do {
                let models = try await HubClient.search(
                    query: query,
                    sort: value,
                    filter: bucket,
                    page: current
                )
                guard !Task.isCancelled else { return }
                self?.hubResults = models
                self?.hubHasMore = models.count >= HubClient.pageSize
                self?.hubLoading = false
                // Quantization and memory need real file sizes, which the list
                // endpoint does not return. Show the rows immediately, then
                // fill in metadata a few repositories at a time.
                let enriched = await HubClient.enrich(models)
                guard !Task.isCancelled else { return }
                self?.hubResults = enriched
            } catch {
                guard !Task.isCancelled else { return }
                self?.hubResults = []
                self?.hubHasMore = false
                self?.hubLoading = false
                self?.hubError = error.localizedDescription
            }
        }
    }

    /// 打开某个仓库的模型卡：文件清单和 README 都在这一个请求里补齐。
    func loadHubDetail(_ repo: String) {
        hubDetailTask?.cancel()
        hubDetail = nil
        hubError = nil
        hubDetailLoading = true
        hubDetailTask = Task { [weak self] in
            do {
                let detail = try await HubClient.detail(repo)
                guard !Task.isCancelled else { return }
                self?.hubDetail = detail
                self?.hubDetailLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.hubDetailLoading = false
                self?.hubError = error.localizedDescription
            }
        }
    }

    func closeHubDetail() {
        hubDetailTask?.cancel()
        hubDetail = nil
        hubDetailLoading = false
    }

    /// 手填仓库 id 的预检。输入每停一次就调一次，上一次的请求直接取消——
    /// 中间态的仓库 id（`Youssof`、`Youssofal/`）不查，省掉一堆必然 404 的请求。
    func probeRepo(_ repo: String) {
        let key = ModelSharing.canonical(repo.trimmingCharacters(in: .whitespacesAndNewlines))
        guard key != repoProbeKey else { return }
        repoProbeKey = key
        repoProbeRepo = key
        repoProbeTask?.cancel()
        repoProbeError = nil
        guard key.split(separator: "/").count == 2 else {
            repoProbe = nil
            repoProbeLoading = false
            return
        }
        repoProbe = nil
        repoProbeLoading = true
        repoProbeTask = Task { [weak self] in
            do {
                let detail = try await HubClient.detail(key)
                guard !Task.isCancelled else { return }
                self?.repoProbe = detail
                self?.repoProbeLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.repoProbe = nil
                self?.repoProbeLoading = false
                self?.repoProbeError = error.localizedDescription
            }
        }
    }

    /// 弹窗关掉就丢掉预检结果：下次打开是另一个仓库，留着旧卡会先闪一下。
    func clearRepoProbe() {
        repoProbeTask?.cancel()
        repoProbe = nil
        repoProbeLoading = false
        repoProbeError = nil
        repoProbeKey = ""
        repoProbeRepo = ""
    }
}
