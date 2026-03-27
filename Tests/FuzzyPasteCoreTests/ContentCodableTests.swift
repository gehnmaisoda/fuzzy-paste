import Testing
import Foundation
@testable import FuzzyPasteCore

// MARK: - ClipContent

@Suite("ClipContent Codable")
struct ClipContentCodableTests {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: Encode

    @Test("Encode text produces flat format")
    func encodeText() throws {
        let content = ClipContent.text("hello")
        let json = try jsonObject(content)
        #expect(json["text"] as? String == "hello")
    }

    @Test("Encode image produces flat format without _0 wrapper")
    func encodeImage() throws {
        let meta = ImageMetadata(fileName: "a.png", originalUTType: "public.png",
                                 originalFileName: nil, pixelWidth: 100, pixelHeight: 200,
                                 fileSizeBytes: 1024)
        let content = ClipContent.image(meta)
        let json = try jsonObject(content)
        let imageDict = try #require(json["image"] as? [String: Any])
        #expect(imageDict["fileName"] as? String == "a.png")
        #expect(imageDict["_0"] == nil)
    }

    @Test("Encode file produces flat format without _0 wrapper")
    func encodeFile() throws {
        let meta = FileMetadata(fileName: "b.pdf", originalFileName: "doc.pdf",
                                fileExtension: "pdf", utType: "com.adobe.pdf",
                                fileSizeBytes: 2048)
        let content = ClipContent.file(meta)
        let json = try jsonObject(content)
        let fileDict = try #require(json["file"] as? [String: Any])
        #expect(fileDict["fileName"] as? String == "b.pdf")
        #expect(fileDict["_0"] == nil)
    }

    // MARK: Decode

    @Test("Decode text")
    func decodeText() throws {
        let json = #"{"text":"hello"}"#
        let content = try decoder.decode(ClipContent.self, from: Data(json.utf8))
        #expect(content == .text("hello"))
    }

    @Test("Decode image")
    func decodeImage() throws {
        let json = """
        {"image":{"fileName":"a.png","originalUTType":"public.png","pixelWidth":100,"pixelHeight":200,"fileSizeBytes":1024}}
        """
        let content = try decoder.decode(ClipContent.self, from: Data(json.utf8))
        if case .image(let meta) = content {
            #expect(meta.fileName == "a.png")
            #expect(meta.pixelWidth == 100)
        } else {
            Issue.record("Expected .image")
        }
    }

    @Test("Decode file")
    func decodeFile() throws {
        let json = """
        {"file":{"fileName":"b.pdf","originalFileName":"doc.pdf","fileExtension":"pdf","utType":"com.adobe.pdf","fileSizeBytes":2048}}
        """
        let content = try decoder.decode(ClipContent.self, from: Data(json.utf8))
        if case .file(let meta) = content {
            #expect(meta.fileName == "b.pdf")
            #expect(meta.originalFileName == "doc.pdf")
        } else {
            Issue.record("Expected .file")
        }
    }

    // MARK: Round-trip

    @Test("Round-trip preserves all content types")
    func roundTrip() throws {
        let cases: [ClipContent] = [
            .text("test string"),
            .image(ImageMetadata(fileName: "x.png", originalUTType: "public.png",
                                 originalFileName: "photo.png", pixelWidth: 640, pixelHeight: 480,
                                 fileSizeBytes: 4096, ocrText: "detected")),
            .file(FileMetadata(fileName: "y.csv", originalFileName: "data.csv",
                               fileExtension: "csv", utType: "public.comma-separated-values-text",
                               fileSizeBytes: 512)),
        ]
        for original in cases {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(ClipContent.self, from: data)
            #expect(decoded == original)
        }
    }

    private func jsonObject(_ content: ClipContent) throws -> [String: Any] {
        let data = try encoder.encode(content)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - SnippetContent

@Suite("SnippetContent Codable")
struct SnippetContentCodableTests {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: Encode

    @Test("Encode text produces flat format")
    func encodeText() throws {
        let content = SnippetContent.text("snippet")
        let data = try encoder.encode(content)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["text"] as? String == "snippet")
    }

    // MARK: Decode

    @Test("Decode image")
    func decodeImage() throws {
        let json = """
        {"image":{"fileName":"a.png","originalUTType":"public.png","pixelWidth":10,"pixelHeight":10,"fileSizeBytes":100}}
        """
        let content = try decoder.decode(SnippetContent.self, from: Data(json.utf8))
        if case .image(let meta) = content {
            #expect(meta.fileName == "a.png")
        } else {
            Issue.record("Expected .image")
        }
    }

    @Test("Decode file")
    func decodeFile() throws {
        let json = """
        {"file":{"fileName":"b.pdf","originalFileName":"doc.pdf","fileExtension":"pdf","utType":"com.adobe.pdf","fileSizeBytes":200}}
        """
        let content = try decoder.decode(SnippetContent.self, from: Data(json.utf8))
        if case .file(let meta) = content {
            #expect(meta.fileName == "b.pdf")
        } else {
            Issue.record("Expected .file")
        }
    }

    // MARK: Round-trip

    @Test("Round-trip preserves all content types")
    func roundTrip() throws {
        let cases: [SnippetContent] = [
            .text("hello"),
            .image(ImageMetadata(fileName: "x.png", originalUTType: "public.png",
                                 originalFileName: nil, pixelWidth: 320, pixelHeight: 240,
                                 fileSizeBytes: 1024)),
            .file(FileMetadata(fileName: "y.json", originalFileName: "config.json",
                               fileExtension: "json", utType: "public.json",
                               fileSizeBytes: 256)),
        ]
        for original in cases {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(SnippetContent.self, from: data)
            #expect(decoded == original)
        }
    }
}
