import ArgumentParser
import Foundation
import FuzzyPasteCore

@main
struct FPaste: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fpaste",
        abstract: "FuzzyPaste CLI — スニペットをターミナルから操作",
        subcommands: [List.self, Add.self, Remove.self, Search.self, Import.self, Export.self]
    )
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
        static let configuration = CommandConfiguration(abstract: "スニペットを追加")

        @Argument(help: "スニペットのタイトル")
        var title: String

        @Argument(help: "スニペットの内容")
        var content: String

        @Option(name: .long, help: "タグ（複数指定可）")
        var tag: [String] = []

        func run() async throws {
            let store = await SnippetStore()
            await store.add(title: title, content: .text(content), tags: tag)
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
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let base = appSupport.appendingPathComponent("FuzzyPaste")
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
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let base = appSupport.appendingPathComponent("FuzzyPaste")
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
