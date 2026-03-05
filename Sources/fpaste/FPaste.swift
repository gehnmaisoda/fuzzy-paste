import AppKit
import ArgumentParser
import Foundation
import FuzzyPasteCore
import ImageIO
import UniformTypeIdentifiers

@main
struct FPaste: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fpaste",
        abstract: "FuzzyPaste CLI — スニペットをターミナルから操作",
        subcommands: [List.self, Add.self, Remove.self, Search.self, Import.self, Export.self, History.self]
    )
}

// MARK: - 共通ファイル操作

/// 画像ファイルを images/ に保存し、サムネイルも生成して ImageMetadata を返す。
private func saveImageFile(path: String) throws -> ImageMetadata {
    let url = URL(fileURLWithPath: path)
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else {
        throw ValidationError("ファイルが見つかりません: \(path)")
    }

    let data = try Data(contentsOf: url)
    let imagesDir = AppPaths.appSupportDir.appendingPathComponent("images")
    let thumbsDir = imagesDir.appendingPathComponent("thumbs")
    try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)

    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ValidationError("画像ファイルを読み込めません: \(path)")
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw ValidationError("PNG への変換に失敗しました: \(path)")
    }

    let fileName = "\(UUID().uuidString).png"
    try pngData.write(to: imagesDir.appendingPathComponent(fileName), options: .atomic)

    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = props?[kCGImagePropertyPixelWidth] as? Int ?? cgImage.width
    let height = props?[kCGImagePropertyPixelHeight] as? Int ?? cgImage.height

    let thumbOpts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 512,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    if let pngSource = CGImageSourceCreateWithData(pngData as CFData, nil),
       let cgThumb = CGImageSourceCreateThumbnailAtIndex(pngSource, 0, thumbOpts as CFDictionary) {
        let thumbRep = NSBitmapImageRep(cgImage: cgThumb)
        if let thumbData = thumbRep.representation(using: .png, properties: [:]) {
            try? thumbData.write(to: thumbsDir.appendingPathComponent(fileName), options: .atomic)
        }
    }

    return ImageMetadata(
        fileName: fileName,
        originalUTType: resolveUTType(for: url),
        originalFileName: url.lastPathComponent,
        pixelWidth: width,
        pixelHeight: height,
        fileSizeBytes: Int64(pngData.count)
    )
}

/// ファイルを files/ にコピーして FileMetadata を返す。
private func saveGenericFile(path: String) throws -> FileMetadata {
    let url = URL(fileURLWithPath: path)
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else {
        throw ValidationError("ファイルが見つかりません: \(path)")
    }

    let data = try Data(contentsOf: url)
    let filesDir = AppPaths.appSupportDir.appendingPathComponent("files")
    try? fm.createDirectory(at: filesDir, withIntermediateDirectories: true)

    let ext = url.pathExtension.lowercased()
    let storedName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
    try data.write(to: filesDir.appendingPathComponent(storedName), options: .atomic)

    return FileMetadata(
        fileName: storedName,
        originalFileName: url.lastPathComponent,
        fileExtension: ext,
        utType: resolveUTType(for: url),
        fileSizeBytes: Int64(data.count)
    )
}

private func resolveUTType(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    if let type = UTType(filenameExtension: ext) {
        return type.identifier
    }
    return "public.data"
}

// MARK: - 共通フォーマット

private func formatSnippet(_ item: SnippetItem, score: Int? = nil) -> String {
    let tags = item.tags.isEmpty ? "" : " [\(item.tags.joined(separator: ", "))]"
    let scoreSuffix = score.map { "  (score: \($0))" } ?? ""
    let preview: String
    switch item.content {
    case .text(let text):
        preview = String(text.prefix(60)).replacingOccurrences(of: "\n", with: "\\n")
    case .image(let meta):
        let name = meta.originalFileName ?? meta.fileName
        preview = "[画像] \(name) \(meta.pixelWidth)×\(meta.pixelHeight)"
    case .file(let meta):
        preview = "[ファイル] \(meta.originalFileName)"
    }
    return "\(item.id)  \(item.title)\(tags)\(scoreSuffix)\n  \(preview)"
}

// MARK: - list

extension FPaste {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "スニペット一覧を表示")

        @Flag(name: .long, help: "JSON 形式で出力")
        var json = false

        func run() async throws {
            let store = await SnippetStore()
            let items = await store.items

            if items.isEmpty {
                print("スニペットがありません。")
                return
            }

            if json {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(items)
                print(String(data: data, encoding: .utf8)!)
            } else {
                for item in items {
                    print(formatSnippet(item))
                }
            }
        }
    }
}

