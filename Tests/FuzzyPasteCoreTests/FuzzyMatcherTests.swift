import Foundation
import Testing
@testable import FuzzyPasteCore

// MARK: - Fuzzy Match 基本動作

struct FuzzyMatcherMatchTests {
    @Test("完全一致する文字列はマッチする")
    func exactMatch() {
        let score = FuzzyMatcher.match(query: "hello", target: "hello")
        #expect(score != nil)
    }

    @Test("クエリの各文字が順番通りに含まれていればマッチする")
    func partialMatch() {
        // "hlo" → h...l...o の順で "hello world" に含まれる
        let score = FuzzyMatcher.match(query: "hlo", target: "hello world")
        #expect(score != nil)
    }

    @Test("対象文字列に含まれない文字があればマッチしない")
    func noMatch() {
        let score = FuzzyMatcher.match(query: "xyz", target: "hello")
        #expect(score == nil)
    }

    @Test("クエリの文字が順番通りでなければマッチしない")
    func wrongOrder() {
        // "olh" は hello 内で o→l→h の順に見つからない
        let score = FuzzyMatcher.match(query: "olh", target: "hello")
        #expect(score == nil)
    }

    @Test("大文字小文字を区別しない")
    func caseInsensitive() {
        let score = FuzzyMatcher.match(query: "HELLO", target: "hello world")
        #expect(score != nil)
    }

    @Test("空クエリは全てにマッチする")
    func emptyQuery() {
        let score = FuzzyMatcher.match(query: "", target: "hello")
        #expect(score != nil)
    }

    @Test("連続一致はバラバラ一致よりスコアが高い")
    func consecutiveBonusHigherScore() {
        // "hel" は "hello" で連続一致 → 高スコア
        // "hlo" は "hello world" で途切れる → 低スコア
        let consecutive = FuzzyMatcher.match(query: "hel", target: "hello")!
        let scattered = FuzzyMatcher.match(query: "hlo", target: "hello world")!
        #expect(consecutive > scattered)
    }
}

// MARK: - フィルタリング

struct FuzzyMatcherFilterTests {
    private func makeClip(_ text: String, useCount: Int = 0, lastUsedAt: Date? = nil) -> ClipItem {
        ClipItem(id: UUID(), content: .text(text), copiedAt: Date(), useCount: useCount, lastUsedAt: lastUsedAt)
    }

    @Test("空クエリは全件をそのまま返す")
    func emptyQueryReturnsAll() {
        let items = [makeClip("aaa"), makeClip("bbb")]
        let result = FuzzyMatcher.filter(query: "", items: items)
        #expect(result.count == 2)
    }

    @Test("マッチしないアイテムは除外される")
    func filtersNonMatching() {
        let items = [makeClip("hello world"), makeClip("goodbye")]
        let result = FuzzyMatcher.filter(query: "hlo", items: items)
        #expect(result.count == 1)
        #expect(result[0].text == "hello world")
    }

    @Test("連続一致が多いアイテムが上位にソートされる")
    func sortsByScore() {
        // "hello" は完全一致で高スコア、"h_e_l_l_o" はバラバラ一致で低スコア
        let items = [makeClip("h_e_l_l_o"), makeClip("hello")]
        let result = FuzzyMatcher.filter(query: "hello", items: items)
        #expect(result[0].text == "hello")
    }
}

// MARK: - Frecency スコア計算

struct FrecencyScoreTests {
    @Test("使用回数 0 のアイテムはスコア 0")
    func zeroUseCount() {
        let score = FuzzyMatcher.frecencyScore(useCount: 0, lastUsedAt: Date())
        #expect(score == 0)
    }

    @Test("lastUsedAt が nil のアイテムはスコア 0")
    func nilLastUsedAt() {
        let score = FuzzyMatcher.frecencyScore(useCount: 5, lastUsedAt: nil)
        #expect(score == 0)
    }

    @Test("直前に使ったアイテムは useCount がほぼそのままスコアになる")
    func justUsed() {
        let score = FuzzyMatcher.frecencyScore(useCount: 10, lastUsedAt: Date())
        #expect(score > 9.9 && score <= 10.0)
    }

    @Test("72 時間経過でスコアが半減する")
    func decaysOverTime() {
        let now = Date()
        let recent = FuzzyMatcher.frecencyScore(useCount: 10, lastUsedAt: now, now: now)
        let old = FuzzyMatcher.frecencyScore(
            useCount: 10,
            lastUsedAt: now.addingTimeInterval(-72 * 3600),
            now: now
        )
        #expect(recent > old)
        #expect(abs(old - 5.0) < 0.01)
    }

    @Test("144 時間（半減期 x 2）で 1/4 に減衰する")
    func halfLifeAt72Hours() {
        let now = Date()
        let score = FuzzyMatcher.frecencyScore(
            useCount: 100,
            lastUsedAt: now.addingTimeInterval(-144 * 3600),
            now: now
        )
        // 100 * (0.5)^2 = 25
        #expect(abs(score - 25.0) < 0.01)
    }
}

// MARK: - Frecency が検索順位に反映されることの検証

struct FrecencyRankingTests {
    private func makeClip(_ text: String, useCount: Int = 0, lastUsedAt: Date? = nil) -> ClipItem {
        ClipItem(id: UUID(), content: .text(text), copiedAt: Date(), useCount: useCount, lastUsedAt: lastUsedAt)
    }

    @Test("fuzzy スコアが同程度なら、使用頻度が高いアイテムが上位になる")
    func frequentlyUsedItemRanksHigher() {
        let now = Date()
        let frequent = makeClip("apple pie recipe", useCount: 20, lastUsedAt: now)
        let unused = makeClip("apple juice recipe", useCount: 0)
        let results = FuzzyMatcher.filter(query: "apple", items: [unused, frequent])
        #expect(results[0].text == "apple pie recipe")
    }

    @Test("長期間使われていないアイテムは減衰して順位が下がる")
    func oldUsageDecaysAndLosesPriority() {
        let now = Date()
        // 720 時間前 = 半減期 x 10 → 使用回数 5 のスコアはほぼ 0 に減衰
        let oldFrequent = makeClip("apple pie recipe", useCount: 5,
                                   lastUsedAt: now.addingTimeInterval(-720 * 3600))
        let recentOnce = makeClip("apple juice recipe", useCount: 3, lastUsedAt: now)
        let results = FuzzyMatcher.filter(query: "apple", items: [oldFrequent, recentOnce])
        #expect(results[0].text == "apple juice recipe")
    }

    @Test("filterMixed でもクリップに frecency が適用される")
    func filterMixedAppliesFrecencyToClips() {
        let now = Date()
        let frequent = makeClip("git commit message", useCount: 15, lastUsedAt: now)
        let unused = makeClip("git commit hash", useCount: 0)
        let results = FuzzyMatcher.filterMixed(query: "git commit", clips: [unused, frequent], snippets: [])
        #expect(results[0].clipItem?.text == "git commit message")
    }

    @Test("空クエリ時は frecency を無視して配列順（時系列）を維持する")
    func emptyQueryIgnoresFrecency() {
        let now = Date()
        let first = makeClip("first item", useCount: 0)
        let second = makeClip("second item", useCount: 100, lastUsedAt: now)
        let results = FuzzyMatcher.filterMixed(query: "", clips: [first, second], snippets: [])
        #expect(results[0].clipItem?.text == "first item")
    }
}
