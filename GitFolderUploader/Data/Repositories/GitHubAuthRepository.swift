//
//  GitHubAuthRepository.swift
//  GitFolderUploader
//
//  Token storage plus the two supported sign-in flows.
//
//  Only the OAuth *device* flow is implemented, deliberately: it is the single
//  browser-based flow that does not require embedding a client secret in the
//  app binary, so nothing sensitive ships in the repository.
//

import Foundation

final class GitHubAuthRepository: AuthRepositoryProtocol {

    private let client: HTTPClient
    private let keychain: KeychainStore

    /// Cached token so the client's token provider stays synchronous and cheap.
    private var cachedToken: String?

    init(client: HTTPClient, keychain: KeychainStore) {
        self.client = client
        self.keychain = keychain
        self.cachedToken = keychain.string(for: .accessToken)
    }

    // MARK: - Stored credentials

    var storedToken: String? {
        if let cachedToken = cachedToken { return cachedToken }
        cachedToken = keychain.string(for: .accessToken)
        return cachedToken
    }

    var storedKind: AuthenticationKind? {
        guard let raw = keychain.string(for: .tokenKind) else { return nil }
        return AuthenticationKind(rawValue: raw)
    }

    var oauthClientID: String? {
        get { keychain.string(for: .oauthClientID) }
        set { keychain.set(newValue, for: .oauthClientID) }
    }

    // MARK: - Personal access token

    func signIn(withToken token: String) async throws -> GitHubUser {
        // Validate before persisting so a bad token never sticks.
        let previous = cachedToken
        cachedToken = token
        do {
            let dto: UserDTO = try await client.send(GitHubEndpoints.currentUser)
            persist(token: token, kind: .personalAccessToken)
            return dto.toDomain()
        } catch {
            cachedToken = previous
            throw error
        }
    }

    // MARK: - Device flow

    func startDeviceFlow(clientID: String, scope: String) async throws -> DeviceCodeSession {
        let endpoint = try GitHubEndpoints.deviceCode(clientID: clientID, scope: scope)
        let dto: DeviceCodeDTO = try await client.send(endpoint)
        guard let session = dto.toDomain() else { throw APIError.invalidResponse }
        oauthClientID = clientID
        return session
    }

    func pollDeviceFlow(session: DeviceCodeSession, clientID: String) async throws -> String {
        let endpoint = try GitHubEndpoints.deviceToken(clientID: clientID, deviceCode: session.deviceCode)
        let dto: DeviceTokenDTO = try await client.send(endpoint)

        if let token = dto.accessToken, !token.isEmpty {
            return token
        }
        switch dto.error {
        case "authorization_pending":
            throw APIError.deviceFlowPending
        case "slow_down":
            throw APIError.deviceFlowSlowDown(dto.interval ?? 10)
        case "expired_token":
            throw APIError.deviceFlowExpired
        case "access_denied":
            throw APIError.deviceFlowDenied
        default:
            throw APIError.validationFailed(dto.errorDescription ?? L10n.t("auth.device.failed"))
        }
    }

    func completeSignIn(token: String, kind: AuthenticationKind) async throws -> GitHubUser {
        let previous = cachedToken
        cachedToken = token
        do {
            let dto: UserDTO = try await client.send(GitHubEndpoints.currentUser)
            persist(token: token, kind: kind)
            return dto.toDomain()
        } catch {
            cachedToken = previous
            throw error
        }
    }

    // MARK: - Session

    func currentUser() async throws -> GitHubUser {
        guard storedToken?.isEmpty == false else { throw APIError.missingToken }
        let dto: UserDTO = try await client.send(GitHubEndpoints.currentUser)
        return dto.toDomain()
    }

    func signOut() {
        cachedToken = nil
        keychain.remove(.accessToken)
        keychain.remove(.tokenKind)
    }

    // MARK: - Private

    private func persist(token: String, kind: AuthenticationKind) {
        cachedToken = token
        keychain.set(token, for: .accessToken)
        keychain.set(kind.rawValue, for: .tokenKind)
    }
}
