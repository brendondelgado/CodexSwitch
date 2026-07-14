import Darwin
import Foundation

enum CodexDesktopAppcastParser {
    static func latestRelease(from data: Data) -> CodexDesktopAppRelease? {
        guard let xml = String(data: data, encoding: .utf8),
              let itemXML = firstTagBlock(named: "item", in: xml),
              let enclosureTag = firstTag(named: "enclosure", in: itemXML) else {
            return nil
        }

        let itemMetadata = parseSparkleMetadata(in: itemXML)
        let attributes = parseAttributes(in: enclosureTag)
        guard let urlString = attributes["url"],
              let shortVersion = itemMetadata.shortVersion
                ?? attributes["sparkle:shortVersionString"],
              let bundleVersion = itemMetadata.bundleVersion ?? attributes["sparkle:version"],
              let downloadURL = URL(string: urlString) else {
            return nil
        }
        let archiveSHA256 = attributes["sparkle:sha256"] ?? attributes["sha256"]
        if let archiveSHA256,
           !isValidSHA256(archiveSHA256) {
            return nil
        }
        let archiveLength = attributes["length"].flatMap(Int64.init)
        if let archiveLength, archiveLength < 0 { return nil }
        return CodexDesktopAppRelease(
            shortVersion: shortVersion,
            bundleVersion: bundleVersion,
            downloadURL: downloadURL,
            archiveSHA256: archiveSHA256?.lowercased(),
            archiveEdSignature: attributes["sparkle:edSignature"],
            archiveLength: archiveLength
        )
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func firstTagBlock(named tagName: String, in xml: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: tagName)
        let pattern = "<\(escaped)\\b[^>]*>[\\s\\S]*?</\(escaped)>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: xml,
                  range: NSRange(xml.startIndex..., in: xml)
              ),
              let range = Range(match.range, in: xml) else {
            return nil
        }
        return String(xml[range])
    }

    private static func firstTag(named tagName: String, in xml: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: tagName)
        let pattern = "<\(escaped)\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: xml,
                  range: NSRange(xml.startIndex..., in: xml)
              ),
              let range = Range(match.range, in: xml) else {
            return nil
        }
        return String(xml[range])
    }

    private static func parseSparkleMetadata(
        in itemXML: String
    ) -> (shortVersion: String?, bundleVersion: String?) {
        (
            firstText(in: itemXML, tagName: "sparkle:shortVersionString"),
            firstText(in: itemXML, tagName: "sparkle:version")
        )
    }

    private static func firstText(in xml: String, tagName: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: tagName)
        let pattern = "<\(escaped)\\b[^>]*>([^<]+)</\(escaped)>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: xml,
                  range: NSRange(xml.startIndex..., in: xml)
              ),
              match.numberOfRanges == 2,
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseAttributes(in tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z0-9:_-]+)="([^"]*)""#
        ) else {
            return [:]
        }
        var attributes: [String: String] = [:]
        let range = NSRange(tag.startIndex..., in: tag)
        for match in regex.matches(in: tag, range: range) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: tag),
                  let valueRange = Range(match.range(at: 2), in: tag) else {
                continue
            }
            attributes[String(tag[keyRange])] = String(tag[valueRange])
        }
        return attributes
    }
}

struct DesktopAppcastHTTPResponse: Equatable, Sendable {
    let statusCode: Int
    let body: Data
    let etag: String?
    let lastModified: String?
    let finalURL: URL
}

protocol DesktopAppcastHTTPTransport: Sendable {
    func send(
        _ request: URLRequest,
        maximumBytes: Int
    ) async throws -> DesktopAppcastHTTPResponse
}

struct URLSessionDesktopAppcastTransport: DesktopAppcastHTTPTransport {
    func send(
        _ request: URLRequest,
        maximumBytes: Int
    ) async throws -> DesktopAppcastHTTPResponse {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DesktopAppcastClient.clientError("Appcast response was not HTTP")
        }
        guard http.expectedContentLength <= 0
                || http.expectedContentLength <= Int64(maximumBytes) else {
            throw DesktopAppcastClient.clientError("Appcast response exceeded its byte limit")
        }
        guard http.url?.absoluteString == request.url?.absoluteString else {
            throw DesktopAppcastClient.clientError(
                "Appcast response redirected to an unexpected final URL"
            )
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1024))
        for try await byte in bytes {
            if data.count >= maximumBytes {
                throw DesktopAppcastClient.clientError("Appcast response exceeded its byte limit")
            }
            data.append(byte)
            if data.count.isMultiple(of: 64 * 1024) {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return DesktopAppcastHTTPResponse(
            statusCode: http.statusCode,
            body: data,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            finalURL: http.url ?? request.url!
        )
    }
}

