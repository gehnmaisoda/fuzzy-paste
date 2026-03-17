import Foundation
import Testing
@testable import FuzzyPasteCore

// MARK: - hasDynamicPlaceholders

struct PlaceholderParserDetectionTests {
    @Test("Detects placeholder in string")
    func detectsPlaceholder() {
        #expect(PlaceholderParser.hasDynamicPlaceholders(in: "Hello {{name}}!"))
    }

    @Test("Returns false when no placeholder exists")
    func noPlaceholder() {
        #expect(!PlaceholderParser.hasDynamicPlaceholders(in: "Hello world!"))
    }

    @Test("Returns false for empty string")
    func emptyString() {
        #expect(!PlaceholderParser.hasDynamicPlaceholders(in: ""))
    }

    @Test("Empty placeholder {{}} does not match")
    func emptyPlaceholder() {
        // Pattern is [^}]+ so empty placeholder does not match
        #expect(!PlaceholderParser.hasDynamicPlaceholders(in: "Hello {{}}!"))
    }

    @Test("Single braces {name} do not match")
    func singleBraces() {
        #expect(!PlaceholderParser.hasDynamicPlaceholders(in: "Hello {name}!"))
    }
}

// MARK: - extractPlaceholderNames

struct PlaceholderParserExtractTests {
    @Test("Extracts names in order of appearance")
    func extractsInOrder() {
        let names = PlaceholderParser.extractPlaceholderNames(from: "{{first}} and {{second}}")
        #expect(names == ["first", "second"])
    }

    @Test("Deduplicates repeated placeholder names")
    func deduplicates() {
        let names = PlaceholderParser.extractPlaceholderNames(from: "{{x}} {{y}} {{x}}")
        #expect(names == ["x", "y"])
    }

    @Test("Returns empty array when no placeholders exist")
    func noPlaceholders() {
        let names = PlaceholderParser.extractPlaceholderNames(from: "plain text")
        #expect(names.isEmpty)
    }

    @Test("Handles Japanese placeholder names")
    func japaneseName() {
        let names = PlaceholderParser.extractPlaceholderNames(from: "{{名前}}さん")
        #expect(names == ["名前"])
    }
}

// MARK: - resolve

struct PlaceholderParserResolveTests {
    @Test("Replaces placeholders with provided values")
    func basicResolve() {
        let result = PlaceholderParser.resolve(
            template: "Hello {{name}}, welcome to {{place}}!",
            values: ["name": "Alice", "place": "Tokyo"]
        )
        #expect(result == "Hello Alice, welcome to Tokyo!")
    }

    @Test("Replaces all occurrences of the same placeholder")
    func multipleOccurrences() {
        let result = PlaceholderParser.resolve(
            template: "{{x}} + {{x}} = 2{{x}}",
            values: ["x": "1"]
        )
        #expect(result == "1 + 1 = 21")
    }

    @Test("Unresolved placeholders remain in output")
    func unresolvedRemains() {
        let result = PlaceholderParser.resolve(
            template: "{{known}} and {{unknown}}",
            values: ["known": "OK"]
        )
        #expect(result == "OK and {{unknown}}")
    }

    @Test("Value containing {{ braces is still substituted")
    func valueContainingBraces() {
        let result = PlaceholderParser.resolve(
            template: "{{a}} then {{b}}",
            values: ["a": "{{b}}", "b": "end"]
        )
        // Dictionary iteration order is non-deterministic, but replacingOccurrences
        // is applied sequentially so {{b}} in the substituted value may also be replaced
        #expect(result.contains("end"))
    }

    @Test("Empty values dictionary leaves template unchanged")
    func emptyValues() {
        let template = "{{x}} stays"
        let result = PlaceholderParser.resolve(template: template, values: [:])
        #expect(result == template)
    }
}
