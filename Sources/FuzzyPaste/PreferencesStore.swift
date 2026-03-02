import Combine
import Foundation

/// 除外アプリの情報。
struct ExcludedApp: Codable, Identifiable, Sendable {
    let id: UUID
    let bundleIdentifier: String
    let appName: String
    let addedAt: Date
}

/// アプリ全体の設定データ。
private struct Preferences: Codable, Sendable {
    var excludedApps: [ExcludedApp] = []
}

/// 設定の永続化を管理するストア。
/// JSON ファイルで保存し、既存の HistoryStore / SnippetStore と同じパターンに従う。
///
/// 保存先: ~/Library/Application Support/FuzzyPaste/preferences.json
@MainActor
final class PreferencesStore: ObservableObject {
    @Published private(set) var excludedApps: [ExcludedApp] = []
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FuzzyPaste")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("preferences.json")
        load()
    }

    func addExcludedApp(bundleIdentifier: String, appName: String) {
        guard !excludedApps.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        let app = ExcludedApp(id: UUID(), bundleIdentifier: bundleIdentifier, appName: appName, addedAt: Date())
        excludedApps.append(app)
        save()
    }

    func removeExcludedApp(id: UUID) {
        excludedApps.removeAll { $0.id == id }
        save()
    }

    func isExcluded(bundleIdentifier: String) -> Bool {
        excludedApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let prefs = try? decoder.decode(Preferences.self, from: data) {
            excludedApps = prefs.excludedApps
        }
    }

    private func save() {
        let prefs = Preferences(excludedApps: excludedApps)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(prefs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
