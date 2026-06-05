import Foundation

enum AppBuildInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    }

    static var sourceRevision: String? {
        Bundle.main.infoDictionary?["CFBundleSourceRevision"] as? String
    }

    static var popoverBuildLabel: String {
        "b\(build)"
    }

    static var settingsVersionLabel: String {
        "v\(version) (\(popoverBuildLabel))"
    }
}
