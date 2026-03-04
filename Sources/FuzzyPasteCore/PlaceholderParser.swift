import Foundation

/// スニペット内の `{{プレースホルダー名}}` を検出・抽出・置換するユーティリティ。
/// ステートレスなので全メソッドが static。
public enum PlaceholderParser {
    private static let pattern = try! NSRegularExpression(pattern: #"\{\{([^}]+)\}\}"#)

    /// テンプレート文字列に動的プレースホルダーが含まれるか判定する。
    public static func hasDynamicPlaceholders(in template: String) -> Bool {
        let range = NSRange(template.startIndex..., in: template)
        return pattern.firstMatch(in: template, range: range) != nil
    }

    /// テンプレート文字列からプレースホルダー名を出現順・一意で抽出する。
    public static func extractPlaceholderNames(from template: String) -> [String] {
        let range = NSRange(template.startIndex..., in: template)
        let matches = pattern.matches(in: template, range: range)
        var seen = Set<String>()
        var names: [String] = []
        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: template) else { continue }
            let name = String(template[nameRange])
            if seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    /// テンプレート内のプレースホルダーを値で置換した文字列を返す。
    /// `values` に含まれないプレースホルダーはそのまま残す。
    public static func resolve(template: String, values: [String: String]) -> String {
        var result = template
        for (name, value) in values {
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return result
    }
}