// MARK: - add

extension FPaste {
    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "スニペットを追加（テキスト / 画像 / ファイル）",
            discussion: """
            テキスト、画像ファイル、または任意のファイルをスニペットとして登録します。
            --image / --file を指定しない場合はテキストスニペットとして登録します。

            使用例:
              fpaste add "挨拶文" "お疲れ様です" --tag メール --tag 定型文
              fpaste add "ロゴ画像" --image logo.png --tag デザイン
              fpaste add "設定ファイル" --file config.json --tag 設定
            """
        )

        @Argument(help: "スニペットのタイトル")
        var title: String

        @Argument(help: "スニペットの内容（テキストモード時。--image / --file 指定時は不要）")
        var content: String?

        @Option(name: .long, help: "画像ファイルのパス（PNG/JPEG 等）")
        var image: String?

        @Option(name: .long, help: "ファイルのパス（任意の拡張子）")
        var file: String?

        @Option(name: .long, help: "タグ（複数指定可）")
        var tag: [String] = []

        func validate() throws {
            let modes = [image != nil, file != nil, content != nil].filter { $0 }.count
            if modes == 0 {
                throw ValidationError("content, --image, --file のいずれかを指定してください")
            }
            if modes > 1 {
                throw ValidationError("content, --image, --file は同時に指定できません")
            }
        }

        func run() async throws {
            let store = await SnippetStore()
            let snippetContent: SnippetContent

            if let imagePath = image {
                snippetContent = .image(try saveImageFile(path: imagePath))
            } else if let filePath = file {
                snippetContent = .file(try saveGenericFile(path: filePath))
            } else if let content {
                snippetContent = .text(content)
            } else {
                throw ValidationError("content, --image, --file のいずれかを指定してください")
            }

            await store.add(title: title, content: snippetContent, tags: tag)
            print("追加しました: \(title)")
        }
    }
}

// MARK: - remove

extension FPaste {
    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "スニペットを UUID 指定で削除")

        @Argument(help: "削除するスニペットの UUID")
        var id: String

        func run() async throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("無効な UUID: \(id)")
            }
            let store = await SnippetStore()
            let before = await store.items.count
            await store.remove(id: uuid)
            let after = await store.items.count
            if before == after {
                throw ValidationError("該当するスニペットが見つかりません: \(id)")
            } else {
                print("削除しました: \(id)")
            }
        }
    }
}

// MARK: - search

extension FPaste {
    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "スニペットを fuzzy 検索")

        @Argument(help: "検索クエリ")
        var query: String

        func run() async throws {
            let store = await SnippetStore()
            let items = await store.items

            let results = items.compactMap { item -> (item: SnippetItem, score: Int)? in
                guard let score = FuzzyMatcher.bestSnippetScore(query: query, snippet: item) else { return nil }
                return (item, score)
            }.sorted { $0.score > $1.score }

            if results.isEmpty {
                print("マッチするスニペットがありません。")
                return
            }

            for (item, score) in results {
                print(formatSnippet(item, score: score))
            }
        }
    }
}

// MARK: - history

extension FPaste {
    struct History: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "クリップボード履歴を操作",
            discussion: """
            履歴の一覧表示・追加・全削除を行います。
            サブコマンドを省略すると一覧を表示します。

            使用例:
              fpaste history                          # 一覧表示
              fpaste history list --limit 5           # 最新5件を表示
              fpaste history add "コピーしたテキスト"
              fpaste history add --image screenshot.png
              fpaste history add --file report.pdf
              fpaste history clear                    # 全件削除
            """,
            subcommands: [HistoryList.self, HistoryAdd.self, HistoryClear.self],
            defaultSubcommand: HistoryList.self
        )
    }
}

