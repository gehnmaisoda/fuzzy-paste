import Foundation

/// Markdown + YAML frontmatter のパース・シリアライズを行うユーティリティ。
/// 外部ライブラリ不使用。frontmatter は単純な key:value 形式のみサポート。
public enum FrontmatterParser {

    /// パース結果。frontmatter の key-value ペアと body テキスト。
    public struct ParseResult: Sendable {
        public let fields: [String: String]
        public let body: String
    }

    // MARK: - Parse

    /// Markdown ファイルの内容をパースし、frontmatter fields と body を返す。
    /// frontmatter がない場合は fields を空、body を全文として返す。
    public static func parse(_ content: String) -> ParseResult {
        let delimiter = "---"
        let lines = content.components(separatedBy: "\n")

        // 先頭行が "---" でなければ frontmatter なし
        guard let firstLine = lines.first, firstLine.trimmingCharacters(in: .whitespaces) == delimiter else {
            return ParseResult(fields: [:], body: content)
        }

        // 2 行目以降で閉じる "---" を探す
        var closingIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == delimiter {
                closingIndex = i
                break
            }
        }

        guard let endIndex = closingIndex else {
            // 閉じ "---" が見つからなければ frontmatter なし扱い
            return ParseResult(fields: [:], body: content)
        }

        // frontmatter 部分をパース
        let frontmatterLines = Array(lines[1..<endIndex])
        let fields = parseFields(frontmatterLines)

        // body: 閉じ "---" の次の行から末尾まで
        let bodyLines = Array(lines[(endIndex + 1)...])
        let body = trimBody(bodyLines.joined(separator: "\n"))

        return ParseResult(fields: fields, body: body)
    }

    // MARK: - Serialize

    /// fields と body から Markdown + frontmatter 文字列を生成する。
    /// fields の出力順序: id, title, tags, created, asset の順（存在するもののみ）。
    public static func serialize(fields: [String: String], body: String) -> String {
        var lines = ["---"]

        // 出力順序を固定
        let orderedKeys = ["id", "title", "tags", "created", "asset"]
        for key in orderedKeys {
            if let value = fields[key] {
                lines.append("\(key): \(value)")
            }
        }
        // orderedKeys に含まれない追加フィールドがあればアルファベット順で出力
        let extraKeys = fields.keys.filter { !orderedKeys.contains($0) }.sorted()
        for key in extraKeys {
            if let value = fields[key] {
                lines.append("\(key): \(value)")
            }
        }

        lines.append("---")

        if !body.isEmpty {
            lines.append(body)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Tags

    /// `[tag1, tag2, tag3]` 形式の文字列をパースして配列を返す。
    public static func parseTags(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else {
            // ブラケットなし → 単一タグまたは空
            return trimmed.isEmpty ? [] : [trimmed]
        }

        let inner = String(trimmed.dropFirst().dropLast())
        if inner.trimmingCharacters(in: .whitespaces).isEmpty {
            return []
        }

        return inner.components(separatedBy: ",").map { tag in
            tag.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }.filter { !$0.isEmpty }
    }

    /// タグ配列を `[tag1, tag2]` 形式の文字列にシリアライズする。
    public static func serializeTags(_ tags: [String]) -> String {
        "[\(tags.joined(separator: ", "))]"
    }

    // MARK: - Slug

    /// タイトルからファイルシステム安全な slug を生成する。
    /// CJK 文字はそのまま保持し、ファイルシステム不正文字のみ除去する。
    public static func slug(from title: String) -> String {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "untitled"
        }

        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // ファイルシステム不正文字を置換 (macOS: / と : が不正)
        let illegal = CharacterSet(charactersIn: "/:\\\0")
        result = result.unicodeScalars
            .map { illegal.contains($0) ? "-" : String($0) }
            .joined()

        // スペースをハイフンに
        result = result.replacingOccurrences(of: " ", with: "-")
        // 連続ハイフンを1つに
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        // 先頭末尾のハイフンを除去
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // 50文字に制限
        if result.count > 50 {
            result = String(result.prefix(50))
            result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        return result.isEmpty ? "untitled" : result
    }

    // MARK: - Private

    /// frontmatter 行を key:value にパースする。
    /// 最初の `:` でキーと値を分割する（値に `:` が含まれていても安全）。
    private static func parseFields(_ lines: [String]) -> [String: String] {
        var fields: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                fields[key] = value
            }
        }
        return fields
    }

    /// body の先頭・末尾の空行を除去する（行内の空行は保持）。
    private static func trimBody(_ body: String) -> String {
        // 先頭の改行を1つだけ除去
        var result = body
        if result.hasPrefix("\n") {
            result = String(result.dropFirst())
        }
        // 末尾の改行・空白を除去
        while result.hasSuffix("\n") || result.hasSuffix(" ") {
            result = String(result.dropLast())
        }
        return result
    }
}
