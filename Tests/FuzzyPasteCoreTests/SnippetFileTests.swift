import Testing
import Foundation
@testable import FuzzyPasteCore

@Suite("SnippetFile")
struct SnippetFileTests {

    // MARK: - Parse

    @Test("Parse text snippet")
    func parseTextSnippet() {
        let content = """
        ---
        id: A1B2C3D4-E5F6-7890-ABCD-EF1234567890
        title: Hello
        tags: [tag1, tag2]
        created: 2024-01-15T10:30:00Z
        ---
        Body text here.
        """
        let item = SnippetFile.parse(content: content)
        #expect(item != nil)
        #expect(item!.id.uuidString == "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
        #expect(item!.title == "Hello")
        #expect(item!.tags == ["tag1", "tag2"])
        #expect(item!.text == "Body text here.")
    }

    @Test("Parse image snippet without assetsDir")
    func parseImageSnippetMinimal() {
        let content = """
        ---
        id: B2C3D4E5-F6A7-8901-BCDE-F12345678901
        title: Logo
        tags: [design]
        created: 2024-01-15T10:30:00Z
        asset: test-image.png
        ---
        """
        let item = SnippetFile.parse(content: content)
        #expect(item != nil)
        #expect(item!.title == "Logo")
        #expect(item!.imageMetadata != nil)
        #expect(item!.imageMetadata?.fileName == "test-image.png")
    }

    @Test("Parse file snippet without assetsDir")
    func parseFileSnippetMinimal() {
        let content = """
        ---
        id: C3D4E5F6-A7B8-9012-CDEF-123456789012
        title: Config
        tags: [config]
        created: 2024-01-15T10:30:00Z
        asset: settings.json
        ---
        """
        let item = SnippetFile.parse(content: content)
        #expect(item != nil)
        #expect(item!.fileMetadata != nil)
        #expect(item!.fileMetadata?.fileName == "settings.json")
        #expect(item!.fileMetadata?.fileExtension == "json")
    }

    @Test("Parse snippet with missing id generates UUID")
    func parseMissingId() {
        let content = """
        ---
        title: No ID
        ---
        Some text
        """
        let item = SnippetFile.parse(content: content)
        #expect(item != nil)
        #expect(item!.title == "No ID")
        #expect(item!.text == "Some text")
    }

    @Test("Parse snippet with no frontmatter")
    func parseNoFrontmatter() {
        let content = "Just plain text."
        let item = SnippetFile.parse(content: content)
        #expect(item != nil)
        #expect(item!.title == "")
        #expect(item!.text == "Just plain text.")
    }

    @Test("Parse with real asset file resolves metadata")
    func parseWithRealAsset() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetFileTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a minimal 1x1 PNG
        let pngData = createMinimalPNG()
        let assetPath = tempDir.appendingPathComponent("test.png")
        try pngData.write(to: assetPath)

        let content = """
        ---
        id: D4E5F6A7-B890-1234-CDEF-567890ABCDEF
        title: Test Image
        tags: []
        created: 2024-01-15T10:30:00Z
        asset: test.png
        ---
        """
        let item = SnippetFile.parse(content: content, assetsDir: tempDir)
        #expect(item != nil)
        #expect(item!.imageMetadata != nil)
        #expect(item!.imageMetadata!.pixelWidth == 1)
        #expect(item!.imageMetadata!.pixelHeight == 1)
        #expect(item!.imageMetadata!.fileSizeBytes > 0)
    }

    @Test("Parse with missing asset file falls back to text")
    func parseMissingAsset() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetFileTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let content = """
        ---
        title: Missing
        asset: nonexistent.png
        ---
        """
        let item = SnippetFile.parse(content: content, assetsDir: tempDir)
        #expect(item != nil)
        // Asset not found → falls back to text
        #expect(item!.text != nil)
    }

    // MARK: - Serialize

    @Test("Serialize text snippet")
    func serializeText() {
        let item = SnippetItem(
            id: UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!,
            title: "Test",
            content: .text("Hello World"),
            tags: ["a", "b"]
        )
        let result = SnippetFile.serialize(item: item)
        #expect(result.contains("id: A1B2C3D4-E5F6-7890-ABCD-EF1234567890"))
        #expect(result.contains("title: Test"))
        #expect(result.contains("tags: [a, b]"))
        #expect(result.contains("Hello World"))
    }

    @Test("Serialize image snippet")
    func serializeImage() {
        let meta = ImageMetadata(
            fileName: "abc.png",
            originalUTType: "public.png",
            originalFileName: nil,
            pixelWidth: 100, pixelHeight: 200,
            fileSizeBytes: 1024
        )
        let item = SnippetItem(title: "Img", content: .image(meta))
        let result = SnippetFile.serialize(item: item)
        #expect(result.contains("asset: abc.png"))
        // Body should be empty (no text content after ---)
        let parsed = FrontmatterParser.parse(result)
        #expect(parsed.body == "")
    }

    @Test("Serialize file snippet")
    func serializeFile() {
        let meta = FileMetadata(
            fileName: "doc.pdf",
            originalFileName: "report.pdf",
            fileExtension: "pdf",
            utType: "com.adobe.pdf",
            fileSizeBytes: 2048
        )
        let item = SnippetItem(title: "PDF", content: .file(meta))
        let result = SnippetFile.serialize(item: item)
        #expect(result.contains("asset: doc.pdf"))
    }

    @Test("Serialize round-trip for text snippet")
    func roundTripText() {
        let original = SnippetItem(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "テスト",
            content: .text("こんにちは\n\n世界"),
            tags: ["jp", "test"]
        )
        let serialized = SnippetFile.serialize(item: original)
        let parsed = SnippetFile.parse(content: serialized)
        #expect(parsed != nil)
        #expect(parsed!.id == original.id)
        #expect(parsed!.title == original.title)
        #expect(parsed!.text == "こんにちは\n\n世界")
        #expect(parsed!.tags == original.tags)
    }

    // MARK: - Filename

    @Test("fileName generates slug.md")
    func fileNameBasic() {
        let item = SnippetItem(title: "Hello World", content: .text(""))
        #expect(SnippetFile.fileName(for: item) == "Hello-World.md")
    }

    @Test("fileName with Japanese title")
    func fileNameJapanese() {
        let item = SnippetItem(title: "メール返信", content: .text(""))
        #expect(SnippetFile.fileName(for: item) == "メール返信.md")
    }

    @Test("uniqueFileName avoids collision")
    func uniqueFileNameCollision() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetFileTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create existing file
        try "".write(to: tempDir.appendingPathComponent("Test.md"), atomically: true, encoding: .utf8)

        let item = SnippetItem(title: "Test", content: .text(""))
        let name = SnippetFile.uniqueFileName(for: item, in: tempDir)
        #expect(name == "Test-2.md")
    }

    // MARK: - Helpers

    /// Create a minimal valid 1x1 PNG for testing.
    private func createMinimalPNG() -> Data {
        // Minimal 1x1 white PNG
        let bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, // 8-bit RGB
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, // IDAT chunk
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC,
            0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, // IEND chunk
            0x44, 0xAE, 0x42, 0x60, 0x82,
        ]
        return Data(bytes)
    }
}
