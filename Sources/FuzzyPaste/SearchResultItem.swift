import Foundation

/// 検索結果の統一型。クリップボード履歴とスニペットを混合して表示するために使用。
enum SearchResultItem: Sendable {
    case clip(ClipItem)
    case snippet(SnippetItem)

    /// ペースト / コピー時に使用するテキスト
    var text: String {
        switch self {
        case .clip(let item): return item.text
        case .snippet(let item): return item.content
        }
    }

    var isSnippet: Bool {
        if case .snippet = self { return true }
        return false
    }
}
