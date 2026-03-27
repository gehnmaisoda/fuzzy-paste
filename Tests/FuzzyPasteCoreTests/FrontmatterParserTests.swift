import Testing
@testable import FuzzyPasteCore

@Suite("FrontmatterParser")
struct FrontmatterParserTests {

    // MARK: - Parse

    @Test("Parse text snippet with all fields")
    func parseFullFrontmatter() {
        let content = """
        ---
        id: a1b2c3d4-e5f6-7890-abcd-ef1234567890
        title: Hello World
        tags: [tag1, tag2]
        created: 2024-01-15T10:30:00Z
        ---
        Body text here.
        """
        let result = FrontmatterParser.parse(content)
        #expect(result.fields["id"] == "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        #expect(result.fields["title"] == "Hello World")
        #expect(result.fields["tags"] == "[tag1, tag2]")
        #expect(result.fields["created"] == "2024-01-15T10:30:00Z")
        #expect(result.body == "Body text here.")
    }

    @Test("Parse image snippet with asset field")
    func parseImageSnippet() {
        let content = """
        ---
        id: b2c3d4e5-f6a7-8901-bcde-f12345678901
        title: Logo
        tags: [design]
        created: 2024-01-15T10:30:00Z
        asset: b2c3d4e5.png
        ---
        """
        let result = FrontmatterParser.parse(content)
        #expect(result.fields["asset"] == "b2c3d4e5.png")
        #expect(result.body == "")
    }

    @Test("Parse file with no frontmatter")
    func parseNoFrontmatter() {
        let content = "Just plain text\nwithout frontmatter."
        let result = FrontmatterParser.parse(content)
        #expect(result.fields.isEmpty)
        #expect(result.body == content)
    }

    @Test("Parse file with empty frontmatter")
    func parseEmptyFrontmatter() {
        let content = """
        ---
        ---
        Body only.
        """
        let result = FrontmatterParser.parse(content)
        #expect(result.fields.isEmpty)
        #expect(result.body == "Body only.")
    }

    @Test("Parse unclosed frontmatter treats as no frontmatter")
    func parseUnclosedFrontmatter() {
        let content = """
        ---
        title: Test
        No closing delimiter
        """
        let result = FrontmatterParser.parse(content)
        #expect(result.fields.isEmpty)
        #expect(result.body == content)
    }

    @Test("Body containing --- is not confused with frontmatter delimiter")
    func parseBodyWithHorizontalRule() {
        let content = """
        ---
        title: Test
        ---
        Some text
        ---
        More text after rule
        """
        let result = FrontmatterParser.parse(content)
        #expect(result.fields["title"] == "Test")
        #expect(result.body == "Some text\n---\nMore text after rule")
    }

    @Test("Title containing colon is parsed correctly")
    func parseTitleWithColon() {
        let content = """
        ---
        title: Hello: World: Test
        ---
        Body
        """
        let result = FrontmatterParser.parse(content)
        #expect(result.fields["title"] == "Hello: World: Test")
    }

    @Test("Multiline body with blank lines is preserved")
    func parseMultilineBody() {
        let content = """
        ---
        title: Test
        ---
        Line 1

        Line 3
        """
        let result = FrontmatterParser.parse(content)
        #expect(result.body == "Line 1\n\nLine 3")
    }

    // MARK: - Serialize

    @Test("Serialize produces valid frontmatter + body")
    func serializeBasic() {
        let fields: [String: String] = [
            "id": "abc-123",
            "title": "Test",
            "tags": "[tag1]",
            "created": "2024-01-01T00:00:00Z",
        ]
        let result = FrontmatterParser.serialize(fields: fields, body: "Hello")
        #expect(result.hasPrefix("---\n"))
        #expect(result.contains("id: abc-123\n"))
        #expect(result.contains("title: Test\n"))
        #expect(result.contains("Hello\n"))
    }

    @Test("Serialize with empty body omits body section")
    func serializeEmptyBody() {
        let fields: [String: String] = ["id": "abc", "title": "T"]
        let result = FrontmatterParser.serialize(fields: fields, body: "")
        #expect(result.hasSuffix("---\n"))
    }

    @Test("Serialize field ordering: id, title, tags, created, asset")
    func serializeFieldOrder() {
        let fields: [String: String] = [
            "asset": "file.png",
            "created": "2024-01-01T00:00:00Z",
            "id": "abc",
            "tags": "[]",
            "title": "Test",
        ]
        let result = FrontmatterParser.serialize(fields: fields, body: "")
        let lines = result.components(separatedBy: "\n")
        // lines[0] = "---", then ordered fields
        #expect(lines[1].hasPrefix("id:"))
        #expect(lines[2].hasPrefix("title:"))
        #expect(lines[3].hasPrefix("tags:"))
        #expect(lines[4].hasPrefix("created:"))
        #expect(lines[5].hasPrefix("asset:"))
    }

    @Test("Serialize round-trip preserves fields and body")
    func serializeRoundTrip() {
        let fields: [String: String] = [
            "id": "a1b2c3d4",
            "title": "テスト",
            "tags": "[a, b]",
            "created": "2024-01-15T10:30:00Z",
        ]
        let body = "こんにちは\n\n世界"
        let serialized = FrontmatterParser.serialize(fields: fields, body: body)
        let parsed = FrontmatterParser.parse(serialized)
        #expect(parsed.fields["id"] == "a1b2c3d4")
        #expect(parsed.fields["title"] == "テスト")
        #expect(parsed.fields["tags"] == "[a, b]")
        #expect(parsed.body == body)
    }

    // MARK: - Tags

    @Test("Parse tags with brackets")
    func parseTagsBasic() {
        let tags = FrontmatterParser.parseTags("[tag1, tag2, tag3]")
        #expect(tags == ["tag1", "tag2", "tag3"])
    }

    @Test("Parse empty tags")
    func parseTagsEmpty() {
        #expect(FrontmatterParser.parseTags("[]") == [])
        #expect(FrontmatterParser.parseTags("") == [])
    }

    @Test("Parse tags with quotes")
    func parseTagsQuoted() {
        let tags = FrontmatterParser.parseTags("[\"tag with spaces\", 'another']")
        #expect(tags == ["tag with spaces", "another"])
    }

    @Test("Serialize tags")
    func serializeTags() {
        #expect(FrontmatterParser.serializeTags(["a", "b"]) == "[a, b]")
        #expect(FrontmatterParser.serializeTags([]) == "[]")
    }

    // MARK: - Slug

    @Test("Slug from ASCII title")
    func slugAscii() {
        #expect(FrontmatterParser.slug(from: "Hello World") == "Hello-World")
    }

    @Test("Slug from Japanese title")
    func slugJapanese() {
        #expect(FrontmatterParser.slug(from: "メール返信テンプレート") == "メール返信テンプレート")
    }

    @Test("Slug from empty title")
    func slugEmpty() {
        #expect(FrontmatterParser.slug(from: "") == "untitled")
        #expect(FrontmatterParser.slug(from: "   ") == "untitled")
    }

    @Test("Slug replaces filesystem-unsafe characters")
    func slugUnsafeChars() {
        #expect(FrontmatterParser.slug(from: "a/b:c") == "a-b-c")
    }

    @Test("Slug collapses consecutive hyphens")
    func slugCollapseHyphens() {
        #expect(FrontmatterParser.slug(from: "a - - b") == "a-b")
    }

    @Test("Slug truncates long titles to 50 characters")
    func slugLongTitle() {
        let long = String(repeating: "a", count: 100)
        let slug = FrontmatterParser.slug(from: long)
        #expect(slug.count <= 50)
    }
}
