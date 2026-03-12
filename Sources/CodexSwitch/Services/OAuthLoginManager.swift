import Foundation
import CryptoKit
import Network
import AppKit
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "OAuth")

/// Handles the ChatGPT OAuth login flow:
/// 1. Generate PKCE code_verifier + code_challenge
/// 2. Start local HTTP server on port 1455
/// 3. Open browser to auth.openai.com/oauth/authorize
/// 4. Capture callback with auth code
/// 5. Exchange code for tokens
actor OAuthLoginManager {
    private static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authBaseURL = "https://auth.openai.com"
    private static let port: UInt16 = 1455
    private static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"

    private var listener: NWListener?

    struct OAuthTokens: Sendable {
        let accessToken: String
        let idToken: String
        let refreshToken: String
    }

    /// Full OAuth flow: start server → open browser → wait for callback → exchange tokens.
    func performLogin() async throws -> CodexAccount {
        let verifier = Self.generateCodeVerifier()
        let challenge = Self.generateCodeChallenge(from: verifier)
        let state = Self.generateState()
        let redirectURI = "http://localhost:\(Self.port)/auth/callback"

        let authorizeURL = Self.buildAuthorizeURL(
            challenge: challenge,
            state: state,
            redirectURI: redirectURI
        )

        // Start listening, open browser, wait for callback
        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            Task {
                do {
                    // Start the local HTTP server
                    let receivedCode = try await self.startCallbackServer(expectedState: state, authorizeURL: authorizeURL)
                    continuation.resume(returning: receivedCode)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        let tokens = try await exchangeCodeForTokens(
            code: code,
            verifier: verifier,
            redirectURI: redirectURI
        )

        let email = Self.extractEmail(from: tokens.idToken) ?? "unknown@imported"
        let accountId = Self.extractAccountId(from: tokens.accessToken) ?? UUID().uuidString

        return CodexAccount(
            email: email,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            accountId: accountId,
            lastRefreshed: Date()
        )
    }

    // MARK: - PKCE

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }

    private static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    // MARK: - Authorize URL

    private static func buildAuthorizeURL(challenge: String, state: String, redirectURI: String) -> URL {
        var components = URLComponents(string: "\(authBaseURL)/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        return components.url!
    }

    // MARK: - Local Callback Server

    /// Start a TCP server on port 1455, open the browser, and wait for the OAuth callback.
    private func startCallbackServer(expectedState: String, authorizeURL: URL) async throws -> String {
        // Use a raw TCP socket approach with URLSession-compatible HTTP parsing
        let serverSocket = try Self.createServerSocket(port: Self.port)
        defer { close(serverSocket) }

        logger.info("OAuth callback server listening on port \(Self.port)")

        // Open browser now that server is ready
        _ = await MainActor.run {
            NSWorkspace.shared.open(authorizeURL)
        }

        // Wait for callback with 120s timeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.acceptAndParseCallback(serverSocket: serverSocket, expectedState: expectedState)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(120))
                throw OAuthError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func createServerSocket(port: UInt16) throws -> Int32 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw OAuthError.serverFailed("socket() failed") }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(sock)
            throw OAuthError.serverFailed("bind() failed on port \(port): errno \(errno)")
        }

        guard listen(sock, 1) == 0 else {
            close(sock)
            throw OAuthError.serverFailed("listen() failed")
        }

        return sock
    }

    private func acceptAndParseCallback(serverSocket: Int32, expectedState: String) async throws -> String {
        // Set non-blocking with poll loop for cancellation support
        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        while !Task.isCancelled {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientSock = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverSocket, sockPtr, &addrLen)
                }
            }

            if clientSock < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try await Task.sleep(for: .milliseconds(50))
                    continue
                }
                throw OAuthError.serverFailed("accept() failed: errno \(errno)")
            }

            defer { close(clientSock) }

            // Read the HTTP request
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(clientSock, &buffer, buffer.count)
            guard bytesRead > 0 else { continue }

            let requestString = String(bytes: buffer[..<bytesRead], encoding: .utf8) ?? ""

            // Parse the request line: GET /auth/callback?code=XXX&state=YYY HTTP/1.1
            guard let firstLine = requestString.components(separatedBy: "\r\n").first,
                  firstLine.hasPrefix("GET /auth/callback") else {
                // Not our callback — send 404 and keep listening
                let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                _ = response.withCString { write(clientSock, $0, strlen($0)) }
                continue
            }

            // Extract query string
            guard let urlPart = firstLine.split(separator: " ").dropFirst(0).first?.split(separator: " ").first,
                  let components = URLComponents(string: String(urlPart)) else {
                let response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
                _ = response.withCString { write(clientSock, $0, strlen($0)) }
                continue
            }

            let queryItems = components.queryItems ?? []

            // Check for error
            if let error = queryItems.first(where: { $0.name == "error" })?.value {
                let desc = queryItems.first(where: { $0.name == "error_description" })?.value ?? error
                let errorHTML = Self.errorHTML(message: desc)
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(errorHTML.utf8.count)\r\n\r\n\(errorHTML)"
                _ = response.withCString { write(clientSock, $0, strlen($0)) }
                throw OAuthError.authorizationDenied(desc)
            }

            // Validate state
            guard let receivedState = queryItems.first(where: { $0.name == "state" })?.value,
                  receivedState == expectedState else {
                let response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
                _ = response.withCString { write(clientSock, $0, strlen($0)) }
                throw OAuthError.stateMismatch
            }

            // Extract code
            guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
                let response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
                _ = response.withCString { write(clientSock, $0, strlen($0)) }
                throw OAuthError.missingCode
            }

            // Send success response
            let successHTML = Self.successHTML()
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(successHTML.utf8.count)\r\n\r\n\(successHTML)"
            _ = response.withCString { write(clientSock, $0, strlen($0)) }

            logger.info("OAuth callback received successfully")
            return code
        }

        throw CancellationError()
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, verifier: String, redirectURI: String) async throws -> OAuthTokens {
        let tokenURL = URL(string: "\(Self.authBaseURL)/oauth/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", Self.clientId),
            ("code_verifier", verifier),
        ]
        let body = params
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.1)" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw OAuthError.tokenExchangeFailed(statusCode: statusCode, body: String(responseBody.prefix(500)))
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let id_token: String
            let refresh_token: String
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        logger.info("Token exchange successful")

        return OAuthTokens(
            accessToken: tokenResponse.access_token,
            idToken: tokenResponse.id_token,
            refreshToken: tokenResponse.refresh_token
        )
    }

    // MARK: - JWT Parsing

    private static func extractEmail(from jwt: String) -> String? {
        extractClaim(from: jwt, key: "email") as? String
    }

    private static func extractAccountId(from jwt: String) -> String? {
        guard let authClaims = extractClaim(from: jwt, key: "https://api.openai.com/auth") as? [String: Any] else {
            return nil
        }
        return authClaims["chatgpt_account_id"] as? String
    }

    private static func extractClaim(from jwt: String, key: String) -> Any? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
        while base64.count % 4 != 0 { base64.append("=") }
        // Convert URL-safe base64 to standard
        let standard = base64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: standard),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json[key]
    }

    // MARK: - HTML Responses

    private static func successHTML() -> String {
        """
        <!DOCTYPE html>
        <html>
        <head><title>CodexSwitch</title>
        <style>
            body { font-family: -apple-system, system-ui; background: #1a1a1e; color: #fff;
                   display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
            .card { text-align: center; padding: 40px; }
            h1 { font-size: 24px; margin-bottom: 8px; }
            p { color: #888; font-size: 14px; }
            .icon { font-size: 48px; margin-bottom: 16px; }
        </style>
        </head>
        <body>
            <div class="card">
                <div class="icon">&#9889;</div>
                <h1>Account Added</h1>
                <p>You can close this tab and return to CodexSwitch.</p>
            </div>
        </body>
        </html>
        """
    }

    private static func errorHTML(message: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head><title>CodexSwitch — Error</title>
        <style>
            body { font-family: -apple-system, system-ui; background: #1a1a1e; color: #fff;
                   display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
            .card { text-align: center; padding: 40px; }
            h1 { font-size: 24px; color: #ff6b6b; margin-bottom: 8px; }
            p { color: #888; font-size: 14px; }
        </style>
        </head>
        <body>
            <div class="card">
                <h1>Login Failed</h1>
                <p>\(message)</p>
            </div>
        </body>
        </html>
        """
    }

}

// MARK: - Errors

enum OAuthError: Error, LocalizedError, Sendable {
    case timeout
    case serverFailed(String)
    case authorizationDenied(String)
    case stateMismatch
    case missingCode
    case tokenExchangeFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "Login timed out (120s)"
        case .serverFailed(let msg): return "Callback server failed: \(msg)"
        case .authorizationDenied(let msg): return "Authorization denied: \(msg)"
        case .stateMismatch: return "OAuth state mismatch (possible CSRF)"
        case .missingCode: return "No authorization code in callback"
        case .tokenExchangeFailed(let code, _): return "Token exchange failed (HTTP \(code))"
        }
    }
}

// MARK: - Base64URL

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
