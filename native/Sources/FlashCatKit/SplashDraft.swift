import Foundation

/// Which DFlash2 draft belongs to a Splash model.
///
/// Splash releases one draft per model family, and an assembly records its
/// family when a recent Splash prepared it. Older assemblies and hub ids that
/// were never prepared carry no family, so the id itself is the evidence left:
/// family names are matched against it with punctuation folded away, which is
/// how `Qwen3.8-27B` finds `mlx-community/Qwen3.8-27B-4bit`.
public enum SplashDraft {

    /// The draft repository for one model, or nil when nothing matches.
    ///
    /// A family that released no draft answers for itself: the match stops
    /// there instead of falling through to a guess, because a draft the family
    /// does not have is not the draft to download.
    ///
    /// - Parameters:
    ///   - modelId: the model's id — a repository with an optional quant, or an
    ///     assembly name.
    ///   - family: the family an assembly recorded, which wins over matching.
    ///   - familyDrafts: family name → draft repository, read from the engine pack.
    ///   - fallback: what the catalog already knows for this model, used only
    ///     when no family name matches.
    public static func repository(for modelId: String,
                                  family: String?,
                                  familyDrafts: [String: String],
                                  fallback: String? = nil) -> String? {
        if let family, !family.isEmpty, let name = key(of: family, in: familyDrafts) {
            return released(familyDrafts[name] ?? "")
        }
        let folded = fold(modelId)
        // Longest name first: a family whose name prefixes another's must not
        // take the match away from the more specific one.
        let matches = familyDrafts.keys
            .filter { !fold($0).isEmpty && folded.contains(fold($0)) }
            .sorted { fold($0).count > fold($1).count }
        if let name = matches.first { return released(familyDrafts[name] ?? "") }
        let known = (fallback ?? "").trimmingCharacters(in: .whitespaces)
        return known.isEmpty ? nil : known
    }

    /// Read `install/families.py` into family → draft repository.
    ///
    /// A family without a released draft (`None`) maps to an empty repository:
    /// dropping it would let the next family that happens to share the id win,
    /// which is exactly the draft that must not be fetched.
    ///
    /// - Returns: an empty dictionary when the file has no `ModelFamily` rows,
    ///   so the caller can keep what it already knows instead.
    public static func families(inFamiliesPy text: String) -> [String: String] {
        // `ModelFamily("Qwen3.8-27B", "incoai/Qwen3.8-27B-DFlash2", QWEN)` and
        // `ModelFamily("Flint", "…", FLINT, vision=False)` and the `None` form.
        let pattern = "ModelFamily\\(\\s*\"([^\"]+)\"\\s*,\\s*(?:\"([^\"]*)\"|None)\\s*[,)]"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(location: 0, length: text.utf16.count)
        var result: [String: String] = [:]
        for match in expression.matches(in: text, options: [], range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])
            guard !name.isEmpty else { continue }
            let draftRange = match.range(at: 2)
            let draft = draftRange.location == NSNotFound
                ? ""
                : Range(draftRange, in: text).map { String(text[$0]) } ?? ""
            result[name] = draft
        }
        return result
    }

    /// Packs print `None` for a family without a draft; the parser keeps it as
    /// an empty repository so the family still answers for itself.
    private static func released(_ repository: String) -> String? {
        let name = repository.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func key(of family: String, in drafts: [String: String]) -> String? {
        drafts.keys.first { $0.caseInsensitiveCompare(family) == .orderedSame }
    }

    /// Family names and model ids disagree on case and punctuation only, so
    /// compare them as bare ASCII letters and digits.
    private static func fold(_ value: String) -> String {
        value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
