import Foundation

/// One concrete model an engine can serve.
public struct GatewayModelRoute: Equatable, Sendable {
    public let model: String
    public let engine: EngineID

    public init(model: String, engine: EngineID) {
        self.model = model
        self.engine = engine
    }
}

/// Maps the `model` field of an API request to the engine that owns those
/// weights.
///
/// Gateway clients send one stable model id, but flashCat can have several
/// engines installed and each engine has its own model directory. Forwarding
/// the request to whichever engine happens to be active is wrong: engines that
/// ignore an unknown `model` field answer with the model they already have
/// loaded, which makes a request look successful while it ran the wrong
/// weights. Resolution therefore happens before the upstream call.
public enum GatewayModelRouting {
    /// The first engine in `orderedEngines` that can actually serve
    /// `requestedModel`. Callers put the active engine first so duplicate ids
    /// keep the same precedence as `GET /v1/models`.
    public static func resolve(requestedModel: String?,
                               orderedEngines: [EngineID],
                               modelsByEngine: [EngineID: [String]]) -> GatewayModelRoute? {
        let wanted = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !wanted.isEmpty else { return nil }
        for engine in orderedEngines {
            if modelsByEngine[engine]?.contains(wanted) == true {
                return GatewayModelRoute(model: wanted, engine: engine)
            }
        }
        return nil
    }
}
