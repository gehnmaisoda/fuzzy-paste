import Foundation
import Testing
@testable import FuzzyPasteCore

// MARK: - parseIfCSV

struct CSVParserParseIfCSVTests {
    @Test("Parses a basic comma-delimited CSV with 2+ rows")
    func basicCSV() {
        let csv = "name,age\nAlice,30\nBob,25"
        let result = CSVParser.parseIfCSV(csv)
        #expect(result != nil)
        #expect(result?.headers == ["name", "age"])
        #expect(result?.rows.count == 2)
        #expect(result?.rows[0] == ["Alice", "30"])
        #expect(result?.rows[1] == ["Bob", "25"])
    }

    @Test("Single line is not valid CSV")
    func singleLineNotCSV() {
        let result = CSVParser.parseIfCSV("name,age")
        #expect(result == nil)
    }

    @Test("Fewer than 2 columns is not valid CSV")
    func singleColumnNotCSV() {
        let csv = "name\nAlice\nBob"
        let result = CSVParser.parseIfCSV(csv)
        #expect(result == nil)
    }

    @Test("Empty string is not valid CSV")
    func emptyString() {
        #expect(CSVParser.parseIfCSV("") == nil)
    }

    @Test("Blank lines only is not valid CSV")
    func onlyBlankLines() {
        #expect(CSVParser.parseIfCSV("\n\n  \n") == nil)
    }

    @Test("Rejects CSV when column count consistency is below 80%")
    func inconsistentColumnCount() {
        // 5 lines: line 1 has 3 cols, rest have 2 -> consistency 1/5 = 20%
        let csv = "a,b,c\n1,2\n3,4\n5,6\n7,8"
        let result = CSVParser.parseIfCSV(csv)
        #expect(result == nil)
    }

    @Test("Accepts CSV when column count consistency is at least 80%")
    func consistentEnough() {
        // 5 lines: 4 have 3 cols, 1 has 2 -> consistency 80%
        let csv = "a,b,c\n1,2,3\n4,5,6\n7,8,9\n10,11"
        let result = CSVParser.parseIfCSV(csv)
        #expect(result != nil)
    }
}

// MARK: - parse

struct CSVParserParseTests {
    @Test("First row becomes headers")
    func headerAndRows() {
        let csv = "h1,h2\nv1,v2"
        let result = CSVParser.parse(csv)
        #expect(result.headers == ["h1", "h2"])
        #expect(result.rows == [["v1", "v2"]])
    }

    @Test("Empty text produces empty result")
    func emptyText() {
        let result = CSVParser.parse("")
        #expect(result.headers.isEmpty)
        #expect(result.rows.isEmpty)
    }
}

// MARK: - Delimiter auto-detection

struct CSVParserDelimiterTests {
    @Test("Auto-detects tab delimiter")
    func tabDelimiter() {
        let tsv = "name\tage\nAlice\t30\nBob\t25"
        let result = CSVParser.parseIfCSV(tsv)
        #expect(result != nil)
        #expect(result?.headers == ["name", "age"])
        #expect(result?.rows[0] == ["Alice", "30"])
    }

    @Test("Auto-detects semicolon delimiter")
    func semicolonDelimiter() {
        let csv = "name;age\nAlice;30\nBob;25"
        let result = CSVParser.parseIfCSV(csv)
        #expect(result != nil)
        #expect(result?.headers == ["name", "age"])
    }
}

// MARK: - Double-quote handling (RFC 4180)

struct CSVParserQuoteTests {
    @Test("Comma inside quotes is part of the field")
    func commaInQuotes() {
        let csv = "name,address\n\"Doe, John\",Tokyo"
        let result = CSVParser.parse(csv)
        #expect(result.rows[0][0] == "Doe, John")
    }

    @Test("Escaped double quotes are unescaped")
    func escapedQuote() {
        let csv = "name,note\nAlice,\"She said \"\"hello\"\"\""
        let result = CSVParser.parse(csv)
        #expect(result.rows[0][1] == "She said \"hello\"")
    }
}

// MARK: - Column count normalization

struct CSVParserNormalizationTests {
    @Test("Short rows are padded with empty strings")
    func shortRowPadded() {
        let csv = "a,b,c\n1,2"
        let result = CSVParser.parse(csv)
        #expect(result.rows[0] == ["1", "2", ""])
    }

    @Test("Long rows are truncated to header column count")
    func longRowTruncated() {
        let csv = "a,b\n1,2,3,4"
        let result = CSVParser.parse(csv)
        #expect(result.rows[0] == ["1", "2"])
    }
}
