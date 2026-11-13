import Foundation
import FlashCatKit

/// 对话里给文本模型挂的画图工具。
///
/// 工具只暴露「一次画一组」这一种形状：模型自己写分镜、一次要给几张，
/// 客户端按同一个 seed 串行画完再回填结果。不暴露单张多次调用的接口——
/// 那样模型会一张一张地要，每一张都要重新换模型，慢且贵。
enum ImageTool {
    static let name = "generate_images"
    /// 一次调用最多几张。四张足够讲完一组分镜，再多图片会把上下文和等待时间拉爆。
    static let maximumImagesPerCall = 4
    /// 一轮对话最多跑几次工具。画完再补一张、改一张是正常需求，但不能无限循环。
    static let maximumRounds = 3
    /// 一轮对话里最多落盘多少张，跨多次调用也计数。
    static let maximumImagesPerTurn = 8

    struct Call: Equatable {
        var prompts: [String]
        var size: String?
    }

    /// 挂进请求体的 `tools`。尺寸只给模型这一族模型真实支持的预设，
    /// 让它在枚举里选，省得自己编一个引擎会拒绝的画布。
    static func schema(sizeOptions: [String]) -> [[String: Any]] {
        var properties: [String: Any] = [
            "prompts": [
                "type": "array",
                "description": "按顺序要画的每一张图的完整提示词。一次调用画一组：想讲一个连续的故事就写多段，每段描述同一角色/同一场景在这一幕的样子（景别、动作、光线都要写清楚），不要只写「同上」。",
                "items": ["type": "string"],
                "minItems": 1,
                "maxItems": maximumImagesPerCall,
            ] as [String: Any],
        ]
        if !sizeOptions.isEmpty {
            properties["size"] = [
                "type": "string",
                "enum": sizeOptions,
                "description": "这一组图的画布尺寸，整组共用。不确定就省略，用用户当前设置的尺寸。",
            ] as [String: Any]
        }
        return [[
            "type": "function",
            "function": [
                "name": name,
                "description": "画图并直接显示在对话里。用户想看画面、要插图、要一组分镜/连环画时调用；一次给多个 prompts 就会画成一组共用同一随机种子的系列图，同一角色与画风在各张之间保持一致。调用后你会拿到每张图的路径与尺寸；能看图的模型还会直接收到成品本身，先看清再点评或补画。",
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": ["prompts"],
                ] as [String: Any],
            ] as [String: Any],
        ]]
    }

    /// 系统提示里追加的一段。工具描述已经写清用途，这里只补「别光说不画」——
    /// 聊天模型常见的失败是先描述一遍画面再问「要我画出来吗」。
    static let guidance = """
    你有一个画图工具 generate_images：需要给用户看图时直接调用它，不要只描述画面、也不要先征求同意。画一组系列图时，把每一幕写成一条 prompt 一次调用完。画完先看画面再收尾：能收到图片就直接看；只拿到路径时不要编造细节。
    """

    /// 解析失败时带一句能直接展示给用户的说明。实现字面量初始化，
    /// 保持 `return .failure("…")` 的写法；调用方用 `error.message` 取原文。
    struct Failure: Error, ExpressibleByStringLiteral {
        let message: String

        init(stringLiteral value: String) {
            message = value
        }
    }

    /// 解析模型给的参数。字段名以 schema 为准，但模型偶尔写成 `prompt`、
    /// 或把一张图的描述拆成数组里的空串，这里都收下并清洗。
    static func parse(_ call: ChatToolCall) -> Result<Call, Failure> {
        guard let object = call.object else {
            return .failure("参数不是合法 JSON，这一轮不画图。请重新调用，只传 prompts 数组。")
        }
        var prompts: [String]
        if let list = object["prompts"] as? [String] {
            prompts = list
        } else if let single = object["prompt"] as? String {
            prompts = [single]
        } else {
            prompts = []
        }
        prompts = prompts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !prompts.isEmpty else {
            return .failure("prompts 是空的：每组图至少要有一句画面描述。")
        }
        if prompts.count > maximumImagesPerCall {
            prompts = Array(prompts.prefix(maximumImagesPerCall))
        }
        let size = (object["size"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(Call(prompts: prompts, size: (size?.isEmpty ?? true) ? nil : size))
    }

    /// 模型给回来的结果按 JSON 写：模型读得懂，也不占多少 token。
    static func result(images: [(path: String, note: String)],
                       seed: Int,
                       size: String) -> String {
        let items = images.map { image in
            "{\"path\":\(quoted(image.path)),\"note\":\(quoted(image.note))}"
        }
        return "{\"ok\":true,\"seed\":\(seed),\"size\":\(quoted(size)),\"images\":[\(items.joined(separator: ","))]}"
    }

    static func failure(_ message: String) -> String {
        "{\"ok\":false,\"error\":\(quoted(message))}"
    }

    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        // [value] 序列化成 ["…"]，掐掉方括号就是带转义的字符串字面量。
        return String(text.dropFirst().dropLast())
    }
}

/// 「画」开关、选用的图像模型与常驻偏好，跟着用户走。默认开：这是对话页的
/// 主动能力，关掉是少数情况（模型不会画、或不想让引擎换模型）。
enum ImageToolSettings {
    private static let enabledKey = "flashCat.imageTool.enabled"
    private static let modelKey = "flashCat.imageTool.model"
    private static let residentKey = "flashCat.imageTool.resident"

    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }

    static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: enabledKey)
    }

    static var modelID: String {
        UserDefaults.standard.string(forKey: modelKey) ?? ""
    }

    static func setModelID(_ value: String) {
        UserDefaults.standard.set(value, forKey: modelKey)
    }

    /// 画完图后把图像模型留在显存里，下一轮生图不必再换进来。默认开：
    /// 关掉的人通常是内存紧、宁可多等一次加载，也不想同时挂两份权重。
    static var resident: Bool {
        (UserDefaults.standard.object(forKey: residentKey) as? Bool) ?? true
    }

    static func setResident(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: residentKey)
    }
}
