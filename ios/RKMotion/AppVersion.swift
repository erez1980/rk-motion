import Foundation

/// Which build is running, so every screen and every report can say so.
enum AppVersion {
    static var label: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["RKCommit"] as? String ?? "local"
        return "\(version) (\(build)) · \(commit)"
    }
    static var line: String {String(format: NSLocalizedString("גרסה %@", comment: "App version line"), label)}
}
