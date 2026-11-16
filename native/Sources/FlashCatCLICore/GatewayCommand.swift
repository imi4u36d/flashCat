import Foundation
import FlashCatKit

public enum GatewayCommand {
    public static func run(_ context: CLIContext) async throws -> Int32 {
        switch context.invocation.subcommand ?? "status" {
        case "status": return try await status(context)
        case "start": return try await toggle(context, running: true)
        case "stop": return try await toggle(context, running: false)
        default:
            throw CLIError("未知 gateway 子命令：\(context.invocation.subcommand ?? "")", exit: .usage,
                           hint: "可用：status / start / stop")
        }
    }

    private static func status(_ context: CLIContext) async throws -> Int32 {
        let gateway: ControlGatewayState
        do {
            let location = try context.control
            let status: ControlStatus = try await location.client.get("/v1/status",
                                                                      timeout: context.timeout)
            gateway = status.gateway
        } catch let error as CLIError where ControlFallback.shouldFallBack(error) {
            // 只有「应用没在运行」才允许展示离线视图；401/504/超时说明应用在跑，
            // 折叠成本地状态会返回 0 并把令牌过期之类的问题藏起来。
            let local = context.local
            gateway = ControlGatewayState(enabled: local.gatewayEnabled,
                                          running: local.gatewayEnabled && portOpen(local.gatewayPort),
                                          port: local.gatewayPort,
                                          baseURL: "http://127.0.0.1:\(local.gatewayPort)")
        }
        if context.output.json {
            context.output.json(gateway)
        } else {
            let state = gateway.running ? context.output.green("运行中")
                : (gateway.enabled ? context.output.yellow("未运行") : context.output.dim("已关闭"))
            context.output.line("\(gateway.baseURL)/v1 · \(state) · :\(gateway.port)")
            if let failure = gateway.failure { context.output.note(failure) }
        }
        return CLIExit.success.rawValue
    }

    private static func toggle(_ context: CLIContext, running: Bool) async throws -> Int32 {
        let location = try context.control
        let path = running ? "/v1/gateway/start" : "/v1/gateway/stop"
        var gateway: ControlGatewayState = try await location.client.post(path, timeout: context.timeout)
        if running {
            let deadline = Date().addingTimeInterval(15)
            while !gateway.running && Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                do {
                    let status: ControlStatus = try await location.client.get("/v1/status",
                                                                              timeout: 5)
                    gateway = status.gateway
                } catch let error as CLIError where ControlFallback.shouldFallBack(error) {
                    // 应用可能刚被唤醒、控制接口短暂不可用：继续等到 deadline。
                } catch {
                    // 401/504 之类说明应用在跑：再等 15 秒只会把真正原因拖成
                    // 「网关没有启动起来」，直接抛。
                    throw error
                }
            }
        }
        if running, !gateway.running {
            throw CLIError("网关没有启动起来", exit: .failure,
                           hint: gateway.failure ?? "运行 flashcat logs --gateway 查看原因")
        }
        if context.output.json {
            context.output.json(gateway)
        } else {
            context.output.success(running
                ? "网关已启动：\(gateway.baseURL)/v1"
                : "网关已关闭")
        }
        return CLIExit.success.rawValue
    }
}
