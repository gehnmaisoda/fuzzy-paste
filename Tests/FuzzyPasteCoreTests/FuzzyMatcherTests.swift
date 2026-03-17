import Foundation
import Testing
@testable import FuzzyPasteCore

// MARK: - Test helpers

private func makeClip(_ text: String, useCount: Int = 0, lastUsedAt: Date? = nil) -> ClipItem {
    ClipItem(id: UUID(), content: .text(text), copiedAt: Date(), useCount: useCount, lastUsedAt: lastUsedAt)
}

private func makeSnippet(_ title: String, content: String = "content", tags: [String] = []) -> SnippetItem {
    SnippetItem(title: title, content: .text(content), tags: tags)
}

// MARK: - Fuzzy Match basics

struct FuzzyMatcherMatchTests {
    @Test("Exact match returns a score")
    func exactMatch() {
        let score = FuzzyMatcher.match(query: "hello", target: "hello")
        #expect(score != nil)
    }

    @Test("Matches when query chars appear in order")
    func partialMatch() {
        // "hlo" matches "hello world" (h...l...o in order)
        let score = FuzzyMatcher.match(query: "hlo", target: "hello world")
        #expect(score != nil)
    }

    @Test("Returns nil when a query char is missing from target")
    func noMatch() {
        let score = FuzzyMatcher.match(query: "xyz", target: "hello")
        #expect(score == nil)
    }

    @Test("Returns nil when query chars appear out of order")
    func wrongOrder() {
        // "olh" cannot be found in order within "hello"
        let score = FuzzyMatcher.match(query: "olh", target: "hello")
        #expect(score == nil)
    }

    @Test("Matching is case-insensitive")
    func caseInsensitive() {
        let score = FuzzyMatcher.match(query: "HELLO", target: "hello world")
        #expect(score != nil)
    }

    @Test("Empty query matches everything")
    func emptyQuery() {
        let score = FuzzyMatcher.match(query: "", target: "hello")
        #expect(score != nil)
    }

    @Test("Consecutive match scores higher than scattered match")
    func consecutiveBonusHigherScore() {
        let consecutive = FuzzyMatcher.match(query: "hel", target: "hello")!
        let scattered = FuzzyMatcher.match(query: "hlo", target: "hello world")!
        #expect(consecutive > scattered)
    }
}

// MARK: - Filtering

struct FuzzyMatcherFilterTests {
    @Test("Empty query returns all items unchanged")
    func emptyQueryReturnsAll() {
        let items = [makeClip("aaa"), makeClip("bbb")]
        let result = FuzzyMatcher.filter(query: "", items: items)
        #expect(result.count == 2)
    }

    @Test("Non-matching items are excluded")
    func filtersNonMatching() {
        let items = [makeClip("hello world"), makeClip("goodbye")]
        let result = FuzzyMatcher.filter(query: "hlo", items: items)
        #expect(result.count == 1)
        #expect(result[0].text == "hello world")
    }

    @Test("Items with more consecutive matches rank higher")
    func sortsByScore() {
        let items = [makeClip("h_e_l_l_o"), makeClip("hello")]
        let result = FuzzyMatcher.filter(query: "hello", items: items)
        #expect(result[0].text == "hello")
    }
}

// MARK: - Frecency score calculation

struct FrecencyScoreTests {
    @Test("Zero use count yields score 0")
    func zeroUseCount() {
        let score = FuzzyMatcher.frecencyScore(useCount: 0, lastUsedAt: Date())
        #expect(score == 0)
    }

    @Test("Nil lastUsedAt yields score 0")
    func nilLastUsedAt() {
        let score = FuzzyMatcher.frecencyScore(useCount: 5, lastUsedAt: nil)
        #expect(score == 0)
    }

    @Test("Just-used item score approximately equals useCount")
    func justUsed() {
        let score = FuzzyMatcher.frecencyScore(useCount: 10, lastUsedAt: Date())
        #expect(score > 9.9 && score <= 10.0)
    }

    @Test("Score halves after 72 hours")
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

