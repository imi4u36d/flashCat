import Foundation

/// The endpoints flashCat drives on a pack engine.
///
/// oMLX keeps the OpenAI surface at the root (`/v1/models/{id}/load|unload`,
/// `/api/status`) but mounts its management API under `/admin`
/// (`omlx/admin/routes.py`: `APIRouter(prefix="/admin")`), so per-model
/// MTP/DFlash settings live at `/admin/api/models/{id}/settings` — the plain
/// `/api/...` form answers 404 even for a model the engine has loaded.
public enum EngineRoutes {
    /// `POST` — hot load a model.
    public static func load(_ modelID: String) -> String {
        "/v1/models/\(component(modelID))/load"
    }

    /// `POST` — drop a model's weights again.
    public static func unload(_ modelID: String) -> String {
        "/v1/models/\(component(modelID))/unload"
    }

    /// `PUT` — apply MTP/DFlash settings to one model.
    public static func modelSettings(_ modelID: String) -> String {
        "/admin/api/models/\(component(modelID))/settings"
    }

    /// Percent-encode a model id for use as a single path segment: `owner/repo`
    /// ids keep their slash escaped, `owner--repo` link names stay readable.
    static func component(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
