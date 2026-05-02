//
//  AuthViewModel.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import Combine
import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    static let defaultHost = "https://s3player.local.168234.xyz"

    @Published var hostText: String
    @Published var passwordText = ""
    @Published private(set) var token: String?
    @Published private(set) var host: String?
    @Published private(set) var isLoggingIn = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isValidatingPlayerSession = false
    @Published private(set) var playerSessionValidationError: String?
    @Published private(set) var playerSessionToken: String?

    private let defaults: UserDefaults
    private let session: URLSession
    private var heartbeatTask: Task<Void, Never>?
    private var launchValidationTask: Task<Void, Never>?
    private static let heartbeatInterval: UInt64 = 30 * 1_000_000_000
    private static let launchValidateTimeout: UInt64 = 8 * 1_000_000_000

    private struct LaunchValidateTimedOut: Error {}

    private enum Keys {
        static let host = "auth.host"
        static let token = "auth.token"
        static let playerSessionToken = "auth.playerSessionToken"
    }

    func setPlayerSessionToken(_ newValue: String?) {
        playerSessionToken = newValue
        if let newValue {
            defaults.set(newValue, forKey: Keys.playerSessionToken)
        } else {
            defaults.removeObject(forKey: Keys.playerSessionToken)
        }
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session

        let storedHost = defaults.string(forKey: Keys.host)
        let storedToken = defaults.string(forKey: Keys.token)
        let storedPlayerToken = defaults.string(forKey: Keys.playerSessionToken)

        self.hostText = storedHost ?? Self.defaultHost
        self.host = storedHost
        self.token = storedToken
        self.playerSessionToken = storedPlayerToken

        // Block UI on a launch-time validate so a stale rehydrated player session token resolves before any browse / playback action runs.
        if storedHost != nil, storedToken != nil, storedPlayerToken != nil {
            startLaunchValidation()
        }

        startHeartbeat()
    }

    func retryPlayerSessionValidation() {
        guard playerSessionToken != nil else {
            playerSessionValidationError = nil
            return
        }
        startLaunchValidation()
    }

    func clearAndContinuePlayerSession() {
        launchValidationTask?.cancel()
        launchValidationTask = nil
        setPlayerSessionToken(nil)
        isValidatingPlayerSession = false
        playerSessionValidationError = nil
    }

    private func startLaunchValidation() {
        launchValidationTask?.cancel()
        isValidatingPlayerSession = true
        playerSessionValidationError = nil
        launchValidationTask = Task { await self.validateStoredPlayerSession() }
    }

    func validateStoredPlayerSession() async {
        defer { isValidatingPlayerSession = false }
        guard let client = APIClient(auth: self),
              let playerToken = playerSessionToken else { return }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await client.validateSession(playerToken: playerToken)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: Self.launchValidateTimeout)
                    throw LaunchValidateTimedOut()
                }
                try await group.next()
                group.cancelAll()
            }
            playerSessionValidationError = nil
        } catch is LaunchValidateTimedOut {
            playerSessionValidationError = "The server didn't respond in time."
        } catch APIError.sessionDisplaced {
            // Authoritative "stale" signal — clear silently and proceed; no need to prompt.
            setPlayerSessionToken(nil)
            playerSessionValidationError = nil
        } catch APIError.unauthorized {
            logout()
            playerSessionValidationError = nil
        } catch {
            playerSessionValidationError = (error as? APIError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.heartbeatInterval)
                if Task.isCancelled { return }
                await self?.heartbeatValidate()
            }
        }
    }

    private func heartbeatValidate() async {
        guard let client = APIClient(auth: self),
              let playerToken = playerSessionToken else { return }
        do {
            try await client.validateSession(playerToken: playerToken)
        } catch APIError.sessionDisplaced {
            setPlayerSessionToken(nil)
        } catch APIError.unauthorized {
            logout()
        } catch {
            // Transient: keep token; the next tick retries.
        }
    }

    var isAuthenticated: Bool {
        token != nil && host != nil
    }

    func login() async {
        let trimmedHost = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordText

        guard let baseURL = parsedHost(trimmedHost) else {
            errorMessage = "Enter a valid https:// host URL."
            return
        }
        guard !password.isEmpty else {
            errorMessage = "Enter the site password."
            return
        }

        isLoggingIn = true
        errorMessage = nil
        defer { isLoggingIn = false }

        let url = baseURL.appendingPathComponent("api/auth/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(["password": password])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                errorMessage = "Unexpected response from server."
                return
            }

            switch http.statusCode {
            case 200:
                let decoded = try JSONDecoder().decode(TokenLoginResponse.self, from: data)
                persist(host: baseURL.absoluteString, token: decoded.token)
                passwordText = ""
            case 401:
                errorMessage = "Incorrect password."
            case 422:
                errorMessage = "Invalid login request."
            default:
                errorMessage = "Login failed (HTTP \(http.statusCode))."
            }
        } catch {
            errorMessage = "Could not reach host: \(error.localizedDescription)"
        }
    }

    func logout() {
        token = nil
        defaults.removeObject(forKey: Keys.token)
        setPlayerSessionToken(nil)
        passwordText = ""
        errorMessage = nil
    }

    private func persist(host: String, token: String) {
        self.host = host
        self.token = token
        defaults.set(host, forKey: Keys.host)
        defaults.set(token, forKey: Keys.token)
    }

    private func parsedHost(_ text: String) -> URL? {
        guard
            let url = URL(string: text),
            let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            url.host != nil
        else {
            return nil
        }
        return url
    }

    private struct TokenLoginResponse: Decodable {
        let token: String
    }
}
