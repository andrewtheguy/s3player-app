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

    private let defaults: UserDefaults
    private let session: URLSession

    private enum Keys {
        static let host = "auth.host"
        static let token = "auth.token"
        static let playerSessionToken = "auth.playerSessionToken"
    }

    var playerSessionToken: String? {
        get { defaults.string(forKey: Keys.playerSessionToken) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.playerSessionToken)
            } else {
                defaults.removeObject(forKey: Keys.playerSessionToken)
            }
        }
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session

        let storedHost = defaults.string(forKey: Keys.host)
        let storedToken = defaults.string(forKey: Keys.token)

        self.hostText = storedHost ?? Self.defaultHost
        self.host = storedHost
        self.token = storedToken
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
        defaults.removeObject(forKey: Keys.playerSessionToken)
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
