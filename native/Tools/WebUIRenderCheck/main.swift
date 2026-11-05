// WebUI render check.
//
// Loads the console page in a real WKWebView, feeds it the snapshot fixture the
// same way `WebBridge.pushSnapshot()` does, and asserts that all six pages
// paint. This is the missing regression net for `WebUI/`: the JS has no tests of
// its own, and a broken renderer currently only shows up as a blank window that
// nobody notices until a human opens that page.
//
//     swift run webui-render-check --webui Sources/FlashCat/WebUI
//
// Two passes run: "warm" (engine running, conversation in progress) and "cold"
// (engine stopped, no stats, no history) — the empty state is where the
// defensive branches live, and it is the state a fresh install sees first.
//
// Exit code is 0 only when every check passes, so CI can gate on it directly.

import AppKit
import Foundation
import WebKit

// MARK: - Report

enum Verdict: String {
    case pass
    case fail
    /// Could not run in this environment. Reported, never silently dropped:
    /// a check that quietly stops running is worse than no check.
    case skip
}

struct Result {
    let name: String
    let verdict: Verdict
    let detail: String
}

final class Report {
    private(set) var results: [Result] = []

    func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        results.append(Result(name: name, verdict: condition ? .pass : .fail, detail: detail()))
    }

    func skip(_ name: String, _ reason: String) {
        results.append(Result(name: name, verdict: .skip, detail: reason))
    }

    var failures: [Result] { results.filter { $0.verdict == .fail } }
    var skips: [Result] { results.filter { $0.verdict == .skip } }
    var passes: [Result] { results.filter { $0.verdict == .pass } }

    func writeJSON(webui: String, fixture: String, to handle: FileHandle) {
        let payload: [String: Any] = [
            "webui": webui,
            "fixture": fixture,
            "passed": passes.count,
            "failed": failures.count,
            "skipped": skips.count,
            "checks": results.map { ["name": $0.name, "verdict": $0.verdict.rawValue, "detail": $0.detail] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    func writeHuman() {
        var width = 0
        for result in results { width = max(width, result.name.count) }
        for result in results {
            let mark: String
            switch result.verdict {
            case .pass: mark = "ok  "
            case .fail: mark = "FAIL"
            case .skip: mark = "skip"
            }
            let padding = String(repeating: " ", count: max(0, width - result.name.count))
            print("  \(mark)  \(result.name)\(padding)  \(result.detail)")
        }
    }
}

// MARK: - Arguments

struct Arguments {
    var webui: URL
    var fixture: URL
    var json = false

    static func parse(_ argv: [String]) throws -> Arguments {
        var webui: URL?
        var fixture: URL?
        var json = false
        var index = 1
        while index < argv.count {
            switch argv[index] {
            case "--webui":
                index += 1
                guard index < argv.count else { throw Failure("--webui needs a directory") }
                webui = URL(fileURLWithPath: argv[index])
            case "--fixture":
                index += 1
                guard index < argv.count else { throw Failure("--fixture needs a file") }
                fixture = URL(fileURLWithPath: argv[index])
            case "--json":
                json = true
            case "--help", "-h":
                print(Self.usage)
                exit(0)
            default:
                throw Failure("unknown argument \(argv[index])\n\n\(Self.usage)")
            }
            index += 1
        }
        let resolvedWebUI = webui ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/FlashCat/WebUI")
        let resolvedFixture = fixture
            ?? Bundle.module.url(forResource: "snapshot", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tools/WebUIRenderCheck/Fixtures/snapshot.json")
        return Arguments(webui: resolvedWebUI, fixture: resolvedFixture, json: json)
    }

    static let usage = """
    usage: webui-render-check [--webui <dir>] [--fixture <file>] [--json]

      --webui    directory holding index.html (default: Sources/FlashCat/WebUI)
      --fixture  snapshot JSON to feed the page (default: bundled Fixtures/snapshot.json)
      --json     machine-readable report on stdout
    """
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Measurements

/// Everything the checks look at, gathered in one JS round trip so a page is
/// measured at a single instant instead of drifting between queries.
struct Metrics {
    var view = ""
    var nodes = 0
    var frameNodes = 0
    var frameText = 0
    var frameWidth = 0
    var frameHeight = 0
    var scrollHeight = 0
    var counts: [String: Int] = [:]

    init?(_ raw: Any?) {
        guard let text = raw as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        view = object["view"] as? String ?? ""
        nodes = object["nodes"] as? Int ?? 0
        frameNodes = object["frameNodes"] as? Int ?? 0
        frameText = object["frameText"] as? Int ?? 0
        frameWidth = object["frameWidth"] as? Int ?? 0
        frameHeight = object["frameHeight"] as? Int ?? 0
        scrollHeight = object["scrollHeight"] as? Int ?? 0
        counts = object["counts"] as? [String: Int] ?? [:]
    }

    func count(_ key: String) -> Int { counts[key] ?? 0 }
}

struct PageSpec {
    let page: String
    /// Selector that identifies the page shell. Must be present in every state,
    /// including the empty one — a missing shell is a blank window.
    let root: String
    /// Content selector that only the warm fixture produces.
    let content: String
    let minContent: Int
    let minText: Int
    let minTextCold: Int

    static let all: [PageSpec] = [
        PageSpec(page: "overview", root: "rootOverview", content: "widgets", minContent: 6, minText: 120, minTextCold: 120),
        PageSpec(page: "chat", root: "rootChat", content: "messages", minContent: 3, minText: 120, minTextCold: 40),
        PageSpec(page: "models", root: "rootModels", content: "modelCards", minContent: 3, minText: 120, minTextCold: 20),
        PageSpec(page: "engines", root: "rootEngines", content: "engineCards", minContent: 2, minText: 120, minTextCold: 120),
        PageSpec(page: "logs", root: "rootLogs", content: "logLines", minContent: 5, minText: 120, minTextCold: 20),
        PageSpec(page: "settings", root: "rootSettings", content: "rootSettings", minContent: 1, minText: 160, minTextCold: 160),
    ]
}

// MARK: - Page host

/// Drives the page and collects anything the console reports: uncaught errors,
/// `console.error`, rejected promises and CSP violations. All four are
/// regressions we care about; only the last one is a policy bug.
@MainActor
final class PageHost: NSObject {
    private let webView: WKWebView
    private let window: NSWindow
    private let sink = MessageSink()
    private var loaded = false
    private var loadFailure: String?
    private(set) var messages: [String] = []

    init(viewport: CGSize = CGSize(width: 1440, height: 900)) {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.probeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        webView = WKWebView(frame: CGRect(origin: .zero, size: viewport), configuration: configuration)
        window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 60, y: 60), size: viewport),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        // The window has to be ordered in, not just created: an offscreen or
        // hidden page reports visibilityState "hidden", WebKit rejects
        // `document.startViewTransition`, and the page logs an error for every
        // page switch — noise that would hide the errors this tool looks for.
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        sink.owner = self
        configuration.userContentController.add(sink, name: "probe")
        webView.navigationDelegate = self
    }

    func load(_ url: URL) {
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// Injected before any page script runs, so nothing can fail before the
    /// listeners exist.
    private static let probeScript = """
    (function () {
      const post = (kind, text) => {
        try { window.webkit.messageHandlers.probe.postMessage(kind + "\\u0000" + text); } catch (e) {}
      };
      const flatten = (args) => Array.prototype.map.call(args, (value) => {
        if (typeof value === "string") return value;
        if (value && value.message) return String(value.message);
        try { return JSON.stringify(value); } catch (e) { return String(value); }
      }).join(" ");
      const realError = console.error.bind(console);
      console.error = function () { post("console", flatten(arguments)); realError.apply(null, arguments); };
      window.addEventListener("error", (event) => {
        post("uncaught", (event.message || "error") + " @ " + (event.filename || "").split("/").pop() + ":" + event.lineno);
      });
      window.addEventListener("unhandledrejection", (event) => {
        post("uncaught", "unhandled rejection: " + flatten([event.reason]));
      });
      document.addEventListener("securitypolicyviolation", (event) => {
        post("csp", event.violatedDirective + " <- " + event.blockedURI);
      });
    })();
    """

    /// Runs one page. A single test with four dimensions: the view switched,
    /// the signature element exists, the frame has text, and the frame is laid
    /// out (a zero-height frame is the blank-window failure).
    private static let measureScript = """
    (function () {
      const frame = document.querySelector("#pageFrame");
      const main = document.querySelector("#mainContent");
      const count = (selector) => document.querySelectorAll(selector).length;
      const rect = frame ? frame.getBoundingClientRect() : { width: 0, height: 0 };
      return JSON.stringify({
        view: frame ? (frame.dataset.view || "") : "",
        nodes: document.querySelectorAll("*").length,
        frameNodes: frame ? frame.querySelectorAll("*").length : 0,
        frameText: frame ? (frame.innerText || "").trim().length : 0,
        frameWidth: Math.round(rect.width),
        frameHeight: Math.round(rect.height),
        scrollHeight: main ? main.scrollHeight : 0,
        counts: {
          widgets: count("#pageFrame .widget"),
          rootOverview: count("#pageFrame .widget"),
          rootChat: count("#pageFrame .chat-page"),
          rootModels: count("#pageFrame .fc-model-workspace"),
          rootEngines: count("#pageFrame .fc-engine-workspace"),
          rootLogs: count("#pageFrame .logs-workspace"),
          rootSettings: count("#pageFrame .settings-workspace"),
          messages: count("#messagesInner .message"),
          modelCards: count(".fc-model-card"),
          engineCards: count(".fc-engine-card"),
          logLines: count("#pageFrame .log-line"),
          navItems: count("#primaryNav .nav-item"),
          overlayChildren: count("#overlayLayer > *"),
          toastItems: count("#toastStack > *")
        }
      });
    })()
    """

    private static let bootScript = """
    (function () {
      const body = getComputedStyle(document.body);
      const root = getComputedStyle(document.documentElement);
      // A file:// page owns no origin, so reading `cssRules` throws
      // SecurityError. A custom property is the reliable proof that a sheet
      // parsed and applied: `--accent` only exists in styles.css.
      return JSON.stringify({
        bridge: typeof (window.__fc__ && window.__fc__.push) === "function",
        toast: typeof window.__fcToast === "function",
        errors: typeof window.__fcErrors === "object" && window.__fcErrors !== null,
        scripts: Array.prototype.map.call(document.scripts, (s) => (s.getAttribute("src") || "inline")),
        styles: document.styleSheets.length,
        accent: (root.getPropertyValue("--accent") || "").trim(),
        backgroundColor: body.backgroundColor,
        color: body.color,
        visibility: document.visibilityState,
        navItems: document.querySelectorAll("#primaryNav .nav-item").length
      });
    })()
    """

    // MARK: Run loop

    /// WebKit delivers everything on the main run loop. Pumping it is how this
    /// tool waits without blocking the very thread doing the work.
    func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func waitLoaded(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !loaded && loadFailure == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return loaded
    }

    var failure: String? { loadFailure }
    var url: URL? { webView.url }

    /// A locked screen or an unattended CI box leaves the window occluded, and
    /// WebKit then throttles `requestAnimationFrame` to zero. Anything that
    /// waits for a frame has to know.
    var isVisible: Bool {
        (evaluate("document.visibilityState") as? String) == "visible"
    }

    /// Synchronous JS evaluation. The completion handler fires on the main
    /// thread, so the run loop has to be pumped while waiting for it.
    func evaluate(_ script: String, timeout: TimeInterval = 10) -> Any? {
        var output: Any?
        var finished = false
        webView.evaluateJavaScript(script) { value, error in
            if let error {
                output = "JS error: \(error.localizedDescription)"
            } else {
                output = value
            }
            finished = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return output
    }

    func measure() -> Metrics? {
        Metrics(evaluate(Self.measureScript))
    }

    func boot() -> [String: Any]? {
        guard let text = evaluate(Self.bootScript) as? String,
              let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func tearDown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "probe")
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.orderOut(nil)
    }

    fileprivate func receive(_ message: String) {
        messages.append(message)
    }
}

extension PageHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailure = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailure = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadFailure = "the WebContent process was killed (it crashed or ran out of memory)"
    }
}

/// Held by `WKUserContentController`, which keeps a strong reference; the
/// back-pointer to the host stays weak so the two do not retain each other.
@MainActor
final class MessageSink: NSObject, WKScriptMessageHandler {
    weak var owner: PageHost?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        let parts = body.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
        let kind = parts.count > 1 ? String(parts[0]) : "console"
        let text = parts.count > 1 ? String(parts[1]) : body
        owner?.receive("[\(kind)] \(text)")
    }
}

