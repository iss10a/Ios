//
//  LoginViewModel.swift
//  GitFolderUploader
//

import Foundation
import SwiftUI
import UIKit

@MainActor
final class LoginViewModel: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case token
        case oauth

        var id: String { rawValue }
        var titleKey: String { self == .token ? "auth.mode.token" : "auth.mode.oauth" }
    }

    // MARK: - Inputs

    @Published var mode: Mode = .token
    @Published var token: String = ""
    @Published var clientID: String = ""

    // MARK: - Outputs

    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var deviceSession: DeviceCodeSession?
    @Published private(set) var secondsRemaining: TimeInterval = 0

    private let environment: AppEnvironment
    private var pollTask: Task<Void, Never>?

    init(environment: AppEnvironment? = nil) {
        self.environment = environment ?? .shared
        self.clientID = self.environment.auth.oauthClientID ?? ""
    }

    /// Cancels the device-flow poll. Called from the view's `onDisappear`;
    /// `deinit` cannot touch isolated state on a main-actor class.
    func cancelPendingWork() {
        pollTask?.cancel()
        pollTask = nil
    }

    var canSubmitToken: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    var canStartDeviceFlow: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    // MARK: - Personal access token

    func signInWithToken() async {
        guard canSubmitToken else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let user = try await environment.signInWithToken(token: token)
            token = ""
            environment.setSignedIn(user: user)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - OAuth device flow

    /// Requests a device code and begins polling in the background.
    func startDeviceFlow() async {
        guard canStartDeviceFlow else { return }
        isBusy = true
        errorMessage = nil

        do {
            let session = try await environment.deviceFlow.start(clientID: clientID)
            deviceSession = session
            secondsRemaining = session.expiresIn
            isBusy = false
            beginPolling(session: session)
        } catch {
            isBusy = false
            errorMessage = Self.describe(error)
        }
    }

    func cancelDeviceFlow() {
        pollTask?.cancel()
        pollTask = nil
        deviceSession = nil
        secondsRemaining = 0
    }

    /// Copies the one-time code so the user can paste it on github.com.
    func copyUserCode() {
        guard let code = deviceSession?.userCode else { return }
        UIPasteboard.general.string = code
    }

    private func beginPolling(session: DeviceCodeSession) {
        pollTask?.cancel()
        let clientID = self.clientID
        let flow = environment.deviceFlow

        pollTask = Task { [weak self] in
            do {
                let user = try await flow.awaitApproval(session: session, clientID: clientID) { remaining in
                    Task { @MainActor in self?.secondsRemaining = max(remaining, 0) }
                }
                self?.deviceSession = nil
                self?.environment.setSignedIn(user: user)
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = LoginViewModel.describe(error)
                self?.deviceSession = nil
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
