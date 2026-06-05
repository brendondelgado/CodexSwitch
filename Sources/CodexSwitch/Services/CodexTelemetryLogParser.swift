import CryptoKit
import Foundation

enum CodexTelemetryLogParser {
    static func report<Lines: Sequence>(
        source: CodexTokenUsageSource,
        lines: Lines,
        accountTokenHashPrefixes: [String],
        generatedAt: Date = Date(),
        windowDays: Int
    ) -> CodexTokenUsageReport where Lines.Element == String {
        var responseSeen: Set<String> = []
        var responseEvents: [CompletionEvent] = []
        var turnAggregates: [String: CompletionEvent] = [:]
        var sessionTotals: [String: CompletionEvent] = [:]
        var byModel: [String: CodexModelTokenUsage] = [:]
        var firstEventAt: Date?

        for line in lines where line.contains("response.completed")
            || line.contains("codex.turn.token_usage.input_tokens")
            || line.contains(#""type":"token_count""#)
            || line.contains(#""type": "token_count""#) {
            guard let event = parseEvent(line) else { continue }
            if event.kind == .sessionTotal, let sessionId = event.sessionId {
                if let existing = sessionTotals[sessionId],
                   existing.aggregateTokenScore > event.aggregateTokenScore {
                    continue
                }
                sessionTotals[sessionId] = event
            } else if event.kind == .turnAggregate, let turnId = event.turnId {
                if let existing = turnAggregates[turnId],
                   existing.aggregateTokenScore > event.aggregateTokenScore {
                    continue
                }
                turnAggregates[turnId] = event
            } else {
                let key = event.dedupeKey
                guard responseSeen.insert(key).inserted else { continue }
                responseEvents.append(event)
            }
        }

        let aggregatedSessionIds = Set(sessionTotals.keys)
        let aggregatedTurnIds = Set(turnAggregates.keys)
        for event in sessionTotals.values.sorted(by: eventSort) {
            add(event, to: &byModel, firstEventAt: &firstEventAt)
        }
        for event in turnAggregates.values.sorted(by: eventSort) {
            if let sessionId = event.sessionId, aggregatedSessionIds.contains(sessionId) {
                continue
            }
            add(event, to: &byModel, firstEventAt: &firstEventAt)
        }
        for event in responseEvents.sorted(by: eventSort) where event.usesLongContextPricing {
            if let sessionId = event.sessionId, aggregatedSessionIds.contains(sessionId) {
                addLongContextPricing(from: event, to: &byModel)
                continue
            }
            if let turnId = event.turnId, aggregatedTurnIds.contains(turnId) {
                addLongContextPricing(from: event, to: &byModel)
            }
        }
        for event in responseEvents.sorted(by: eventSort) {
            if let sessionId = event.sessionId, aggregatedSessionIds.contains(sessionId) {
                continue
            }
            if let turnId = event.turnId, aggregatedTurnIds.contains(turnId) {
                continue
            }
            add(event, to: &byModel, firstEventAt: &firstEventAt)
        }

        return CodexTokenUsageReport(
            source: source,
            generatedAt: generatedAt,
            windowDays: windowDays,
            firstEventAt: firstEventAt,
            accountTokenHashPrefixes: accountTokenHashPrefixes.sorted(),
            models: byModel.values.sorted { $0.model < $1.model }
        )
    }

    private static func add(
        _ event: CompletionEvent,
        to byModel: inout [String: CodexModelTokenUsage],
        firstEventAt: inout Date?
    ) {
        if let eventDate = event.eventDate, firstEventAt == nil || eventDate < firstEventAt! {
            firstEventAt = eventDate
        }
        var usage = byModel[event.model] ?? .empty(model: event.model)
        usage.inputTokens += event.inputTokens
        usage.cachedInputTokens += min(event.cachedInputTokens, event.inputTokens)
        usage.outputTokens += event.outputTokens
        usage.reasoningTokens += event.reasoningTokens
        usage.completionCount += 1
        if event.usesLongContextPricing {
            usage.longContextInputTokens += event.inputTokens
            usage.longContextCachedInputTokens += min(event.cachedInputTokens, event.inputTokens)
            usage.longContextOutputTokens += event.outputTokens
        }
        byModel[event.model] = usage
    }

    private static func addLongContextPricing(
        from event: CompletionEvent,
        to byModel: inout [String: CodexModelTokenUsage]
    ) {
        var usage = byModel[event.model] ?? .empty(model: event.model)
        usage.longContextInputTokens += event.inputTokens
        usage.longContextCachedInputTokens += min(event.cachedInputTokens, event.inputTokens)
        usage.longContextOutputTokens += event.outputTokens
        byModel[event.model] = usage
    }

    private static func eventSort(_ left: CompletionEvent, _ right: CompletionEvent) -> Bool {
        switch (left.eventDate, right.eventDate) {
        case (.some(let leftDate), .some(let rightDate)):
            return leftDate < rightDate
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return left.dedupeKey < right.dedupeKey
        }
    }

    static func tokenHashPrefixes(for accounts: [CodexAccount]) -> [String] {
        Set(
            accounts.flatMap { account in
                [account.accessToken, account.refreshToken]
                    .filter { !$0.isEmpty }
                    .map(tokenHashPrefix)
            }
        ).sorted()
    }

    static func tokenHashPrefix(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
            .description
    }

    private static func parseEvent(_ line: String) -> CompletionEvent? {
        if let tokenCountEvent = parseTokenCountEvent(line) {
            return tokenCountEvent
        }
        if let turnEvent = parseTurnAggregateEvent(line) {
            return turnEvent
        }
        if let kvEvent = parseKeyValueEvent(line) {
            return kvEvent
        }
        return parseJSONishEvent(line)
    }

    private static func parseTokenCountEvent(_ line: String) -> CompletionEvent? {
        guard line.contains(#""type":"token_count""#)
            || line.contains(#""type": "token_count""#) else {
            return nil
        }
        let jsonStart = line.firstIndex(of: "{") ?? line.startIndex
        let jsonText = String(line[jsonStart...])
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any],
              let input = anyInt(total["input_tokens"]),
              let output = anyInt(total["output_tokens"]) else {
            return nil
        }
        let cached = anyInt(total["cached_input_tokens"]) ?? 0
        let reasoning = anyInt(total["reasoning_output_tokens"]) ?? 0
        let timestamp = root["timestamp"] as? String
            ?? stringField("codexswitch_ts", in: line)
            ?? "unknown-timestamp"
        return CompletionEvent(
            kind: .sessionTotal,
            model: normalizeModel(stringField("codexswitch_model", in: line) ?? stringField("model", in: line) ?? "gpt-5.5"),
            timestamp: timestamp,
            sessionId: sessionId(in: line),
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningTokens: reasoning
        )
    }

    private static func parseTurnAggregateEvent(_ line: String) -> CompletionEvent? {
        guard line.contains("codex.turn.token_usage.input_tokens"),
              let turnId = stringField("turn.id", in: line),
              let input = intField("codex.turn.token_usage.input_tokens", in: line),
              let cached = intField("codex.turn.token_usage.cached_input_tokens", in: line),
              let output = intField("codex.turn.token_usage.output_tokens", in: line) else {
            return nil
        }
        let reasoning = intField("codex.turn.token_usage.reasoning_output_tokens", in: line) ?? 0
        let model = normalizeModel(stringField("model", in: line) ?? stringField("slug", in: line) ?? "gpt-5.5")
        let timestamp = stringField("codexswitch_ts", in: line)
            ?? stringField("event.timestamp", in: line)
            ?? "unknown-timestamp"
        return CompletionEvent(
            kind: .turnAggregate,
            model: model,
            timestamp: timestamp,
            sessionId: sessionId(in: line),
            turnId: turnId,
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningTokens: reasoning
        )
    }

    private static func parseKeyValueEvent(_ line: String) -> CompletionEvent? {
        guard line.contains("event.kind=response.completed"),
              let input = intField("input_token_count", in: line),
              let output = intField("output_token_count", in: line),
              let cached = intField("cached_token_count", in: line) else {
            return nil
        }
        let reasoning = intField("reasoning_token_count", in: line) ?? 0
        let model = normalizeModel(stringField("slug", in: line) ?? stringField("model", in: line) ?? "gpt-5.5")
        let timestamp = stringField("codexswitch_ts", in: line)
            ?? stringField("event.timestamp", in: line)
            ?? stringField("conversation.id", in: line)
            ?? "unknown-timestamp"
        return CompletionEvent(
            model: model,
            timestamp: timestamp,
            sessionId: sessionId(in: line),
            turnId: stringField("turn.id", in: line),
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningTokens: reasoning
        )
    }

    private static func parseJSONishEvent(_ line: String) -> CompletionEvent? {
        if let jsonEvent = parseJSONObjectEvent(line) {
            return jsonEvent
        }

        guard let input = intField("input_token_count", in: line),
              let output = intField("output_token_count", in: line),
              let cached = intField("cached_token_count", in: line) else {
            guard let jsonInput = jsonIntField("input_tokens", in: line),
                  let jsonOutput = jsonIntField("output_tokens", in: line) else {
                return nil
            }
            let jsonCached = jsonIntField("cached_tokens", in: line)
                ?? jsonIntField("cached_input_tokens", in: line)
                ?? 0
            let jsonReasoning = jsonIntField("reasoning_tokens", in: line) ?? 0
            let jsonModel = normalizeModel(jsonStringField("model", in: line) ?? stringField("slug", in: line) ?? stringField("model", in: line) ?? "gpt-5.5")
            let timestamp = stringField("codexswitch_ts", in: line)
                ?? jsonStringField("id", in: line)
                ?? "unknown-timestamp"
            return CompletionEvent(
                model: jsonModel,
                timestamp: timestamp,
                sessionId: sessionId(in: line),
                turnId: stringField("turn.id", in: line),
                inputTokens: jsonInput,
                cachedInputTokens: jsonCached,
                outputTokens: jsonOutput,
                reasoningTokens: jsonReasoning
            )
        }
        let reasoning = intField("reasoning_token_count", in: line) ?? 0
        let model = normalizeModel(stringField("slug", in: line) ?? stringField("model", in: line) ?? "gpt-5.5")
        let timestamp = stringField("codexswitch_ts", in: line)
            ?? stringField("event.timestamp", in: line)
            ?? "unknown-timestamp"
        return CompletionEvent(
            model: model,
            timestamp: timestamp,
            sessionId: sessionId(in: line),
            turnId: stringField("turn.id", in: line),
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningTokens: reasoning
        )
    }

    private static func parseJSONObjectEvent(_ line: String) -> CompletionEvent? {
        guard let jsonText = responseCompletedJSONText(in: line) else {
            return nil
        }
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "response.completed",
              let response = root["response"] as? [String: Any],
              let usage = response["usage"] as? [String: Any],
              let input = anyInt(usage["input_tokens"]),
              let output = anyInt(usage["output_tokens"]) else {
            return nil
        }
        let inputDetails = usage["input_tokens_details"] as? [String: Any]
        let outputDetails = usage["output_tokens_details"] as? [String: Any]
        let cached = anyInt(inputDetails?["cached_tokens"])
            ?? anyInt(usage["cached_tokens"])
            ?? anyInt(usage["cached_input_tokens"])
            ?? 0
        let reasoning = anyInt(outputDetails?["reasoning_tokens"])
            ?? anyInt(usage["reasoning_tokens"])
            ?? 0
        let model = normalizeModel(response["model"] as? String ?? jsonStringField("model", in: line) ?? "gpt-5.5")
        let timestamp = stringField("codexswitch_ts", in: line)
            ?? response["id"] as? String
            ?? "unknown-timestamp"
        return CompletionEvent(
            model: model,
            timestamp: timestamp,
            sessionId: sessionId(in: line),
            turnId: stringField("turn.id", in: line),
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningTokens: reasoning
        )
    }

    private static func responseCompletedJSONText(in line: String) -> String? {
        guard let typeRange = line.range(
            of: #""type"\s*:\s*"response\.completed""#,
            options: .regularExpression
        ) else {
            return nil
        }

        var start = typeRange.lowerBound
        var foundStart = false
        while start > line.startIndex {
            start = line.index(before: start)
            if line[start] == "{" {
                foundStart = true
                break
            }
        }
        guard foundStart else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < line.endIndex {
            let char = line[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else if char == "\"" {
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(line[start...index])
                }
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func anyInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func normalizeModel(_ model: String) -> String {
        let withoutTraceSuffix = model.split(separator: "}").first.map(String.init) ?? model
        return withoutTraceSuffix
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sessionId(in line: String) -> String? {
        stringField("codexswitch_session", in: line)
            ?? stringField("thread_id", in: line)
            ?? stringField("thread.id", in: line)
    }

    private static func intField(_ name: String, in line: String) -> Int? {
        guard let value = stringField(name, in: line) else { return nil }
        return Int(value)
    }

    private static func stringField(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "\(name)=") else { return nil }
        var value = line[range.upperBound...]
        if value.first == "\"" {
            value.removeFirst()
            guard let end = value.firstIndex(of: "\"") else { return nil }
            return String(value[..<end])
        }
        let end = value.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "}" || $0 == ":" || $0 == "," }) ?? value.endIndex
        return String(value[..<end])
    }

    private static func jsonIntField(_ name: String, in line: String) -> Int? {
        for pattern in [
            #""\#(NSRegularExpression.escapedPattern(for: name))"\s*:\s*(\d+)"#,
            #"\\?"\#(NSRegularExpression.escapedPattern(for: name))\\?"\s*:\s*(\d+)"#,
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: line) else {
                continue
            }
            return Int(line[valueRange])
        }
        return nil
    }

    private static func jsonStringField(_ name: String, in line: String) -> String? {
        for pattern in [
            #""\#(NSRegularExpression.escapedPattern(for: name))"\s*:\s*"([^"]+)""#,
            #"\\?"\#(NSRegularExpression.escapedPattern(for: name))\\?"\s*:\s*\\?"([^"\\]+)\\?""#,
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: line) else {
                continue
            }
            return String(line[valueRange])
        }
        return nil
    }

