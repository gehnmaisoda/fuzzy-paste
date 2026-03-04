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
            abstract: "JSON ファイルからスニペットをインポート"
        )

        @Argument(help: "インポートする JSON ファイルのパス（\"-\" で stdin）")
        var file: String

        func run() async throws {
            // stdin またはファイルから Data を読み込み
            let data: Data
            if file == "-" || file == "/dev/stdin" {
                data = FileHandle.standardInput.readDataToEndOfFile()
            } else {
                let url = URL(fileURLWithPath: file)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ValidationError("ファイルが見つかりません: \(file)")
                }
                data = try Data(contentsOf: url)
            }

            let store = await SnippetStore()
            let result = try await store.parseImportData(data)

            // プレビュー表示
            print("--- インポートプレビュー ---")
            print("新規: \(result.new.count) 件")
            for item in result.new { print("  + \(item.title)") }
            print("重複 (スキップ): \(result.duplicates.count) 件")
            for item in result.duplicates { print("  = \(item.title)") }

            if !result.new.isEmpty {
                await store.importItems(result.new)
                print("\n\(result.new.count) 件インポートしました。")
            }
        }
    }
}

// MARK: - export

extension FPaste {
    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "スニペットを JSON エクスポート")

        @Option(name: .shortAndLong, help: "出力ファイルパス（省略時は stdout）")
        var output: String?

        func run() async throws {
            let store = await SnippetStore()
            let data = try await store.exportData()

            if let output = output {
                let url = URL(fileURLWithPath: output)
                try data.write(to: url, options: .atomic)
                print("エクスポートしました: \(output)")
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
    }
}
