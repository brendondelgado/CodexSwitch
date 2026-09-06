import Foundation

struct VPSCodexRestartPlan: Equatable, Sendable {
    let pid: Int32
    let processStart: String
    let configDigest: String

    var isValid: Bool {
        pid > 1
            && !processStart.isEmpty
            && processStart.utf8.count <= 32
            && processStart.utf8.allSatisfy { (48...57).contains($0) }
            && configDigest.utf8.count == 64
            && configDigest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct VPSCodexRestartResult: Decodable, Sendable {
    let schemaVersion: Int
    let status: String
    let pid: Int32?
    let processStart: String?
    let configDigest: String?
    let appServerVersion: String?
    let message: String?

    var plan: VPSCodexRestartPlan? {
        guard let pid, let processStart, let configDigest else { return nil }
        let plan = VPSCodexRestartPlan(pid: pid, processStart: processStart, configDigest: configDigest)
        return plan.isValid ? plan : nil
    }

    var hasValidVersion: Bool {
        guard let appServerVersion, !appServerVersion.isEmpty, appServerVersion.utf8.count <= 64 else {
            return false
        }
        return appServerVersion.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || [43, 45, 46].contains($0)
        }
    }
}