    private enum EventKind {
        case response
        case turnAggregate
        case sessionTotal
    }

    private struct CompletionEvent {
        var kind: EventKind = .response
        let model: String
        let timestamp: String
        var sessionId: String? = nil
        var turnId: String? = nil
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int

        var eventDate: Date? {
            if let unixSeconds = TimeInterval(timestamp) {
                return Date(timeIntervalSince1970: unixSeconds)
            }
            return ISO8601DateFormatter().date(from: timestamp)
        }

        var dedupeKey: String {
            if kind == .sessionTotal, let sessionId {
                return "session|\(sessionId)|\(model)|\(inputTokens)|\(min(cachedInputTokens, inputTokens))|\(outputTokens)|\(reasoningTokens)"
            }
            if kind == .turnAggregate, let turnId {
                return "turn|\(turnId)|\(model)|\(inputTokens)|\(min(cachedInputTokens, inputTokens))|\(outputTokens)|\(reasoningTokens)"
            }
            return "\(timestamp)|\(sessionId ?? "no-session")|\(turnId ?? "no-turn")|\(model)|\(inputTokens)|\(min(cachedInputTokens, inputTokens))|\(outputTokens)|\(reasoningTokens)"
        }

        var aggregateTokenScore: Int {
            inputTokens + outputTokens + reasoningTokens
        }

