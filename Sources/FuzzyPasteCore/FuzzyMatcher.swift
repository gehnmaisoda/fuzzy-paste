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

    // MARK: - Frecency

    /// frecency スコアを計算する。使用回数と最終使用日時から算出。
    /// 半減期 72 時間で連続減衰する。
    public static func frecencyScore(useCount: Int, lastUsedAt: Date?, now: Date = Date()) -> Double {
        guard useCount > 0, let lastUsed = lastUsedAt else { return 0 }
        let hoursSinceLastUse = max(0, now.timeIntervalSince(lastUsed) / 3600)
        let decayFactor = pow(0.5, hoursSinceLastUse / 72.0)
        return Double(useCount) * decayFactor
    }

    /// frecency スコアの重み（fuzzy スコアに対する比率）
    private static let frecencyWeight: Double = 0.5

    /// fuzzy スコアと frecency スコアを合成する。
    private static func combinedScore(fuzzy: Int, clip: ClipItem) -> Double {
        Double(fuzzy) + frecencyWeight * frecencyScore(useCount: clip.useCount, lastUsedAt: clip.lastUsedAt)
    }

    /// クエリでアイテム一覧をフィルタリングし、スコア降順でソートして返す。
    /// クエリが空の場合は全件をそのまま返す。
    public static func filter(query: String, items: [ClipItem]) -> [ClipItem] {
        if query.isEmpty { return items }
        return items
            .compactMap { item -> (item: ClipItem, score: Double)? in
                guard let text = item.text,
                      let fuzzy = match(query: query, target: text) else { return nil }
                return (item, combinedScore(fuzzy: fuzzy, clip: item))
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
        let activeSnippets = snippets.filter(\.hasContent)
        if !tagFilters.isEmpty {
            let filtered = activeSnippets.filter { snippet in
                tagFilters.allSatisfy { snippet.tags.contains($0) }
            }
            if query.isEmpty {
                return filtered.map { .snippet($0) }
            }
            var scored: [(item: SearchResultItem, score: Double)] = []
            for snippet in filtered {
                let best = bestSnippetScore(query: query, snippet: snippet)
                if let s = best { scored.append((.snippet(snippet), Double(s))) }
            }
            return scored.sorted { $0.score > $1.score }.map(\.item)
        }

        if query.isEmpty {
            return clips.map { SearchResultItem.clip($0) }
        }

        var scored: [(item: SearchResultItem, score: Double)] = []

        for clip in clips {
            switch clip.content {
            case .text(let text):
                if let score = match(query: query, target: text) {
                    scored.append((.clip(clip), combinedScore(fuzzy: score, clip: clip)))
                }
            case .image(let meta):
                // 画像は originalFileName と ocrText（行単位）を検索対象にする
                var bestScore: Int?
                if let name = meta.originalFileName,
                   let s = match(query: query, target: name) {
                    bestScore = s
                }
                if let ocr = meta.ocrText,
                   let s = matchLines(query: query, target: ocr) {
                    bestScore = max(bestScore ?? 0, s)
                }
                if let s = bestScore {
                    scored.append((.clip(clip), combinedScore(fuzzy: s, clip: clip)))
                }
            case .file(let meta):
                if let score = match(query: query, target: meta.originalFileName) {
                    scored.append((.clip(clip), combinedScore(fuzzy: score, clip: clip)))
                }
            }
        }

        for snippet in activeSnippets {
            if let bestScore = bestSnippetScore(query: query, snippet: snippet) {
                scored.append((.snippet(snippet), Double(bestScore)))
            }
        }

        return scored.sorted { $0.score > $1.score }.map(\.item)
    }

    /// スニペットをフィルタリングし、スコア降順でソートして返す。
    /// tagFilters が指定された場合、全てのタグを持つスニペットのみ対象にする。
    public static func filterSnippets(query: String, snippets: [SnippetItem], tagFilters: [String] = []) -> [SnippetItem] {
        var items = snippets
        if !tagFilters.isEmpty {
            items = items.filter { snippet in
                tagFilters.allSatisfy { snippet.tags.contains($0) }
            }
        }
        if query.isEmpty { return items }
        return items
            .compactMap { snippet -> (item: SnippetItem, score: Int)? in
                guard let score = bestSnippetScore(query: query, snippet: snippet) else { return nil }
                return (snippet, score)
            }
            .sorted { $0.score > $1.score }
            .map(\.item)
    }

    /// クエリの各文字がターゲット内のどの位置にマッチしたかを返す。
    /// マッチしなければ nil。ハイライト表示に使用する。
    public static func matchPositions(query: String, target: String) -> [Int]? {
        let queryChars = Array(query.lowercased())
        let targetChars = Array(target.lowercased())
        var positions: [Int] = []
        var targetIdx = 0

        for queryChar in queryChars {
            var found = false
            while targetIdx < targetChars.count {
                if targetChars[targetIdx] == queryChar {
                    positions.append(targetIdx)
                    targetIdx += 1
                    found = true
                    break
                }
                targetIdx += 1
            }
            if !found { return nil }
        }
        return positions
    }

    /// OCR テキストを行単位で fuzzy match し、最もスコアの高い行のスコアを返す。
    /// 長いテキスト全体に対する fuzzy match だと文字がバラバラにヒットするため、
    /// 行単位でマッチさせることで "updateFilter" のような単語検索を正確にする。
    public static func matchLines(query: String, target: String) -> Int? {
        target.components(separatedBy: "\n")
            .compactMap { match(query: query, target: $0) }
            .max()
    }

    /// OCR テキストを行単位で fuzzy match し、最もスコアの高い行とそのマッチ位置を返す。
    /// ハイライト表示用。
    public static func bestMatchingLine(query: String, target: String) -> (line: String, positions: [Int])? {
        var bestLine: String?
        var bestPositions: [Int]?
        var bestScore = -1
        for line in target.components(separatedBy: "\n") {
            guard let positions = matchPositions(query: query, target: line) else { continue }
            // matchPositions が成功 = マッチ確定。連続一致ボーナスからスコアを計算。
            let score = consecutiveScore(positions)
            if score > bestScore {
                bestScore = score
                bestLine = line
                bestPositions = positions
            }
        }
        guard let line = bestLine, let positions = bestPositions else { return nil }
        return (line, positions)
    }

    /// マッチ位置列から連続一致ボーナスのスコアを計算する。
    /// match() と同じスコアリングロジック。
    private static func consecutiveScore(_ positions: [Int]) -> Int {
        var score = 0
        var consecutive = 0
        var prev = -2
        for pos in positions {
            consecutive = (pos == prev + 1) ? consecutive + 1 : 1
            score += consecutive
            prev = pos
        }
        return score
    }

    /// スニペットのタイトルマッチに加算するボーナス倍率。
    /// クエリ長 × この値を加算し、スニペットが優先的にヒットするようにする。
    private static let snippetTitleBonus = 3

    /// スニペットの title, content, tags からベストスコアを返す。
    /// タイトルマッチにはボーナスを加算し、スニペットが優先的にヒットするようにする。
    /// CLI の検索機能でも使用するため public。
    public static func bestSnippetScore(query: String, snippet: SnippetItem) -> Int? {
        let titleScore: Int? = match(query: query, target: snippet.title)
            .map { $0 + query.count * snippetTitleBonus }
        var scores: [Int?] = [titleScore]
        switch snippet.content {
        case .text(let text):
            scores.append(match(query: query, target: text))
        case .image(let meta):
            // スニペットは OCR 検索しない（タイトル・タグで十分検索できるため）
            if let name = meta.originalFileName {
                scores.append(match(query: query, target: name))
            }
        case .file(let meta):
            scores.append(match(query: query, target: meta.originalFileName))
        }
        for tag in snippet.tags {
            scores.append(match(query: query, target: tag))
        }
        return scores.compactMap { $0 }.max()
    }
}
