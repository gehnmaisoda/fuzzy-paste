import Foundation

/// コンテンツ種別に応じた自動タグを決定するユーティリティ。
/// 画像は "img"、ファイルは拡張子ベースでタグを付与する。テキストはタグなし。
public enum AutoTag {
    /// 画像コンテンツの自動タグ。
    public static let imageTag = "img"

    /// 拡張子 → 自動タグのマッピング。該当なしは空配列。
    public static func tags(forExtension ext: String) -> [String] {
        switch ext.lowercased() {
        case "pdf": return ["pdf"]
        case "csv": return ["csv"]
        case "json": return ["json"]
        default: return []
        }
    }
}
