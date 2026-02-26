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
                guard let score = match(query: query, target: item.text) else { return nil }
                return (item, score)
            }
            .sorted { $0.score > $1.score }
            .map(\.item)
    }
}
