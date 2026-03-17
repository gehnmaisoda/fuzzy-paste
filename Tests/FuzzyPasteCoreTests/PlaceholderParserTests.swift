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

    @Test("Resolves choice placeholder by name")
    func resolveChoicePlaceholder() {
        let result = PlaceholderParser.resolve(
            template: "OS: {{OS|macOS,Windows,Linux}}",
            values: ["OS": "macOS"]
        )
        #expect(result == "OS: macOS")
    }

    @Test("Resolves mixed free-text and choice placeholders")
    func resolveMixed() {
        let result = PlaceholderParser.resolve(
            template: "{{name}} uses {{OS|macOS,Windows}}",
            values: ["name": "Alice", "OS": "Windows"]
        )
        #expect(result == "Alice uses Windows")
    }
}

// MARK: - extractPlaceholders (with options)

struct PlaceholderParserChoiceTests {
    @Test("Extracts choice options from placeholder")
    func extractsOptions() {
        let placeholders = PlaceholderParser.extractPlaceholders(from: "{{OS|macOS,Windows,Linux}}")
        #expect(placeholders.count == 1)
        #expect(placeholders[0].name == "OS")
        #expect(placeholders[0].options == ["macOS", "Windows", "Linux"])
    }

    @Test("Free-text placeholder has nil options")
    func freeTextHasNilOptions() {
        let placeholders = PlaceholderParser.extractPlaceholders(from: "{{name}}")
        #expect(placeholders.count == 1)
        #expect(placeholders[0].name == "name")
        #expect(placeholders[0].options == nil)
    }

    @Test("Mixed free-text and choice placeholders")
    func mixedTypes() {
        let placeholders = PlaceholderParser.extractPlaceholders(from: "{{name}} {{OS|macOS,Windows}}")
        #expect(placeholders.count == 2)
        #expect(placeholders[0].options == nil)
        #expect(placeholders[1].options == ["macOS", "Windows"])
    }

    @Test("Trims whitespace around options")
    func trimsOptionWhitespace() {
        let placeholders = PlaceholderParser.extractPlaceholders(from: "{{size| S , M , L }}")
        #expect(placeholders[0].options == ["S", "M", "L"])
    }

    @Test("extractPlaceholderNames still works with choice syntax")
    func namesBackwardCompatible() {
        let names = PlaceholderParser.extractPlaceholderNames(from: "{{OS|macOS,Windows}} and {{name}}")
        #expect(names == ["OS", "name"])
    }

    @Test("Deduplicates choice placeholders by name")
    func deduplicatesChoices() {
        let placeholders = PlaceholderParser.extractPlaceholders(from: "{{x|a,b}} {{x|a,b}}")
        #expect(placeholders.count == 1)
    }

    @Test("rawToken preserves original syntax for resolve")
    func rawTokenPreserved() {
        let placeholders = PlaceholderParser.extractPlaceholders(from: "{{OS|macOS,Windows}}")
        #expect(placeholders[0].rawToken == "{{OS|macOS,Windows}}")
    }
}