// MARK: - Fixture

struct Fixture {
    private let base: [String: Any]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure("fixture is not a JSON object: \(url.path)")
        }
        base = object
    }

    var topLevelKeys: [String] { base.keys.sorted() }

    /// The snapshot Swift would send for `page` in the given state.
    func snapshot(page: String, warm: Bool, pending: [String: Any]? = nil) throws -> String {
        var snapshot = base
        snapshot["page"] = page
        if let pending {
            snapshot["pending"] = pending
        }
        if !warm {
            snapshot["engine"] = [
                "id": "splash", "name": "Splash", "version": "", "state": "stopped",
                "running": false, "ready": false, "switching": false,
                "switchStage": "", "startupStage": "", "startupSeconds": 0,
            ]
            snapshot["stats"] = NSNull()
            snapshot["throughput"] = []
            snapshot["acceptance"] = []
            snapshot["sessions"] = []
            snapshot["messages"] = []
            snapshot["threads"] = []
            snapshot["threadID"] = ""
            snapshot["generating"] = false
            snapshot["generationStatus"] = ""
            snapshot["selectedModel"] = ""
            snapshot["context"] = ["used": 0, "total": 0]
            snapshot["downloads"] = ["tasks": []]
            snapshot["logs"] = []
            snapshot["modelsMenu"] = []
            snapshot["modelsAll"] = []
            snapshot["library"] = ["engine": "splash", "entries": []]
        }
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.fragmentsAllowed])
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure("snapshot for \(page) could not be encoded as UTF-8")
        }
        return text
    }
}

