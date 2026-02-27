import Foundation

/// fuzzy search アルゴリズム。
/// クエリの各文字が対象文字列に「順番通りに」含まれていればマッチとみなす。
///
/// 例: クエリ "hlo" は "hello world" にマッチする（h...l...o の順で見つかる）
/// 例: クエリ "olh" は "hello world" にマッチしない（順番が違う）
enum FuzzyMatcher {
    /// マッチ判定とスコア計算。マッチしなければ nil を返す。
    ///
    /// スコアリング: 連続一致にボーナスを与える。
    /// - 1文字目の連続一致 → +1
    /// - 2文字目の連続一致 → +2（累積）
    /// - 途切れたらリセット
    /// これにより "hello" で検索したとき、"hello world" が "h.e" より上位にくる。
    static func match(query: String, target: String) -> Int? {
        let query = query.lowercased()
        let target = target.lowercased()

        var score = 0
        var consecutive = 0
        var targetIndex = target.startIndex

        for queryChar in query {
            var found = false
            while targetIndex < target.endIndex {
                if target[targetIndex] == queryChar {
                    consecutive += 1
                    score += consecutive
                    targetIndex = target.index(after: targetIndex)
                    found = true
                    break
                }
                consecutive = 0
                targetIndex = target.index(after: targetIndex)
            }
            if !found { return nil }
        }
        return score
    }

    /// クエリでアイテム一覧をフィルタリングし、スコア降順でソートして返す。
    /// クエリが空の場合は全件をそのまま返す。
    static func filter(query: String, items: [ClipItem]) -> [ClipItem] {
        if query.isEmpty { return items }
        return items
            .compactMap { item -> (item: ClipItem, score: Int)? in
                guard let text = item.text,
                      let score = match(query: query, target: text) else { return nil }
                return (item, score)
            }
            .sorted { $0.score > $1.score }
            .map(\.item)
    }

    /// クエリでクリップ履歴とスニペットを統合検索し、スコア順で返す。
    /// スニペットは title と content の両方で検索し、高い方のスコアを採用。
    /// クエリが空の場合、クリップ履歴のみを表示（スニペットは検索時のみ混合）。
    /// クエリがある場合、画像アイテムはスキップ（テキスト検索不可）。
    static func filterMixed(query: String, clips: [ClipItem], snippets: [SnippetItem]) -> [SearchResultItem] {
        if query.isEmpty {
            return clips.map { SearchResultItem.clip($0) }
        }

        var scored: [(item: SearchResultItem, score: Int)] = []

        for clip in clips {
            switch clip.content {
            case .text(let text):
                if let score = match(query: query, target: text) {
                    scored.append((.clip(clip), score))
                }
            case .image(let meta):
                // 画像は originalFileName があれば検索対象にする
                if let name = meta.originalFileName,
                   let score = match(query: query, target: name) {
                    scored.append((.clip(clip), score))
                }
            }
        }

        for snippet in snippets {
            let titleScore = match(query: query, target: snippet.title)
            let contentScore = match(query: query, target: snippet.content)
            if let bestScore = [titleScore, contentScore].compactMap({ $0 }).max() {
                scored.append((.snippet(snippet), bestScore))
            }
        }

        return scored.sorted { $0.score > $1.score }.map(\.item)
    }
}