    @Test("Score decays to 1/4 after 144 hours (2 half-lives)")
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

// MARK: - Frecency affects search ranking

struct FrecencyRankingTests {
    @Test("Frequently used item ranks higher with similar fuzzy scores")
    func frequentlyUsedItemRanksHigher() {
        let now = Date()
        let frequent = makeClip("apple pie recipe", useCount: 20, lastUsedAt: now)
        let unused = makeClip("apple juice recipe", useCount: 0)
        let results = FuzzyMatcher.filter(query: "apple", items: [unused, frequent])
        #expect(results[0].text == "apple pie recipe")
    }

    @Test("Old usage decays and loses priority")
    func oldUsageDecaysAndLosesPriority() {
        let now = Date()
        // 720 hours ago = 10 half-lives, so useCount 5 decays to ~0
        let oldFrequent = makeClip("apple pie recipe", useCount: 5,
                                   lastUsedAt: now.addingTimeInterval(-720 * 3600))
        let recentOnce = makeClip("apple juice recipe", useCount: 3, lastUsedAt: now)
        let results = FuzzyMatcher.filter(query: "apple", items: [oldFrequent, recentOnce])
        #expect(results[0].text == "apple juice recipe")
    }

    @Test("filterMixed also applies frecency to clips")
    func filterMixedAppliesFrecencyToClips() {
        let now = Date()
        let frequent = makeClip("git commit message", useCount: 15, lastUsedAt: now)
        let unused = makeClip("git commit hash", useCount: 0)
        let results = FuzzyMatcher.filterMixed(query: "git commit", clips: [unused, frequent], snippets: [])
        #expect(results[0].clipItem?.text == "git commit message")
    }

    @Test("Empty query ignores frecency and preserves array order")
    func emptyQueryIgnoresFrecency() {
        let now = Date()
        let first = makeClip("first item", useCount: 0)
        let second = makeClip("second item", useCount: 100, lastUsedAt: now)
        let results = FuzzyMatcher.filterMixed(query: "", clips: [first, second], snippets: [])
        #expect(results[0].clipItem?.text == "first item")
    }
}

// MARK: - matchPositions (highlight positions)

struct FuzzyMatcherMatchPositionsTests {
    @Test("Returns correct match positions")
    func basicPositions() {
        // "hlo" -> h(0), l(2), o(4) in "hello"
        let positions = FuzzyMatcher.matchPositions(query: "hlo", target: "hello")
        #expect(positions != nil)
        #expect(positions?[0] == 0) // h
        #expect(positions?[1] == 2) // l (first l)
        #expect(positions?[2] == 4) // o
    }

    @Test("Exact match returns consecutive positions")
    func exactMatchPositions() {
        let positions = FuzzyMatcher.matchPositions(query: "abc", target: "abc")
        #expect(positions == [0, 1, 2])
    }

    @Test("Returns nil on no match")
    func noMatchReturnsNil() {
        #expect(FuzzyMatcher.matchPositions(query: "xyz", target: "hello") == nil)
    }

    @Test("Position matching is case-insensitive")
    func caseInsensitive() {
        let positions = FuzzyMatcher.matchPositions(query: "AB", target: "ab")
        #expect(positions == [0, 1])
    }

    @Test("Empty query returns empty positions array")
    func emptyQuery() {
        let positions = FuzzyMatcher.matchPositions(query: "", target: "hello")
        #expect(positions == [])
    }
}

// MARK: - matchLines (OCR line-based matching)

struct FuzzyMatcherMatchLinesTests {
    @Test("Returns the best line score across multiple lines")
    func bestLineScore() {
        let text = "foo bar\nhello world\nbaz"
        let score = FuzzyMatcher.matchLines(query: "hello", target: text)
        #expect(score != nil)
        let directScore = FuzzyMatcher.match(query: "hello", target: "hello world")
        #expect(score == directScore)
    }

    @Test("Returns nil when no line matches")
    func noMatchReturnsNil() {
        let text = "aaa\nbbb\nccc"
        #expect(FuzzyMatcher.matchLines(query: "xyz", target: text) == nil)
    }

    @Test("Works with single-line text")
    func singleLine() {
        let score = FuzzyMatcher.matchLines(query: "hi", target: "hi there")
        #expect(score != nil)
    }
}

// MARK: - bestMatchingLine

struct FuzzyMatcherBestMatchingLineTests {
    @Test("Returns the best scoring line and its match positions")
    func returnsBestLine() {
        let text = "foo bar\nhello world\nbaz"
        let result = FuzzyMatcher.bestMatchingLine(query: "hello", target: text)
        #expect(result != nil)
        #expect(result?.line == "hello world")
        #expect(result?.positions.count == 5) // h, e, l, l, o
    }