        var usesLongContextPricing: Bool {
            kind == .response && inputTokens > 272_000 && ["gpt-5.5", "gpt-5.4"].contains(model.lowercased())
        }
    }
}

enum CodexTokenUsageReader {
    static func localReport(
        accounts: [CodexAccount],
        days: Int = 30,
        logsPath: String = NSString(string: "~/.codex/logs_2.sqlite").expandingTildeInPath
    ) -> CodexTokenUsageReport? {
        guard FileManager.default.fileExists(atPath: logsPath) else { return nil }
        let cutoff = Int(Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970)
        let query = """
        select 'codexswitch_ts=' || ts || ' codexswitch_target=' || target || ' ' || replace(feedback_log_body, char(10), ' ') from logs
        where (feedback_log_body like '%response.completed%'
            or feedback_log_body like '%codex.turn.token_usage.input_tokens%')
          and ts >= \(cutoff)
        order by ts asc;
        """
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [logsPath, query],
            timeout: 5
        )
        guard !result.timedOut, result.terminationStatus == 0 else { return nil }
        let lines = result.stdoutString
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let sessionLines = sessionTokenCountLines(
            root: NSString(string: "~/.codex/sessions").expandingTildeInPath,
            cutoff: cutoff
        )
        let combinedLines = AnySequence<String> {
            var logIterator = lines.makeIterator()
            var sessionIterator = sessionLines.makeIterator()
            var readingLogs = true
            return AnyIterator {
                if readingLogs {
                    if let next = logIterator.next() {
                        return next
                    }
                    readingLogs = false
                }
                return sessionIterator.next()
            }
        }

