import Foundation

/// 検索結果の統一型。クリップボード履歴とスニペットを混合して表示するために使用。
enum SearchResultItem: Sendable {
    case clip(ClipItem)
    case snippet(SnippetItem)

    /// ペースト / コピー時に使用するテキスト。画像・ファイルの場合は nil。
    var text: String? {
        switch self {
        case .clip(let item): return item.text
        case .snippet(let item): return item.content
        }
    }

    /// clip の場合のみ ClipItem を返す。
    var clipItem: ClipItem? {
        if case .clip(let item) = self { return item }
        return nil
    }
}
