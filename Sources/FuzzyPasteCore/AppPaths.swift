import Foundation

public enum AppPaths {
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
}
