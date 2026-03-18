import Foundation

/// スニペット内の `{{プレースホルダー名}}` を検出・抽出・置換するユーティリティ。
/// ステートレスなので全メソッドが static。
///
/// 構文:
/// - `{{名前}}` — 自由入力
/// - `{{OS:macOS,Windows,Linux}}` — 選択肢付き（最初の `:` の後にカンマ区切り）
public enum PlaceholderParser {
    private static let pattern = try! NSRegularExpression(pattern: #"\{\{([^}]+)\}\}"#)

    /// プレースホルダーの定義。名前と、選択肢がある場合はその一覧を持つ。
    public struct Placeholder: Equatable, Sendable {
        public let name: String
        /// 選択肢。nil なら自由入力。
        public let options: [String]?
        /// resolve 時に使うキー。`{{名前:選択肢}}` 全体を置換するために元の raw 文字列を保持。
        public let rawToken: String
    }

    /// テンプレート文字列に動的プレースホルダーが含まれるか判定する。
    public static func hasDynamicPlaceholders(in template: String) -> Bool {
        let range = NSRange(template.startIndex..., in: template)
        return pattern.firstMatch(in: template, range: range) != nil
    }

    /// テンプレート文字列からプレースホルダー名を出現順・一意で抽出する。
    public static func extractPlaceholderNames(from template: String) -> [String] {
        extractPlaceholders(from: template).map(\.name)
    }

    /// テンプレート文字列からプレースホルダー定義を出現順・一意（名前ベース）で抽出する。
    /// `{{名前:選択肢1,選択肢2}}` 形式の場合、options に選択肢の配列が入る。
    public static func extractPlaceholders(from template: String) -> [Placeholder] {
        let range = NSRange(template.startIndex..., in: template)
        let matches = pattern.matches(in: template, range: range)
        var seen = Set<String>()
        var placeholders: [Placeholder] = []
        for match in matches {
            guard let innerRange = Range(match.range(at: 1), in: template) else { continue }
            let inner = String(template[innerRange])
            let (name, options) = parseInner(inner)
            if seen.insert(name).inserted {
                let rawToken = "{{\(inner)}}"
                placeholders.append(Placeholder(name: name, options: options, rawToken: rawToken))
            }
        }
        return placeholders
    }

    /// テンプレート内のプレースホルダーを値で置換した文字列を返す。
    /// `values` に含まれないプレースホルダーはそのまま残す。
    /// 選択肢付き `{{名前:選択肢}}` も rawToken ごと置換する。
    public static func resolve(template: String, values: [String: String]) -> String {
        let placeholders = extractPlaceholders(from: template)
        var result = template
        for placeholder in placeholders {
            guard let value = values[placeholder.name] else { continue }
            result = result.replacingOccurrences(of: placeholder.rawToken, with: value)
        }
        return result
    }

    /// `名前:選択肢1,選択肢2` を (名前, options?) にパースする。
    /// 最初の `:` で分割する。`:` がなければ options は nil（自由入力）。
    private static func parseInner(_ inner: String) -> (name: String, options: [String]?) {
        guard let colonIndex = inner.firstIndex(of: ":") else {
            return (inner, nil)
        }
        let name = String(inner[inner.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let optionsStr = String(inner[inner.index(after: colonIndex)...])
        let options = optionsStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return (name, options.isEmpty ? nil : options)
    }
}
