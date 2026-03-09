import Foundation

/// CSV テキストのパースと判定を行うユーティリティ。
public enum CSVParser {
    /// パース結果。
    public struct Result: Sendable {
        public let headers: [String]
        public let rows: [[String]]
    }

    /// CSV として扱うファイル拡張子。
    public static let fileExtensions: Set<String> = ["csv", "tsv"]

    /// テキストが CSV として妥当なら判定とパースを一度に行い結果を返す。
    /// CSV でなければ nil を返す。
    public static func parseIfCSV(_ text: String) -> Result? {
        let lines = nonEmptyLines(text)
        guard lines.count >= 2 else { return nil }

        let delimiter = detectDelimiter(from: lines)
        let counts = lines.prefix(20).map { parseFields($0, delimiter: delimiter).count }
        guard let columnCount = counts.first, columnCount >= 2 else { return nil }

        let matching = counts.filter { $0 == columnCount }.count
        guard Double(matching) / Double(counts.count) >= 0.8 else { return nil }

        return buildResult(from: lines, delimiter: delimiter, columnCount: columnCount)
    }

    /// CSV テキストをパースする。1行目はヘッダーとして扱う。
    /// CSV 妥当性チェックが不要な場合に使用する。
    public static func parse(_ text: String) -> Result {
        let lines = nonEmptyLines(text)
        guard !lines.isEmpty else {
            return Result(headers: [], rows: [])
        }
        let delimiter = detectDelimiter(from: lines)
        let columnCount = parseFields(lines[0], delimiter: delimiter).count
        return buildResult(from: lines, delimiter: delimiter, columnCount: columnCount)
    }

    // MARK: - Private

    private static func nonEmptyLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 行分割済みのデータからヘッダー + 正規化済み行データを構築する。
    private static func buildResult(from lines: [String], delimiter: Character, columnCount: Int) -> Result {
        let headers = parseFields(lines[0], delimiter: delimiter)
        let rows = lines.dropFirst().map { line in
            let fields = parseFields(line, delimiter: delimiter)
            if fields.count < columnCount {
                return fields + Array(repeating: "", count: columnCount - fields.count)
            } else if fields.count > columnCount {
                return Array(fields.prefix(columnCount))
            }
            return fields
        }
        return Result(headers: headers, rows: rows)
    }

    /// カンマ・タブ・セミコロンから最も使われている区切り文字を推定する。
    private static func detectDelimiter(from lines: [String]) -> Character {
        let candidates: [Character] = [",", "\t", ";"]
        let sample = lines.prefix(5).joined(separator: "\n")
        var best: Character = ","
        var bestCount = 0
        for c in candidates {
            let count = sample.filter { $0 == c }.count
            if count > bestCount {
                bestCount = count
                best = c
            }
        }
        return best
    }

    /// RFC 4180 準拠の簡易フィールドパーサー。ダブルクォートに対応。
    private static func parseFields(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex

        while i < line.endIndex {
            let c = line[i]
            if inQuotes {
                if c == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex && line[next] == "\"" {
                        current.append("\"")
                        i = line.index(after: next)
                    } else {
                        inQuotes = false
                        i = line.index(after: i)
                    }
                } else {
                    current.append(c)
                    i = line.index(after: i)
                }
            } else if c == "\"" {
                inQuotes = true
                i = line.index(after: i)
            } else if c == delimiter {
                fields.append(current)
                current = ""
                i = line.index(after: i)
            } else {
                current.append(c)
                i = line.index(after: i)
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
