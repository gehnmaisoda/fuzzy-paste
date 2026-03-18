import Foundation
import Testing
@testable import FuzzyPasteCore

// MARK: - add (text dedup with snippetId awareness)

@MainActor
struct HistoryStoreAddTests {
    @Test("Adding duplicate text deduplicates and moves to front")
    func deduplicatesSameText() {
        let store = HistoryStore()
        store.clearAll()
        store.add("hello")
        store.add("world")
        store.add("hello")
        #expect(store.items.count == 2)
        #expect(store.items[0].text == "hello")
    }

    @Test("Adding text does not remove snippet marker with same text")
    func doesNotRemoveSnippetMarker() {
        let store = HistoryStore()
        store.clearAll()
        let snippetId = UUID()
        store.addSnippetUse(snippetId: snippetId)
        store.add("some text")
        // Both should exist
        #expect(store.items.count == 2)
        #expect(store.items[0].text == "some text")
        #expect(store.items[1].snippetId == snippetId)
    }

    @Test("Whitespace-only text is rejected")
    func rejectsWhitespaceOnly() {
        let store = HistoryStore()
        store.clearAll()
        store.add("   \n\t  ")
        #expect(store.items.isEmpty)
    }

    @Test("Deduplication preserves frecency data")
    func preservesFrecencyOnDedup() {
        let store = HistoryStore()
        store.clearAll()
        store.add("hello")
        store.recordUse(id: store.items[0].id)
        let useCount = store.items[0].useCount
        let lastUsed = store.items[0].lastUsedAt
        // Re-add same text
        store.add("hello")
        #expect(store.items[0].useCount == useCount)
        #expect(store.items[0].lastUsedAt == lastUsed)
    }
}

// MARK: - addSnippetUse

@MainActor
struct HistoryStoreSnippetUseTests {
    @Test("Creates a snippet marker entry")
    func createsMarker() {
        let store = HistoryStore()
        store.clearAll()
        let id = UUID()
        store.addSnippetUse(snippetId: id)
        #expect(store.items.count == 1)
        #expect(store.items[0].snippetId == id)
    }

    @Test("Duplicate snippetId moves to front and deduplicates")
    func deduplicatesBySnippetId() {
        let store = HistoryStore()
        store.clearAll()
        let id = UUID()
        store.addSnippetUse(snippetId: id)
        store.add("other text")
        store.addSnippetUse(snippetId: id)
        // Should be: [snippet marker, "other text"]
        #expect(store.items.count == 2)
        #expect(store.items[0].snippetId == id)
        #expect(store.items[1].text == "other text")
    }

    @Test("Preserves frecency data on re-add")
    func preservesFrecency() {
        let store = HistoryStore()
        store.clearAll()
        let id = UUID()
        store.addSnippetUse(snippetId: id)
        store.recordUse(id: store.items[0].id)
        let useCount = store.items[0].useCount
        // Re-add
        store.addSnippetUse(snippetId: id)
        #expect(store.items[0].useCount == useCount)
    }

    @Test("Different snippetIds are independent entries")
    func differentSnippetIds() {
        let store = HistoryStore()
        store.clearAll()
        let id1 = UUID()
        let id2 = UUID()
        store.addSnippetUse(snippetId: id1)
        store.addSnippetUse(snippetId: id2)
        #expect(store.items.count == 2)
        #expect(store.items[0].snippetId == id2)
        #expect(store.items[1].snippetId == id1)
    }
}

// MARK: - recordUse / recordUses

@MainActor
struct HistoryStoreRecordUseTests {
    @Test("recordUse increments useCount and sets lastUsedAt")
    func recordUseSingle() {
        let store = HistoryStore()
        store.clearAll()
        store.add("test")
        let id = store.items[0].id
        #expect(store.items[0].useCount == 0)
        #expect(store.items[0].lastUsedAt == nil)
        store.recordUse(id: id)
        #expect(store.items[0].useCount == 1)
        #expect(store.items[0].lastUsedAt != nil)
    }

    @Test("recordUses updates multiple items")
    func recordUsesMultiple() {
        let store = HistoryStore()
        store.clearAll()
        store.add("a")
        store.add("b")
        let ids = store.items.map(\.id)
        store.recordUses(ids: ids)
        #expect(store.items.allSatisfy { $0.useCount == 1 })
        #expect(store.items.allSatisfy { $0.lastUsedAt != nil })
    }

    @Test("recordUse with non-existent id is a no-op")
    func nonExistentIdIsNoop() {
        let store = HistoryStore()
        store.clearAll()
        store.add("test")
        store.recordUse(id: UUID())
        #expect(store.items[0].useCount == 0)
    }
}