extension FPaste.History {
    struct HistoryList: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "履歴一覧を表示"
        )

        @Option(name: .shortAndLong, help: "表示件数（省略時は全件）")
        var limit: Int?

        @Flag(name: .long, help: "JSON 形式で出力")
        var json = false

        func run() async throws {
            let store = await HistoryStore()
            let items = await store.items
            let displayed = limit.map { Array(items.prefix($0)) } ?? items

            if displayed.isEmpty {
                print("履歴がありません。")
                return
            }

            if json {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(displayed)
                print(String(data: data, encoding: .utf8)!)
            } else {
                for item in displayed {
                    print(formatClipItem(item))
                }
                if let limit, items.count > limit {
                    print("... 他 \(items.count - limit) 件")
                }
            }
        }
    }

    struct HistoryAdd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "履歴にアイテムを追加（テキスト / 画像 / ファイル）",
            discussion: """
            使用例:
              fpaste history add "コピーしたテキスト"
              fpaste history add --image screenshot.png
              fpaste history add --file report.pdf
            """
        )

        @Argument(help: "テキスト内容（--image / --file 指定時は不要）")
        var text: String?

        @Option(name: .long, help: "画像ファイルのパス（PNG/JPEG 等）")
        var image: String?

        @Option(name: .long, help: "ファイルのパス（任意の拡張子）")
        var file: String?

        func validate() throws {
            let modes = [text != nil, image != nil, file != nil].filter { $0 }.count
            if modes == 0 {
                throw ValidationError("text, --image, --file のいずれかを指定してください")
            }
            if modes > 1 {
                throw ValidationError("text, --image, --file は同時に指定できません")
            }
        }

        func run() async throws {
            let store = await HistoryStore()

            if let text {
                await store.add(text)
                print("履歴に追加しました（テキスト）")
            } else if let imagePath = image {
                let meta = try saveImageFile(path: imagePath)
                await store.addImage(meta)
                print("履歴に追加しました（画像: \(meta.pixelWidth)×\(meta.pixelHeight)）")
            } else if let filePath = file {
                let meta = try saveGenericFile(path: filePath)
                await store.addFile(meta)
                print("履歴に追加しました（ファイル: \(meta.originalFileName)）")
            }
        }
    }

    struct HistoryClear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear",
            abstract: "履歴を全件削除"
        )

        func run() async throws {
            let store = await HistoryStore()
            let count = await store.items.count
            if count == 0 {
                print("履歴は空です。")
                return
            }
            await store.clearAll()
            print("\(count) 件の履歴を削除しました。")
        }
    }
}

private func formatClipItem(_ item: ClipItem) -> String {
    let dateStr = ISO8601DateFormatter().string(from: item.copiedAt)
    let preview: String
    switch item.content {
    case .text(let text):
        preview = String(text.prefix(70)).replacingOccurrences(of: "\n", with: "\\n")
    case .image(let meta):
        let name = meta.originalFileName ?? meta.fileName
        preview = "[画像] \(name) \(meta.pixelWidth)×\(meta.pixelHeight)"
    case .file(let meta):
        preview = "[ファイル] \(meta.originalFileName)"
    }
    return "\(dateStr)  \(preview)"
}

// MARK: - import

extension FPaste {
    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "スニペットをインポート（ZIP バンドルまたは JSON）"
        )

        @Argument(help: "インポートするファイルのパス（.zip / .json / \"-\" で stdin JSON）")
        var file: String

        func run() async throws {
            let fm = FileManager.default
            let isBundle: Bool
            let jsonData: Data
            var bundleTempDir: URL?

            if file == "-" || file == "/dev/stdin" {
                isBundle = false
                jsonData = FileHandle.standardInput.readDataToEndOfFile()
            } else {
                let url = URL(fileURLWithPath: file)
                guard fm.fileExists(atPath: url.path) else {
                    throw ValidationError("ファイルが見つかりません: \(file)")
                }

                let ext = url.pathExtension.lowercased()
                isBundle = ext == "zip" || ext == "fuzzypaste"

                if isBundle {
                    let tempDir = fm.temporaryDirectory
                        .appendingPathComponent("FuzzyPaste-import-\(UUID().uuidString)")
                    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    bundleTempDir = tempDir

                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    proc.arguments = ["-x", "-k", url.path, tempDir.path]
                    try proc.run()
                    proc.waitUntilExit()
                    guard proc.terminationStatus == 0 else {
                        throw ValidationError("ZIP ファイルの展開に失敗しました")
                    }
                    let jsonURL = tempDir.appendingPathComponent("snippets.json")
                    guard fm.fileExists(atPath: jsonURL.path) else {
                        throw ValidationError("バンドル内に snippets.json が見つかりません")
                    }
                    jsonData = try Data(contentsOf: jsonURL)
                } else {
                    jsonData = try Data(contentsOf: url)
                }
            }

            defer { if let dir = bundleTempDir { try? fm.removeItem(at: dir) } }

            let store = await SnippetStore()
            let result = try await store.parseImportData(jsonData)

            // プレビュー表示
            print("--- インポートプレビュー ---")
            print("新規: \(result.new.count) 件")
            for item in result.new { print("  + \(item.title)") }
            print("重複 (スキップ): \(result.duplicates.count) 件")
            for item in result.duplicates { print("  = \(item.title)") }

            if !result.new.isEmpty {
                if let tempDir = bundleTempDir {
                    let mapping = copyBundleFiles(from: tempDir, items: result.new)
                    await store.importItems(result.new, fileNameMapping: mapping)
                } else {
                    await store.importItems(result.new)
                }
                print("\n\(result.new.count) 件インポートしました。")
            }
        }

        /// バンドルから画像・ファイルの実体をアプリのデータディレクトリにコピーし、ファイル名マッピングを返す。
        private func copyBundleFiles(from bundleDir: URL, items: [SnippetItem]) -> [String: String] {
            let fm = FileManager.default
            let base = AppPaths.appSupportDir
            let imagesDir = base.appendingPathComponent("images")
            let filesDir = base.appendingPathComponent("files")
            try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: filesDir, withIntermediateDirectories: true)

            let bundleImagesDir = bundleDir.appendingPathComponent("images")
            let bundleFilesDir = bundleDir.appendingPathComponent("files")

            var mapping: [String: String] = [:]
            for item in items {
                switch item.content {
                case .image(let meta):
                    let src = bundleImagesDir.appendingPathComponent(meta.fileName)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    let newName = "\(UUID().uuidString).png"
                    let dst = imagesDir.appendingPathComponent(newName)
                    try? fm.copyItem(at: src, to: dst)
                    mapping[meta.fileName] = newName
                case .file(let meta):
                    let src = bundleFilesDir.appendingPathComponent(meta.fileName)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    let ext = meta.fileExtension
                    let newName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
                    let dst = filesDir.appendingPathComponent(newName)
                    try? fm.copyItem(at: src, to: dst)
                    mapping[meta.fileName] = newName
                case .text:
                    break
                }
            }
            return mapping
        }
    }
}

