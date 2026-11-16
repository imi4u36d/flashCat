import Foundation

/// 控制接口不可用时，CLI 会退回「离线视图」：读 control.json、端口、本地模型目录，
/// 然后照常 exit 0。只有「连不上 / 没有 control.json」才说明应用真的没在运行。
///
/// 401（令牌过期）、504（服务端超时）、请求超时都说明应用在跑、只是这次没答好。
/// 把这些错误折叠成离线视图，用户会看到一份陈旧的本地状态并且进程返回 0，
/// 故障被伪装成正常；离线视图还会盖掉真正需要重启应用的令牌问题。
/// 所以降级判据只有一条：错误码是 `.notRunning`。
public enum ControlFallback {
    public static func shouldFallBack(_ error: CLIError) -> Bool {
        error.exit == .notRunning
    }
}