        return CodexTelemetryLogParser.report(
            source: .mac,
            lines: combinedLines,
            accountTokenHashPrefixes: CodexTelemetryLogParser.tokenHashPrefixes(for: accounts),
            windowDays: days
        )
    }

    static func sessionTokenCountLines(root: String, cutoff: Int) -> [String] {
        let script = #"""
        import json
        import pathlib, sys
        import re
        root = pathlib.Path(sys.argv[1])
        cutoff = int(sys.argv[2])
        if not root.exists():
            raise SystemExit(0)
        def model_in(line):
            try:
                root = json.loads(line)
            except Exception:
                return None
            payload = root.get("payload") or {}
            candidates = []
            if root.get("type") in ("session_meta", "turn_context"):
                candidates.extend([
                    payload.get("model"),
                    payload.get("model_slug"),
                    payload.get("slug"),
                ])
            elif root.get("type") == "event_msg" and payload.get("type") == "token_count":
                info = payload.get("info") or {}
                candidates.extend([
                    payload.get("model"),
                    payload.get("model_slug"),
                    payload.get("slug"),
                    info.get("model"),
                    info.get("model_slug"),
                ])
            for candidate in candidates:
                if isinstance(candidate, str) and candidate.strip():
                    return candidate.strip()
            return None
        def token_score(line):
            try:
                root = json.loads(line)
            except Exception:
                return None
            if root.get("type") != "event_msg":
                return None
            payload = root.get("payload") or {}
            if payload.get("type") != "token_count":
                return None
            total = ((payload.get("info") or {}).get("total_token_usage") or {})
            return (
                int(total.get("input_tokens") or 0)
                + int(total.get("output_tokens") or 0)
                + int(total.get("reasoning_output_tokens") or 0)
            )
        def tail_lines(path, max_bytes=8 * 1024 * 1024):
            try:
                size = path.stat().st_size
                with path.open("rb") as handle:
                    if size > max_bytes:
                        handle.seek(size - max_bytes)
                        handle.readline()
                    data = handle.read()
            except OSError:
                return []
            return data.decode("utf-8", errors="ignore").splitlines()
        def session_id_for(path):
            matches = re.findall(
                r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
                path.stem,
                re.I,
            )
            return matches[-1] if matches else path.stem
        for path in sorted(root.rglob("*.jsonl")):
            try:
                if path.stat().st_mtime < cutoff:
                    continue
            except OSError:
                continue
            session_id = session_id_for(path)
            model = "gpt-5.5"
            best_line = None
            best_score = -1
            for line in tail_lines(path):
                found_model = model_in(line)
                if found_model:
                    model = found_model
                if '"type":"token_count"' not in line and '"type": "token_count"' not in line:
                    continue
                score = token_score(line)
                if score is not None and score >= best_score:
                    best_score = score
                    best_line = line.rstrip()
            if best_line:
                print(f"codexswitch_session={session_id} codexswitch_model={model} " + best_line)
        """#
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, root, String(cutoff)],
            timeout: 8
        )
        guard !result.timedOut, result.terminationStatus == 0 else { return [] }
        return result.stdoutString
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