    @Test("Returns nil when no line matches")
    func noMatchReturnsNil() {
        let text = "aaa\nbbb"
        #expect(FuzzyMatcher.bestMatchingLine(query: "xyz", target: text) == nil)
    }

    @Test("Prefers line with more consecutive matches")
    func prefersConsecutiveMatch() {
        let text = "h_e_l_l_o\nhello"
        let result = FuzzyMatcher.bestMatchingLine(query: "hello", target: text)
        #expect(result?.line == "hello")
    }
}

// MARK: - bestSnippetScore

struct FuzzyMatcherSnippetScoreTests {
    @Test("Title match receives a bonus over content match")
    func titleBonus() {
        let snippet = makeSnippet("hello", content: "hello")
        let score = FuzzyMatcher.bestSnippetScore(query: "hello", snippet: snippet)
        let plainScore = FuzzyMatcher.match(query: "hello", target: "hello")!
        #expect(score! > plainScore)
    }

    @Test("Matches against tags")
    func tagMatch() {
        let snippet = makeSnippet("no match here", content: "no match", tags: ["swift"])
        let score = FuzzyMatcher.bestSnippetScore(query: "swift", snippet: snippet)
        #expect(score != nil)
    }

    @Test("Returns nil when no field matches")
    func noMatch() {
        let snippet = makeSnippet("aaa", content: "bbb", tags: ["ccc"])
        #expect(FuzzyMatcher.bestSnippetScore(query: "xyz", snippet: snippet) == nil)
    }
}

// MARK: - filterSnippets

struct FuzzyMatcherFilterSnippetsTests {
    @Test("Empty query returns all snippets")
    func emptyQueryReturnsAll() {
        let snippets = [makeSnippet("a"), makeSnippet("b")]
        let result = FuzzyMatcher.filterSnippets(query: "", snippets: snippets)
        #expect(result.count == 2)
    }

    @Test("Tag filter narrows results")
    func tagFilter() {
        let snippets = [
            makeSnippet("a", tags: ["swift", "ios"]),
            makeSnippet("b", tags: ["swift"]),
            makeSnippet("c", tags: ["go"]),
        ]
        let result = FuzzyMatcher.filterSnippets(query: "", snippets: snippets, tagFilters: ["swift"])
        #expect(result.count == 2)
    }

    @Test("Multiple tag filters use AND logic")
    func multipleTagFilters() {
        let snippets = [
            makeSnippet("a", tags: ["swift", "ios"]),
            makeSnippet("b", tags: ["swift"]),
        ]
        let result = FuzzyMatcher.filterSnippets(query: "", snippets: snippets, tagFilters: ["swift", "ios"])
        #expect(result.count == 1)
        #expect(result[0].title == "a")
    }

    @Test("Non-matching snippets are excluded")
    func filtersNonMatching() {
        let snippets = [makeSnippet("hello world"), makeSnippet("goodbye")]
        let result = FuzzyMatcher.filterSnippets(query: "hello", snippets: snippets)
        #expect(result.count == 1)
        #expect(result[0].title == "hello world")
    }
}

// MARK: - filterMixed with tagFilters

struct FuzzyMatcherFilterMixedTagTests {
    @Test("Tag filter returns only snippets, excluding clips")
    func tagFilterExcludesClips() {
        let clips = [makeClip("hello")]
        let snippets = [makeSnippet("snippet", tags: ["tag1"])]
        let results = FuzzyMatcher.filterMixed(query: "", clips: clips, snippets: snippets, tagFilters: ["tag1"])
        #expect(results.count == 1)
        #expect(results[0].clipItem == nil) // snippet only
    }

    @Test("Tag filter combined with query filters and searches")
    func tagFilterWithQuery() {
        let snippets = [
            makeSnippet("hello world", tags: ["greet"]),
            makeSnippet("goodbye", tags: ["greet"]),
            makeSnippet("hello", tags: ["other"]),
        ]
        let results = FuzzyMatcher.filterMixed(query: "hello", clips: [], snippets: snippets, tagFilters: ["greet"])
        #expect(results.count == 1)
        #expect(results[0].text == "content") // "hello world" snippet's content
    }
}
