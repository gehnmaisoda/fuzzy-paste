import Foundation

/// fuzzy search アルゴリズム。
/// クエリの各文字が対象文字列に「順番通りに」含まれていればマッチとみなす。
///
/// 例: クエリ "hlo" は "hello world" にマッチする（h...l...o の順で見つかる）
/// 例: クエリ "olh" は "hello world" にマッチしない（順番が違う）
public enum FuzzyMatcher {
    /// マッチ判定とスコア計算。マッチしなければ nil を返す。
    ///
    /// スコアリング: 連続一致にボーナスを与える。
    /// - 1文字目の連続一致 → +1
    /// - 2文字目の連続一致 → +2（累積）
    /// - 途切れたらリセット
    /// これにより "hello" で検索したとき、"hello world" が "h.e" より上位にくる。
    public static func match(query: String, target: String) -> Int? {
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
    public static func filter(query: String, items: [ClipItem]) -> [ClipItem] {
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
    /// スニペットは title, content, tags で検索し、高い方のスコアを採用。
    /// 画像・ファイルはファイル名で検索対象にする。
    /// クエリが空の場合、クリップ履歴のみを表示（スニペットは検索時のみ混合）。
    /// tagFilters が指定された場合、全てのタグを持つスニペットのみ表示（クリップは除外）。
    public static func filterMixed(query: String, clips: [ClipItem], snippets: [SnippetItem], tagFilters: [String] = []) -> [SearchResultItem] {
        if !tagFilters.isEmpty {
            let filtered = snippets.filter { snippet in
                tagFilters.allSatisfy { snippet.tags.contains($0) }
            }
            if query.isEmpty {
                return filtered.map { .snippet($0) }
            }
            var scored: [(item: SearchResultItem, score: Int)] = []
            for snippet in filtered {
                let best = bestSnippetScore(query: query, snippet: snippet)
                if let s = best { scored.append((.snippet(snippet), s)) }
            }
            return scored.sorted { $0.score > $1.score }.map(\.item)
        }

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
            case .file(let meta):
                if let score = match(query: query, target: meta.originalFileName) {
                    scored.append((.clip(clip), score))
                }
            }
        }

        for snippet in snippets {
            if let bestScore = bestSnippetScore(query: query, snippet: snippet) {
                scored.append((.snippet(snippet), bestScore))
            }
        }

        return scored.sorted { $0.score > $1.score }.map(\.item)
    }

    /// スニペットの title, content, tags からベストスコアを返す。
    /// CLI の検索機能でも使用するため public。
    public static func bestSnippetScore(query: String, snippet: SnippetItem) -> Int? {
        var scores: [Int?] = [
            match(query: query, target: snippet.title),
            match(query: query, target: snippet.content),
        ]
        for tag in snippet.tags {
            scores.append(match(query: query, target: tag))
        }
        return scores.compactMap { $0 }.max()
    }
}