// MARK: - Checks

@MainActor
struct Runner {
    let host: PageHost
    let fixture: Fixture
    let webui: URL
    let report: Report

    func run() {
        checkBoot()
        checkFixtureCoverage()
        for warm in [true, false] {
            for spec in PageSpec.all {
                checkPage(spec, warm: warm)
            }
        }
        checkStreaming()
        checkNavigation()
        checkOverlay()
        checkFocusTrap()
        checkChrome()
        checkConsole()
    }

    /// The fixture is only useful while it matches the snapshot the app really
    /// sends. A renamed or newly read field would otherwise surface as a blank
    /// panel with no error — so the fields the page reads are harvested from
    /// the JavaScript and required to exist in the fixture. When this fails,
    /// update `Fixtures/snapshot.json` to match `WebSnapshot.swift`.
    private func checkFixtureCoverage() {
        let scripts = (try? FileManager.default.contentsOfDirectory(at: webui, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "js" } ?? []
        let pattern = try? NSRegularExpression(pattern: #"(?:S\.)?snap\.([A-Za-z_$][\w$]*)"#)
        var read: Set<String> = []
        for script in scripts {
            guard let source = try? String(contentsOf: script, encoding: .utf8),
                  let pattern else { continue }
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                if let captured = Range(match.range(at: 1), in: source) {
                    read.insert(String(source[captured]))
                }
            }
        }
        let available = Set(fixture.topLevelKeys)
        let missing = read.subtracting(available).sorted()
        report.check("fixture/covers read fields", missing.isEmpty,
                     missing.isEmpty
                        ? "\(read.count) fields read by the page, all present"
                        : "missing from fixture: \(missing.joined(separator: ", "))")
    }

    private func push(page: String, warm: Bool) -> Bool {
        guard let json = try? fixture.snapshot(page: page, warm: warm) else { return false }
        let outcome = host.evaluate("window.__fc__.push(\(json)); 0;")
        if outcome is String {
            report.check("push/\(page)", false, "\(outcome ?? "")")
            return false
        }
        host.pump(0.45)
        return true
    }

    private func checkBoot() {
        guard let boot = host.boot() else {
            report.check("boot/page loaded", false, "the page produced no boot metrics")
            return
        }
        let bridge = boot["bridge"] as? Bool ?? false
        let toast = boot["toast"] as? Bool ?? false
        let errors = boot["errors"] as? Bool ?? false
        let scripts = (boot["scripts"] as? [String]) ?? []
        let styles = boot["styles"] as? Int ?? 0
        let accent = boot["accent"] as? String ?? ""
        let background = boot["backgroundColor"] as? String ?? ""
        let navItems = boot["navItems"] as? Int ?? 0

        report.check("boot/bridge entry points", bridge && toast && errors,
                     "push=\(bridge) toast=\(toast) errors=\(errors)")
        // Assert against the script tags index.html actually declares, not a
        // hardcoded count: a missing file then fails here, and deleting a script
        // on purpose does not need a number bumped in this file.
        let declared = declaredScripts()
        let loaded = Set(scripts.filter { $0 != "inline" })
        let missing = declared.subtracting(loaded).sorted()
        let extra = loaded.subtracting(declared).sorted()
        report.check("boot/scripts loaded", missing.isEmpty && extra.isEmpty,
                     missing.isEmpty && extra.isEmpty
                        ? "\(loaded.count) scripts, all declared tags loaded"
                        : "missing: \(missing.joined(separator: ", ")) — unexpected: \(extra.joined(separator: ", "))")
        report.check("boot/stylesheet applied", styles >= 8 && !accent.isEmpty,
                     "\(styles) sheets, --accent=\(accent.isEmpty ? "unset" : accent)")
        let blank = background.isEmpty || background == "rgba(0, 0, 0, 0)" || background == "transparent"
        report.check("boot/page painted", !blank, "body background \(background)")
        report.check("boot/navigation rendered", navItems == 6, "\(navItems) nav items")
    }

    /// The `<script src>` tags index.html asks for, in document order.
    private func declaredScripts() -> Set<String> {
        let html = (try? String(contentsOf: webui.appendingPathComponent("index.html"), encoding: .utf8)) ?? ""
        let pattern = try? NSRegularExpression(pattern: #"<script\s+src="([^"']+)""#)
        var names: Set<String> = []
        if let pattern {
            let range = NSRange(html.startIndex..., in: html)
            for match in pattern.matches(in: html, range: range) {
                if let r = Range(match.range(at: 1), in: html) { names.insert(String(html[r])) }
            }
        }
        return names
    }

    private func checkPage(_ spec: PageSpec, warm: Bool) {
        let label = "page/\(spec.page)\(warm ? "" : " (cold)")"
        guard push(page: spec.page, warm: warm), let metrics = host.measure() else {
            report.check(label, false, "no metrics after push")
            return
        }
        let root = metrics.count(spec.root)
        let content = metrics.count(spec.content)
        let minText = warm ? spec.minText : spec.minTextCold
        let detail = "view=\(metrics.view) \(spec.root)=\(root) \(spec.content)=\(content) "
            + "nodes=\(metrics.frameNodes) text=\(metrics.frameText) size=\(metrics.frameWidth)x\(metrics.frameHeight)"
        let ok = metrics.view == spec.page
            && root >= 1
            && (warm ? content >= spec.minContent : true)
            && metrics.frameText >= minText
            && metrics.frameHeight > 0
            && metrics.frameWidth > 0
        report.check(label, ok, detail)
    }

    /// Tokens arrive on a separate channel from the snapshot. This pins the
    /// append path: a delta must extend the last message, not create a second
    /// one, and `end` must leave the transcript intact.
    ///
    /// Text is painted by a requestAnimationFrame loop (`chat-stream.js`
    /// `schedule` / `frame`). WebKit throttles those to zero while the window is
    /// hidden, so the check cannot run on a locked screen — it says so instead
    /// of reporting a failure the code did not cause.
    private func checkStreaming() {
        guard host.isVisible else {
            report.skip("stream/append", "needs a visible window (screen locked or session unattended)")
            report.skip("stream/end keeps one node", "needs a visible window (screen locked or session unattended)")
            return
        }
        guard push(page: "chat", warm: true) else {
            report.check("stream/append", false, "chat page did not render")
            return
        }
        let probe = """
        (function () {
          const nodes = document.querySelectorAll("#messagesInner .message");
          const last = nodes[nodes.length - 1];
          return JSON.stringify({
            count: nodes.length,
            text: last ? (last.innerText || "").trim().length : 0
          });
        })()
        """
        func snapshotState() -> (count: Int, text: Int) {
            guard let text = host.evaluate(probe) as? String,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (0, 0)
            }
            return (object["count"] as? Int ?? 0, object["text"] as? Int ?? 0)
        }

        let before = snapshotState()
        let deltas = """
        window.__fc__.stream([
          { type: "delta", id: "msg-assistant-streaming", seq: 11, at: Date.now(), channel: "content",
            text: "草稿模型与目标分布越接近，接受率越高；低于 60% 通常意味着草稿太长。" },
          { type: "delta", id: "msg-assistant-streaming", seq: 12, at: Date.now(), channel: "content",
            text: "可以试着把草稿长度降到 4 再测。" }
        ]); 0;
        """
        _ = host.evaluate(deltas)
        host.pump(1.2)
        let after = snapshotState()

        report.check("stream/append", after.text > before.text && after.count == before.count,
                     "text \(before.text) -> \(after.text), messages \(before.count) -> \(after.count)")

        _ = host.evaluate("window.__fc__.stream([{ type: \"end\", id: \"msg-assistant-streaming\", at: Date.now(), cancelled: false }]); 0;")
        host.pump(0.6)
        let settled = snapshotState()
        report.check("stream/end keeps one node", settled.count == after.count,
                     "\(settled.count) messages after end")
    }

    /// Clicking the nav must switch pages on the client alone — the snapshot
    /// only confirms it later. `data-view` is the observable side effect.
    private func checkNavigation() {
        if !push(page: "overview", warm: true) {
            report.check("nav/click", false, "overview did not render")
            return
        }
        var failed: [String] = []
        for spec in PageSpec.all where spec.page != "overview" {
            let script = """
            (function () {
              const item = document.querySelector('#primaryNav .nav-item[data-page="\(spec.page)"]');
              if (!item) return "missing";
              item.click();
              const frame = document.querySelector("#pageFrame");
              return JSON.stringify({ view: frame ? frame.dataset.view : "", active: document.querySelectorAll("#primaryNav .nav-item.active").length });
            })()
            """
            host.pump(0.35)
            guard let text = host.evaluate(script) as? String, text != "missing" else {
                failed.append("\(spec.page): no nav button")
                continue
            }
            host.pump(0.25)
            if let metrics = host.measure(), metrics.view == spec.page, metrics.frameText > 0 {
                continue
            }
            failed.append("\(spec.page): view did not switch")
        }
        report.check("nav/click", failed.isEmpty, failed.isEmpty ? "all five switches rendered" : failed.joined(separator: "; "))
    }

    /// Overlays live in `#overlayLayer` and are toggled by class, so the check
    /// looks at the class and the panel's own box — counting layer children
    /// would only count the permanent panels that are always mounted.
    ///
    /// Drives the real user path: command palette → 「下载中心」 entry → the
    /// downloads overlay. Exercising the palette here also keeps it covered by
    /// every run; closing goes through the sheet's own close button.
    private func checkOverlay() {
        _ = push(page: "overview", warm: true)
        let openScript = """
        (function () {
          // Real user path: the toolbar's download shortcut button.
          const trigger = document.querySelector("#downloadShortcut");
          if (!trigger) return JSON.stringify({ missing: "downloadShortcut" });
          trigger.click();
          const layer = document.querySelector("#overlayLayer");
          const sheet = document.querySelector("#downloadSheet");
          return JSON.stringify({
            open: layer.classList.contains("is-open") && layer.classList.contains("downloads-open"),
            height: sheet ? Math.round(sheet.getBoundingClientRect().height) : 0,
            text: sheet ? (sheet.innerText || "").trim().length : 0,
            ariaHidden: layer.getAttribute("aria-hidden")
          });
        })()
        """
        guard let text = host.evaluate(openScript) as? String,
              let data = text.data(using: .utf8),
              let opened = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            report.check("overlay/open", false, "probe returned nothing")
            return
        }
        let isOpen = opened["open"] as? Bool ?? false
        let height = opened["height"] as? Int ?? 0
        let overlayText = opened["text"] as? Int ?? 0
        if isOpen && height > 20 && overlayText > 0 {
            report.check("overlay/open", true,
                         "open=true size=\(height) text=\(overlayText) aria-hidden=\(opened["ariaHidden"] ?? "?")")
        } else {
            report.check("overlay/open", false,
                         "open=\(isOpen) size=\(height) text=\(overlayText) raw=\(text.prefix(400))")
        }

        // The real close path: the sheet's own close button (a user would also
        // accept Escape — app.js routes both to the same closeOverlays). The
        // close runs an exit animation and removes `is-open` in its finish()
        // callback, so the Swift side polls instead of probing synchronously.
        let closeScript = """
        (function () {
          const closer = document.querySelector("#downloadSheet [data-close-downloads]") ||
                         document.querySelector("[data-close-downloads]");
          if (!closer) return JSON.stringify({ missing: "data-close-downloads" });
          closer.click();
          // The close runs a WAAPI exit animation whose finish() removes the
          // classes. In a hidden window rendering is throttled and the
          // animation never completes on its own, so fast-forward it — the
          // app's own finish() callback then runs exactly as in a visible
          // window. (Standard WAAPI test technique.)
          document.getAnimations().forEach((animation) => { try { animation.finish(); } catch (e) {} });
          return "clicked";
        })()
        """
        guard let closeText = host.evaluate(closeScript) as? String, closeText == "clicked" else {
            report.check("overlay/close keeps page", false, "close click failed")
            return
        }
        var closed: [String: Any]?
        let closeProbe = """
        (function () {
          const layer = document.querySelector("#overlayLayer");
          const frame = document.querySelector("#pageFrame");
          const sheet = document.querySelector("#downloadSheet");
          return JSON.stringify({
            open: layer.classList.contains("is-open"),
            layerClass: layer.className,
            frameExists: Boolean(frame),
            frameText: frame ? (frame.innerText || "").trim().length : -1,
            sheetAnims: sheet ? sheet.getAnimations().length : -1,
            ariaHidden: layer.getAttribute("aria-hidden")
          });
        })()
        """
        let closeDeadline = Date().addingTimeInterval(3)
        while Date() < closeDeadline {
            if let text = host.evaluate(closeProbe) as? String,
               let data = text.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if value["open"] as? Bool == false { closed = value; break }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let stillOpen = (closed?["open"] as? Bool) ?? true
        let frameText = (closed?["frameText"] as? Int) ?? 0
        let debug = closed.map { "layer=\($0["layerClass"] ?? "?") anims=\($0["sheetAnims"] ?? "?") frameExists=\($0["frameExists"] ?? "?")" } ?? "never closed within 3s"
        report.check("overlay/close keeps page", !stillOpen && frameText > 0,
                     "open=\(stillOpen) page text \(frameText) — \(debug)")
    }

    /// The three `aria-modal` dialogs (command palette, pending confirmation,
    /// share engines) share the keyboard governance in store.js: Tab cycles
    /// inside the dialog, Escape dismisses the scrim dialogs, focus moves to
    /// the least destructive action on open and returns to the trigger on
    /// close. This check drives each path the way a keyboard user would.
    ///
    /// The palette opens via its real path (⌘K); the pending dialog arrives
    /// through the same `__fc__.push` snapshot the bridge delivers. The
    /// cancel round-trip needs Swift to answer `cmd(...)`, which this harness
    /// does not do — so the cancel side effect is asserted by intercepting
    /// the `[cmd]` console fallback, and the dialog is dismissed by pushing
    /// a snapshot without `pending`, exactly what the app does after cancel.
    private func checkFocusTrap() {
        _ = push(page: "overview", warm: true)

        // --- palette: ⌘K → Tab wraps at both ends → Escape closes ---
        let paletteScript = """
        (function () {
          // Real key events target the focused element (or body) — never the
          // document node itself, which is also what keeps listener errors
          // attributed to their real script instead of masked.
          const fire = (key, extra) => document.body.dispatchEvent(
            new KeyboardEvent("keydown", Object.assign({ key: key, bubbles: true, cancelable: true }, extra || {})));
          fire("k", { metaKey: true });
          const palette = document.querySelector("#commandPalette");
          if (!palette || palette.getAttribute("aria-modal") !== "true") {
            return JSON.stringify({ error: "palette did not open via cmd+k" });
          }
          const items = () => Array.from(palette.querySelectorAll("button:not([disabled]), input:not([disabled])"));
          const all = items();
          if (!all.length) return JSON.stringify({ error: "no focusable items in palette" });
          all[all.length - 1].focus();
          fire("Tab");
          const wrapForward = document.activeElement === all[0];
          all[0].focus();
          fire("Tab", { shiftKey: true });
          const wrapBack = document.activeElement === all[all.length - 1];
          return JSON.stringify({ wrapForward: wrapForward, wrapBack: wrapBack, count: all.length });
        })()
        """
        guard let text = host.evaluate(paletteScript) as? String,
              let data = text.data(using: .utf8),
              let palette = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            report.check("a11y/palette tab cycle", false, "probe returned nothing")
            return
        }
        if let error = palette["error"] as? String {
            report.check("a11y/palette tab cycle", false, error)
        } else {
            let forward = palette["wrapForward"] as? Bool ?? false
            let back = palette["wrapBack"] as? Bool ?? false
            report.check("a11y/palette tab cycle", forward && back,
                         "\(palette["count"] ?? 0) focusables, forward=\(forward) back=\(back)")
        }

        // Escape → app.js closeOverlays → WAAPI exit; fast-forward like the
        // overlay close check, then poll for aria-modal to drop.
        let paletteEscape = """
        (function () {
          document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
          document.getAnimations().forEach((animation) => { try { animation.finish(); } catch (e) {} });
          return "fired";
        })()
        """
        guard let escapeText = host.evaluate(paletteEscape) as? String, escapeText == "fired" else {
            report.check("a11y/palette escape closes", false, "escape dispatch failed")
            return
        }
        var paletteClosed = false
        let paletteProbe = "document.querySelector('#commandPalette').getAttribute('aria-modal')"
        let paletteDeadline = Date().addingTimeInterval(3)
        while Date() < paletteDeadline {
            if (host.evaluate(paletteProbe) as? String) == "false" { paletteClosed = true; break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        report.check("a11y/palette escape closes", paletteClosed,
                     paletteClosed ? "aria-modal dropped after escape" : "palette still open within 3s")

        // --- pending dialog: pushed with `pending`, focus lands on cancel,
        //     Escape routes to cancel, dismissal gives focus back ---
        let stashScript = """
        (function () {
          const trigger = document.querySelector("#downloadShortcut");
          if (!trigger) return "missing";
          trigger.focus();
          return document.activeElement === trigger ? "focused" : "unfocused";
        })()
        """
        guard (host.evaluate(stashScript) as? String) == "focused" else {
            report.check("a11y/pending initial focus", false, "could not focus trigger")
            return
        }
        guard let pendingJSON = try? fixture.snapshot(
            page: "overview", warm: true,
            pending: ["kind": "use", "needsDownload": false, "model": "Qwen/Qwen3-8B", "engine": "splash"]) else {
            report.check("a11y/pending initial focus", false, "pending snapshot failed to encode")
            return
        }
        _ = host.evaluate("window.__fc__.push(\(pendingJSON)); 0;")
        host.pump(0.45)
        let pendingProbe = """
        (function () {
          const node = document.querySelector("#fcPending");
          const dialog = node && node.querySelector(".fc-modal");
          const cancel = node && node.querySelector("[data-pending^='cancel']");
          return JSON.stringify({
            present: Boolean(dialog),
            ariaModal: dialog ? dialog.getAttribute("aria-modal") : null,
            focusOnCancel: Boolean(cancel) && document.activeElement === cancel
          });
        })()
        """
        guard let pendingText = host.evaluate(pendingProbe) as? String,
              let pendingData = pendingText.data(using: .utf8),
              let pending = try? JSONSerialization.jsonObject(with: pendingData) as? [String: Any] else {
            report.check("a11y/pending initial focus", false, "probe returned nothing")
            return
        }
        let present = pending["present"] as? Bool ?? false
        let focusOnCancel = pending["focusOnCancel"] as? Bool ?? false
        report.check("a11y/pending initial focus",
                     present && (pending["ariaModal"] as? String) == "true" && focusOnCancel,
                     "present=\(present) focusOnCancel=\(focusOnCancel)")

        // Escape must reach the cancel button. The harness cannot answer the
        // resulting `cmd`, so assert the dispatch by catching the console
        // fallback that cmd() uses when no bridge handler is installed.
        let escapeCancel = """
        (function () {
          const seen = [];
          const original = console.log;
          console.log = function () { seen.push(arguments[1] && arguments[1].type); };
          try {
            document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
          } finally { console.log = original; }
          return JSON.stringify({ cmds: seen });
        })()
        """
        let cancelTypes = (host.evaluate(escapeCancel) as? String)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let cmds = (cancelTypes?["cmds"] as? [String]) ?? []
        report.check("a11y/pending escape cancels", cmds.contains("cancelLibraryUse"),
                     cmds.isEmpty ? "no cmd dispatched" : "cmds: \(cmds.joined(separator: ", "))")

        // Dismiss exactly the way the app does after the Swift round-trip:
        // a snapshot without `pending`. The scrim disappears and focus
        // returns to the element that was active when it opened.
        _ = push(page: "overview", warm: true)
        let restoreProbe = """
        (function () {
          const trigger = document.querySelector("#downloadShortcut");
          return JSON.stringify({
            gone: !document.querySelector("#fcPending"),
            focusBack: Boolean(trigger) && document.activeElement === trigger
          });
        })()
        """
        let restoreText = (host.evaluate(restoreProbe) as? String)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let gone = restoreText?["gone"] as? Bool ?? false
        let focusBack = restoreText?["focusBack"] as? Bool ?? false
        report.check("a11y/pending close restores focus", gone && focusBack,
                     "gone=\(gone) focusBack=\(focusBack)")
    }

    /// The shell: theme, sidebar and toasts all paint outside `#pageFrame`, so
    /// a page-only check would miss them.
    private func checkChrome() {
        let script = """
        (function () {
          // Theme is a user click on the toolbar toggle, not a direct call:
          // app.js binds #themeToggle to setTheme(toggle(resolvedTheme())).
          const toggle = document.querySelector("#themeToggle");
          if (!toggle) return JSON.stringify({ missing: "themeToggle" });
          toggle.click();
          const dark = document.documentElement.dataset.theme;
          toggle.click();
          const light = document.documentElement.dataset.theme;
          window.__fc__.setSidebar(false);
          const collapsed = document.body.classList.contains("sidebar-collapsed");
          window.__fc__.setSidebar(true);
          const expanded = !document.body.classList.contains("sidebar-collapsed");
          window.__fcToast("回归检查");
          return JSON.stringify({ dark: dark, light: light, collapsed: collapsed, expanded: expanded,
                                  toasts: document.querySelectorAll("#toastStack > *").length });
        })()
        """
        guard let text = host.evaluate(script) as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            report.check("chrome/theme", false, "probe returned nothing")
            return
        }
        report.check("chrome/theme", (object["dark"] as? String) == "dark" && (object["light"] as? String) == "light",
                     "dark=\(object["dark"] ?? "?") light=\(object["light"] ?? "?")")
        report.check("chrome/sidebar", (object["collapsed"] as? Bool ?? false) && (object["expanded"] as? Bool ?? false),
                     "collapse and restore both applied")
        report.check("chrome/toast", (object["toasts"] as? Int ?? 0) > 0,
                     "\(object["toasts"] ?? 0) toast nodes")
    }

    /// Everything the console reported, minus noise this environment creates.
    ///
    /// A hidden window makes `document.startViewTransition` reject; the page
    /// logs that rejection, and `guardEntry` logs it a second time. Both say
    /// "rejected", not "threw" — an exception raised *inside* the transition
    /// callback still arrives with its own message and still fails the check.
    /// Suppressed messages are counted and shown, never dropped silently.
    private func checkConsole() {
        let hidden = !host.isVisible
        func isEnvironmentNoise(_ message: String) -> Bool {
            guard hidden else { return false }
            return message.contains("View transition was skipped")
                || message.contains("Promise rejected startViewTransition")
        }
        let suppressed = host.messages.filter(isEnvironmentNoise).count
        func relevant(_ prefix: String) -> [String] {
            host.messages.filter { $0.hasPrefix(prefix) && !isEnvironmentNoise($0) }
        }
        let csp = relevant("[csp]")
        let uncaught = relevant("[uncaught]")
        let errors = relevant("[console]")
        let note = suppressed > 0 ? " (suppressed \(suppressed) hidden-window notices)" : ""

        report.check("console/no CSP violations", csp.isEmpty,
                     csp.isEmpty ? "none\(note)" : csp.prefix(3).joined(separator: " | "))
        report.check("console/no uncaught errors", uncaught.isEmpty,
                     uncaught.isEmpty ? "none\(note)" : uncaught.prefix(3).joined(separator: " | "))
        report.check("console/no logged errors", errors.isEmpty,
                     errors.isEmpty ? "none\(note)" : errors.prefix(3).joined(separator: " | "))
    }
}

// MARK: - Entry point

@MainActor
func main() -> Int32 {
    let arguments: Arguments
    do {
        arguments = try Arguments.parse(CommandLine.arguments)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return 2
    }

    let index = arguments.webui.appendingPathComponent("index.html")
    guard FileManager.default.fileExists(atPath: index.path) else {
        FileHandle.standardError.write(Data("no index.html in \(arguments.webui.path)\n".utf8))
        return 2
    }

    let fixture: Fixture
    do {
        fixture = try Fixture(url: arguments.fixture)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return 2
    }

    // WKWebView needs an NSApplication even without a window; `.accessory`
    // keeps the check out of the Dock and the menu bar.
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let host = PageHost()
    host.load(index)
    guard host.waitLoaded(timeout: 30) else {
        let reason = host.failure ?? "timed out waiting for the page to load"
        FileHandle.standardError.write(Data("cannot load \(index.path): \(reason)\n".utf8))
        return 2
    }
    // Boot builds the shell over a couple of animation frames.
    host.pump(0.8)

    let report = Report()
    Runner(host: host, fixture: fixture, webui: arguments.webui, report: report).run()
    host.tearDown()

    if arguments.json {
        report.writeJSON(webui: arguments.webui.path, fixture: arguments.fixture.path, to: FileHandle.standardOutput)
    } else {
        print("webui-render-check")
        print("  page     \(index.path)")
        print("  fixture  \(arguments.fixture.path)")
        print("  window   \(host.isVisible ? "visible" : "hidden (locked screen or unattended session)")")
        print("")
        report.writeHuman()
        print("")
        var summary = "  \(report.passes.count) passed, \(report.failures.count) failed"
        if !report.skips.isEmpty { summary += ", \(report.skips.count) skipped" }
        print(summary)
    }
    return report.failures.isEmpty ? 0 : 1
}

exit(MainActor.assumeIsolated { main() })