// MARK: - export

extension FPaste {
    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "スニペットをエクスポート（ZIP バンドルまたは JSON）")

        @Option(name: .shortAndLong, help: "出力ファイルパス（省略時は stdout に JSON）")
        var output: String?

        func run() async throws {
            let store = await SnippetStore()
            let items = await store.items

            if items.isEmpty {
                print("エクスポートするスニペットがありません。")
                return
            }

            let hasMedia = items.contains {
                switch $0.content {
                case .image, .file: return true
                case .text: return false
                }
            }

            if let output = output, hasMedia {
                try await exportBundle(store: store, items: items, to: URL(fileURLWithPath: output))
                print("エクスポートしました: \(output)")
            } else {
                let data = try await store.exportData()
                if let output = output {
                    let url = URL(fileURLWithPath: output)
                    try data.write(to: url, options: .atomic)
                    print("エクスポートしました: \(output)")
                } else {
                    if hasMedia {
                        FileHandle.standardError.write(Data("警告: 画像/ファイルスニペットを含みますが、stdout には JSON のみ出力します。\nバンドル形式でエクスポートするには -o output.zip を指定してください。\n".utf8))
                    }
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
            }
        }

        private func exportBundle(store: SnippetStore, items: [SnippetItem], to url: URL) async throws {
            let fm = FileManager.default
            let base = AppPaths.appSupportDir
            let appImagesDir = base.appendingPathComponent("images")
            let appFilesDir = base.appendingPathComponent("files")

            let tempDir = fm.temporaryDirectory
                .appendingPathComponent("FuzzyPaste-export-\(UUID().uuidString)")
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempDir) }

            // snippets.json
            let jsonData = try await store.exportData()
            try jsonData.write(to: tempDir.appendingPathComponent("snippets.json"), options: .atomic)

            // 画像・ファイルの実体をコピー
            let bundleImagesDir = tempDir.appendingPathComponent("images")
            let bundleFilesDir = tempDir.appendingPathComponent("files")
            try? fm.createDirectory(at: bundleImagesDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: bundleFilesDir, withIntermediateDirectories: true)

            for item in items {
                switch item.content {
                case .image(let meta):
                    let src = appImagesDir.appendingPathComponent(meta.fileName)
                    if fm.fileExists(atPath: src.path) {
                        try fm.copyItem(at: src, to: bundleImagesDir.appendingPathComponent(meta.fileName))
                    }
                case .file(let meta):
                    let src = appFilesDir.appendingPathComponent(meta.fileName)
                    if fm.fileExists(atPath: src.path) {
                        try fm.copyItem(at: src, to: bundleFilesDir.appendingPathComponent(meta.fileName))
                    }
                case .text:
                    break
                }
            }

            // ditto で ZIP 作成
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-c", "-k", "--sequesterRsrc", tempDir.path, url.path]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw ValidationError("ZIP ファイルの作成に失敗しました")
            }
        }
    }
}