struct DesktopAppcastClient: @unchecked Sendable {
    static let maximumResponseBytes = 1024 * 1024
    static let maximumCacheBytes = 2 * 1024 * 1024

    let appcastURL: URL
    let cacheURL: URL
    let transport: any DesktopAppcastHTTPTransport
    let fileManager: FileManager

    init(
        appcastURL: URL,
        cacheURL: URL,
        transport: any DesktopAppcastHTTPTransport = URLSessionDesktopAppcastTransport(),
        fileManager: FileManager = .default
    ) {
        self.appcastURL = appcastURL
        self.cacheURL = cacheURL
        self.transport = transport
        self.fileManager = fileManager
    }

    func fetchLatestRelease() async throws -> CodexDesktopAppRelease {
        try Task.checkCancellation()
        let cache = loadEnvelope()
        try Task.checkCancellation()
        if cache.shouldClear {
            try Task.checkCancellation()
            clearCache()
        }
        let cached = cache.envelope
        do {
            return try await fetch(cached: cached, allowsUnconditionalRetry: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let cached, let release = CodexDesktopAppcastParser.latestRelease(
                from: cached.appcastBytes
            ) {
                return release
            }
            throw error
        }
    }

    private func fetch(
        cached: DesktopAppcastCacheEnvelope?,
        allowsUnconditionalRetry: Bool
    ) async throws -> CodexDesktopAppRelease {
        try Task.checkCancellation()
        var request = URLRequest(url: appcastURL)
        request.timeoutInterval = 20
        request.setValue("CodexSwitch/1.0", forHTTPHeaderField: "User-Agent")
        if let etag = cached?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = cached?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let response = try await transport.send(
            request,
            maximumBytes: Self.maximumResponseBytes
        )
        try Task.checkCancellation()
        guard response.finalURL.absoluteString == appcastURL.absoluteString else {
            throw Self.clientError("Appcast response redirected to an unexpected final URL")
        }
        guard response.body.count <= Self.maximumResponseBytes else {
            throw Self.clientError("Appcast response exceeded its byte limit")
        }
        if response.statusCode == 304 {
            if let cached,
               let release = CodexDesktopAppcastParser.latestRelease(
                   from: cached.appcastBytes
               ) {
                return release
            }
            try Task.checkCancellation()
            clearCache()
            guard allowsUnconditionalRetry else {
                throw Self.clientError("Appcast returned 304 without a valid cache")
            }
            try Task.checkCancellation()
            return try await fetch(cached: nil, allowsUnconditionalRetry: false)
        }

        guard (200..<300).contains(response.statusCode),
              let release = CodexDesktopAppcastParser.latestRelease(from: response.body) else {
            throw Self.clientError(
                "Appcast request failed or returned malformed bytes (HTTP \(response.statusCode))"
            )
        }
        let envelope = DesktopAppcastCacheEnvelope(
            appcastBytes: response.body,
            etag: response.etag,
            lastModified: response.lastModified
        )
        try Task.checkCancellation()
        try commit(envelope)
        return release
    }

    private func loadEnvelope() -> (
        envelope: DesktopAppcastCacheEnvelope?,
        shouldClear: Bool
    ) {
        guard fileManager.fileExists(atPath: cacheURL.path) else { return (nil, false) }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? cacheURL.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= Self.maximumCacheBytes,
              let data = try? Data(contentsOf: cacheURL),
              let envelope = try? JSONDecoder().decode(
                  DesktopAppcastCacheEnvelope.self,
                  from: data
              ),
              CodexDesktopAppcastParser.latestRelease(from: envelope.appcastBytes) != nil else {
            return (nil, true)
        }
        return (envelope, false)
    }

    private func commit(_ envelope: DesktopAppcastCacheEnvelope) throws {
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= Self.maximumCacheBytes else {
            throw Self.clientError("Appcast cache envelope exceeded its size bound")
        }
        try Task.checkCancellation()
        let parent = cacheURL.deletingLastPathComponent()
        try CodexDesktopPathSecurity.ensureDirectoryExists(parent)
        var info = stat()
        if lstat(cacheURL.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFREG {
            throw Self.clientError("Appcast cache destination is not a regular file")
        }
        try Task.checkCancellation()
        try data.write(to: cacheURL, options: .atomic)
    }

    private func clearCache() {
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(
            cacheURL.deletingLastPathComponent()
        ) else { return }
        try? fileManager.removeItem(at: cacheURL)
    }

    static func clientError(_ message: String) -> NSError {
        NSError(
            domain: "DesktopAppcastClient",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
