import Foundation

/// Bilingual string service for the update flow. Strings come from the
/// staged res/i18n JSON files (byte-identical to shared/i18n/{zh,en}.json,
/// staged by the rivet resources clause). Lookup: current language → zh
/// fallback → the key itself. `{0}` placeholders are formatted positionally.
final class I18nService: @unchecked Sendable {
    static let shared = I18nService()

    private var tables: [String: [String: String]] = [:] // lang → key → text
    private var current = "zh"
    private let lock = NSLock()

    private init() {
        tables["zh"] = Self.loadTable("zh")
        tables["en"] = Self.loadTable("en")
    }

    var language: String {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// "zh" | "en"; anything else falls back to zh.
    func setLanguage(_ lang: String) {
        lock.lock()
        current = (lang.lowercased() == "en") ? "en" : "zh"
        lock.unlock()
    }

    func t(_ key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let v = tables[current]?[key] { return v }
        if let v = tables["zh"]?[key] { return v }
        return key
    }

    /// Positional formatting: first argument replaces {0}, etc.
    func format(_ key: String, _ args: Any...) -> String {
        var text = t(key)
        for (index, arg) in args.enumerated() {
            text = text.replacingOccurrences(of: "{\(index)}", with: String(describing: arg))
        }
        return text
    }

    // MARK: - Resource loading

    private static func loadTable(_ lang: String) -> [String: String] {
        if let url = HostResources.locate(i18n: lang),
           let data = try? Data(contentsOf: url),
           let table = try? JSONDecoder().decode([String: String].self, from: data) {
            return table
        }
        return [:]
    }
}
