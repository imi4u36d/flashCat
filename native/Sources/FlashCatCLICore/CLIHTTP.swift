import Foundation

/// The CLI has no use for an on-disk URL cache, and writing one under
/// `~/Library/Caches/flashcat-cli` is both noise and (under a sandbox) an error
/// dump on stderr. Ephemeral sessions keep every command self-contained.
public enum CLIHTTP {
    public static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: configuration)
    }
}
