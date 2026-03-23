import Foundation

public enum AppPaths {
    /// ~/Library/Application Support/FuzzyPaste/ — 履歴・設定用（従来通り）
    public static let appSupportDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #if DEV
        let dirName = "FuzzyPaste-Dev"
        #else
        let dirName = "FuzzyPaste"
        #endif
        let dir = appSupport.appendingPathComponent(dirName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// ~/.config/fuzzy-paste/snippets/ — スニペット (.md ファイル)
    public static let snippetsDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if DEV
        let base = "fuzzy-paste-dev"
        #else
        let base = "fuzzy-paste"
        #endif
        let dir = home
            .appendingPathComponent(".config")
            .appendingPathComponent(base)
            .appendingPathComponent("snippets")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// ~/.config/fuzzy-paste/snippets/_assets/ — 画像・ファイルアセット
    public static let assetsDir: URL = {
        let dir = snippetsDir.appendingPathComponent("_assets")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// ~/.config/fuzzy-paste/snippets/_assets/thumbs/ — サムネイル
    public static let thumbsDir: URL = {
        let dir = assetsDir.appendingPathComponent("thumbs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
