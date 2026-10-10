import Foundation

/// Locates staged product resources (shared/i18n JSON).
///
/// rivet.rktd declares `(resources . ("shared/i18n"))`, so rivet's build
/// stages them under app/shared/… and every package ships them: the .app at
/// Contents/Resources/app/shared/…, Windows/Linux at <install dir>/app/
/// shared/…. SwiftPM resource bundles are deliberately NOT used: their
/// accessor looks only at the .app root, where codesign refuses to seal
/// anything.
///
/// Candidates, in order:
///   1. <Bundle.main.resourceURL>/app/shared/…   (packaged .app)
///   2. <exe_dir>/app/shared/…                   (staged build)
///   3. <exe_dir>/../../shared/…                 (dev tree, `raco rivet dev`)
/// Missing everywhere → nil; callers degrade (key-echo fallbacks).
enum HostResources {
    static func locate(i18n lang: String) -> URL? {
        locate(staged: "i18n/\(lang).json", devTree: "shared/i18n/\(lang).json")
    }

    private static func locate(staged: String, devTree: String) -> URL? {
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(URL(fileURLWithPath: resourceURL.path)
                .appendingPathComponent("app/shared")
                .appendingPathComponent(staged))
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("app/shared")
            .appendingPathComponent(staged))
        candidates.append(exeDir.appendingPathComponent("../..")
            .appendingPathComponent(devTree))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
