//
//  AuthUseCases.swift
//  GitFolderUploader
//

import Foundation

/// Signs in with a Personal Access Token.
struct SignInWithTokenUseCase {
    let repository: AuthRepositoryProtocol

    func callAsFunction(token: String) async throws -> GitHubUser {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.missingToken }
        return try await repository.signIn(withToken: trimmed)
    }
}

/// Drives the OAuth device flow from start to token.
struct DeviceFlowUseCase {
    let repository: AuthRepositoryProtocol

    /// Scopes required for every feature in the app.
    static let scope = "repo read:user"

    func start(clientID: String) async throws -> DeviceCodeSession {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.validationFailed(L10n.t("auth.device.missing_client")) }
        return try await repository.startDeviceFlow(clientID: trimmed, scope: Self.scope)
    }

    /// Polls until the user approves, the code expires or the task is cancelled.
    func awaitApproval(session: DeviceCodeSession,
                       clientID: String,
                       onTick: @escaping (TimeInterval) -> Void) async throws -> GitHubUser {
        var interval = max(session.interval, 5)

        while true {
            try Task.checkCancellation()
            if session.isExpired { throw APIError.deviceFlowExpired }

            onTick(session.expiryDate.timeIntervalSinceNow)
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            do {
                let token = try await repository.pollDeviceFlow(session: session, clientID: clientID)
                return try await repository.completeSignIn(token: token, kind: .oauthDeviceFlow)
            } catch APIError.deviceFlowPending {
                continue
            } catch APIError.deviceFlowSlowDown(let suggested) {
                interval = max(interval + 5, suggested)
                continue
            }
        }
    }
}

/// Restores an existing session on launch.
struct RestoreSessionUseCase {
    let repository: AuthRepositoryProtocol

    func callAsFunction() async -> GitHubUser? {
        guard repository.storedToken?.isEmpty == false else { return nil }
        return try? await repository.currentUser()
    }
}
