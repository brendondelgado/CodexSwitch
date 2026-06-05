import Foundation

enum ComputerUsePermissionRepair {
    struct RepairResult: Sendable, Equatable {
        let attempted: Bool
        let changed: Bool
        let success: Bool
        let message: String
    }

    struct AppleEventsClient: Sendable, Equatable {
        let bundleIdentifier: String
        let appPath: String
    }

    private static let appleEventsService = "kTCCServiceAppleEvents"
    private static let systemEventsBundleIdentifier = "com.apple.systemevents"
    private static let systemEventsPath = "/System/Library/CoreServices/System Events.app"
    private static let userTCCDatabasePath =
        NSString("~/Library/Application Support/com.apple.TCC/TCC.db").expandingTildeInPath

    static let genericAppleEventsClients = [
        AppleEventsClient(
            bundleIdentifier: "com.openai.codex",
            appPath: "/Applications/Codex.app"
        ),
        AppleEventsClient(
            bundleIdentifier: "com.openai.sky.CUAService",
            appPath: "/Applications/Codex.app/Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app"
        ),
        AppleEventsClient(
            bundleIdentifier: "com.openai.sky.CUAService.cli",
            appPath: "/Applications/Codex.app/Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app"
        ),
    ]

    static func repairGenericAppleEventsIfNeeded(
        tccDatabasePath: String = userTCCDatabasePath,
        clients: [AppleEventsClient] = genericAppleEventsClients,
        targetPath: String = systemEventsPath
    ) -> RepairResult {
        guard FileManager.default.fileExists(atPath: tccDatabasePath) else {
            return RepairResult(
                attempted: false,
                changed: false,
                success: false,
                message: "user TCC database not found"
            )
        }
        guard FileManager.default.fileExists(atPath: targetPath),
              let targetRequirementHex = codeRequirementBlobHex(for: targetPath) else {
            return RepairResult(
                attempted: false,
                changed: false,
                success: false,
                message: "System Events code requirement unavailable"
            )
        }

        var grantsToRepair: [(AppleEventsClient, String)] = []
        var missingClients: [String] = []
        for client in clients {
            guard FileManager.default.fileExists(atPath: client.appPath),
                  let clientRequirementHex = codeRequirementBlobHex(for: client.appPath) else {
                missingClients.append(client.bundleIdentifier)
                continue
            }
            if !existingAppleEventsGrantMatches(
                tccDatabasePath: tccDatabasePath,
                clientBundleIdentifier: client.bundleIdentifier,
                clientRequirementHex: clientRequirementHex,
                targetRequirementHex: targetRequirementHex
            ) {
                grantsToRepair.append((client, clientRequirementHex))
            }
        }

        guard !grantsToRepair.isEmpty else {
            let suffix = missingClients.isEmpty ? "" : "; skipped missing clients: \(missingClients.joined(separator: ","))"
            return RepairResult(
                attempted: false,
                changed: false,
                success: true,
                message: "generic Computer Use AppleEvents grants already current\(suffix)"
            )
        }

        let backupResult = backUpTCCDatabase(tccDatabasePath)
        guard backupResult.success else {
            return RepairResult(
                attempted: true,
                changed: false,
                success: false,
                message: backupResult.message
            )
        }

        let now = Int(Date().timeIntervalSince1970)
        let sql = grantsToRepair.map { client, clientRequirementHex in
            appleEventsUpsertSQL(
                clientBundleIdentifier: client.bundleIdentifier,
                clientRequirementHex: clientRequirementHex,
                targetRequirementHex: targetRequirementHex,
                timestamp: now
            )
        }.joined(separator: "\n")

        let writeResult = runSQLite(tccDatabasePath: tccDatabasePath, sql: "PRAGMA busy_timeout=3000;\nBEGIN IMMEDIATE;\n\(sql)\nCOMMIT;")
        guard writeResult.terminationStatus == 0, !writeResult.timedOut else {
            return RepairResult(
                attempted: true,
                changed: false,
                success: false,
                message: "TCC AppleEvents repair failed: \(writeResult.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }

        restartTCCD()
        SwapLog.append(.debug("COMPUTER_USE_APPLEEVENTS_REPAIRED clients=\(grantsToRepair.map { $0.0.bundleIdentifier }.joined(separator: ",")) target=\(systemEventsBundleIdentifier)"))
        return RepairResult(
            attempted: true,
            changed: true,
            success: true,
            message: "generic Computer Use AppleEvents grants repaired for System Events"
        )
    }

    static func appleEventsUpsertSQL(
        clientBundleIdentifier: String,
        clientRequirementHex: String,
        targetRequirementHex: String,
        timestamp: Int
    ) -> String {
        """
        INSERT INTO access (
            service, client, client_type, auth_value, auth_reason, auth_version,
            csreq, policy_id, indirect_object_identifier_type,
            indirect_object_identifier, indirect_object_code_identity,
            flags, last_modified, pid, pid_version, boot_uuid, last_reminded
        ) VALUES (
            '\(sqlEscape(appleEventsService))',
            '\(sqlEscape(clientBundleIdentifier))',
            0, 2, 3, 1,
            X'\(clientRequirementHex)', NULL, 0,
            '\(sqlEscape(systemEventsBundleIdentifier))',
            X'\(targetRequirementHex)',
            0, \(timestamp), NULL, NULL, 'UNUSED', \(timestamp)
        )
        ON CONFLICT(service, client, client_type, indirect_object_identifier)
        DO UPDATE SET
            auth_value = 2,
            auth_reason = 3,
            auth_version = 1,
            csreq = X'\(clientRequirementHex)',
            indirect_object_identifier_type = 0,
            indirect_object_code_identity = X'\(targetRequirementHex)',
            flags = 0,
            last_modified = \(timestamp),
            last_reminded = \(timestamp);
        """
    }

    private static func existingAppleEventsGrantMatches(
        tccDatabasePath: String,
        clientBundleIdentifier: String,
        clientRequirementHex: String,
        targetRequirementHex: String
    ) -> Bool {
        let sql = """
        SELECT auth_value || '|' || lower(hex(csreq)) || '|' || lower(hex(indirect_object_code_identity))
        FROM access
        WHERE service = '\(sqlEscape(appleEventsService))'
          AND client = '\(sqlEscape(clientBundleIdentifier))'
          AND client_type = 0
          AND indirect_object_identifier = '\(sqlEscape(systemEventsBundleIdentifier))'
        LIMIT 1;
        """
        let result = runSQLite(tccDatabasePath: tccDatabasePath, sql: sql)
        guard result.terminationStatus == 0, !result.timedOut else { return false }
        let expected = "2|\(clientRequirementHex.lowercased())|\(targetRequirementHex.lowercased())"
        return result.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == expected
    }

    private static func codeRequirementBlobHex(for path: String) -> String? {
        let codesign = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dr", "-", path],
            timeout: 3
        )
        guard !codesign.timedOut, codesign.terminationStatus == 0 else { return nil }
        let requirement = (codesign.stdoutString + "\n" + codesign.stderrString)
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                let prefix = "designated => "
                guard line.hasPrefix(prefix) else { return nil }
                return String(line.dropFirst(prefix.count))
            }
            .first
        guard let requirement, !requirement.isEmpty else { return nil }

        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "codexswitch-csreq-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let requirementPath = temporaryDirectory.appending(path: "requirement.txt")
            let blobPath = temporaryDirectory.appending(path: "requirement.csreq")
            try requirement.write(to: requirementPath, atomically: true, encoding: .utf8)
            let csreq = ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/csreq"),
                arguments: ["-r", requirementPath.path, "-b", blobPath.path],
                timeout: 3
            )
            guard !csreq.timedOut, csreq.terminationStatus == 0,
                  let data = try? Data(contentsOf: blobPath) else {
                return nil
            }
            return data.map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }

    private static func backUpTCCDatabase(_ path: String) -> (success: Bool, message: String) {
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let backupPath = "\(path).codexswitch-computer-use-appleevents-backup-\(timestamp)"
        do {
            try FileManager.default.copyItem(atPath: path, toPath: backupPath)
            return (true, "backup written to \(backupPath)")
        } catch {
            return (false, "TCC backup failed: \(error.localizedDescription)")
        }
    }

    private static func runSQLite(tccDatabasePath: String, sql: String) -> ProcessRunResult {
        ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [tccDatabasePath, sql],
            timeout: 5
        )
    }

    private static func restartTCCD() {
        _ = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/killall"),
            arguments: ["tccd"],
            timeout: 2
        )
    }

    private static func sqlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
