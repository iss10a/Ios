//
//  LoginView.swift
//  GitFolderUploader
//
//  Sign-in screen offering a Personal Access Token or the OAuth device flow.
//

import SwiftUI

struct LoginView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var localization = LocalizationManager.shared
    @StateObject private var viewModel = LoginViewModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header

                    Picker(L10n.t("auth.mode"), selection: $viewModel.mode) {
                        ForEach(LoginViewModel.Mode.allCases) { mode in
                            Text(L10n.t(mode.titleKey)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if viewModel.mode == .token {
                        tokenSection
                    } else {
                        oauthSection
                    }

                    if let message = viewModel.errorMessage {
                        ErrorBanner(message: message)
                    }

                    footer
                }
                .padding()
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L10n.t("auth.title"))
            .onDisappear { viewModel.cancelPendingWork() }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: Design.tightSpacing) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Color.brand)
            Text(L10n.t("auth.headline"))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(L10n.t("auth.subheadline"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: Design.spacing) {
            Text(L10n.t("auth.token.label"))
                .font(.subheadline.weight(.medium))

            SecureField("ghp_…", text: $viewModel.token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .padding(Design.spacing)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Design.smallRadius))

            Text(L10n.t("auth.token.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task { await viewModel.signInWithToken() }
            } label: {
                HStack {
                    if viewModel.isBusy { ProgressView().padding(.trailing, 4) }
                    Text(L10n.t("auth.signin"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canSubmitToken)

            Button(L10n.t("auth.token.create")) {
                openURL(URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=GitFolderUploader")!)
            }
            .font(.footnote)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Design.cornerRadius))
    }

    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: Design.spacing) {
            if let session = viewModel.deviceSession {
                deviceCodePanel(session)
            } else {
                Text(L10n.t("auth.oauth.client_label"))
                    .font(.subheadline.weight(.medium))

                TextField("Iv1.…", text: $viewModel.clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(Design.spacing)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: Design.smallRadius))

                Text(L10n.t("auth.oauth.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await viewModel.startDeviceFlow() }
                } label: {
                    HStack {
                        if viewModel.isBusy { ProgressView().padding(.trailing, 4) }
                        Text(L10n.t("auth.oauth.start"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canStartDeviceFlow)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Design.cornerRadius))
    }

    private func deviceCodePanel(_ session: DeviceCodeSession) -> some View {
        VStack(spacing: Design.spacing) {
            Text(L10n.t("auth.device.instructions"))
                .font(.subheadline)
                .multilineTextAlignment(.center)

            Text(session.userCode)
                .font(.system(.title, design: .monospaced).weight(.bold))
                .tracking(4)
                .padding(.vertical, Design.spacing)
                .frame(maxWidth: .infinity)
                .background(Color.brand.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: Design.smallRadius))
                .textSelection(.enabled)

            HStack(spacing: Design.spacing) {
                Button(L10n.t("common.copy")) { viewModel.copyUserCode() }
                    .buttonStyle(.bordered)
                Button(L10n.t("auth.device.open")) { openURL(session.verificationURL) }
                    .buttonStyle(.borderedProminent)
            }

            HStack(spacing: Design.tightSpacing) {
                ProgressView()
                Text(L10n.t("auth.device.waiting"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(Formatters.duration(viewModel.secondsRemaining))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button(L10n.t("common.cancel"), role: .cancel) { viewModel.cancelDeviceFlow() }
                .font(.footnote)
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text(L10n.t("auth.privacy"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("\(AppInfo.name) \(AppInfo.version) (\(AppInfo.build))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
    }
}
