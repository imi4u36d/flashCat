import Foundation

/// What the engine page can do with one release from the pack index.
public enum EnginePackAction: String, Sendable, Equatable {
    /// Nothing installed yet.
    case install
    /// A newer version than the newest installed one.
    case update
    /// Exactly the newest installed version — offered so a broken runtime can be
    /// rebuilt in place without deleting it first.
    case reinstall

    public var label: String {
        switch self {
        case .install: return "安装"
        case .update: return "更新"
        case .reinstall: return "重装"
        }
    }
}

/// One row of the engine page's "可安装 / 可更新" section.
public struct EnginePackOffer: Sendable, Equatable {
    public let release: EnginePackRelease
    public let action: EnginePackAction

    public init(release: EnginePackRelease, action: EnginePackAction) {
        self.release = release
        self.action = action
    }
}

public enum EnginePackOffers {
    /// Pairs the index with what is already on disk.
    ///
    /// Every release newer than the newest installed version is an `update`; the
    /// newest installed version itself is a `reinstall`; anything older is
    /// dropped, because offering 0.7.1 next to an installed 0.7.2 only invites
    /// accidental downgrades. With nothing installed, every release is an
    /// `install` and the list stays newest first.
    public static func offers(installed: [String],
                              releases: [EnginePackRelease]) -> [EnginePackOffer] {
        let newestInstalled = installed.max { EngineVersionOrder.isNewer($1, than: $0) }
        var result: [EnginePackOffer] = []
        for release in releases {
            if let newestInstalled {
                if release.version == newestInstalled {
                    result.append(EnginePackOffer(release: release, action: .reinstall))
                } else if EngineVersionOrder.isNewer(release.version, than: newestInstalled) {
                    result.append(EnginePackOffer(release: release, action: .update))
                }
            } else {
                result.append(EnginePackOffer(release: release, action: .install))
            }
        }
        return result
    }
}
