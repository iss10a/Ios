//
//  SettingsView.swift
//  GitFolderUploader
//
//  Account, appearance, language and diagnostics.
//

import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.openURL) private var openURL

    @AppStorage("app.theme") private var themeRawValue = AppTheme.system.rawValue
    @State private var isConfirmingSignOut = false
    @State private var rateLimit = RateLimitSnapshot()

    private var theme: AppTheme { AppTheme(rawValue: themeRawValue) ?? .system }

    var body: some View {
        List {
            accountSection
            appearanceSection
            languageSection
            diagnosticsSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("tab.settings"))
        .confirmationDialog(L10n.t("settings.signout.confirm"),
                            isPresented: $isConfirmingSignOut,
                            titleVisibility: .visible) {
            Button(L10n.t("settings.signout"), role: .destructive) {
                environment.signOut()
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("settings.signout.message"))
        }
        .task {
            rateLimit = environment.rateLimit
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var accountSection: some View {
        Section(L10n.t("settings.section.account")) {
            if let user = environment.currentUser {
                HStack(spacing: Design.spacing) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName).font(.headline)
                        Text("@" + user.login)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                DetailRow(title: L10n.t("settings.repos.public"), value: "\(user.publicRepos)")
                if user.privateRepos > 0 {
                    DetailRow(title: L10n.t("settings.repos.private"), value: "\(user.privateRepos)")
                }
                if let kind = environment.auth.storedKind {
                    DetailRow(title: L10n.t("settings.auth_method"), value: L10n.t(kind.titleKey))
                }
                if let url = user.htmlURL {
                    Button(L10n.t("settings.open_profile")) { openURL(url) }
                }
            }

            Button(role: .destructive) {
                isConfirmingSignOut = true
            } label: {
                Label(L10n.t("settings.signout"), systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    private var appearanceSection: some View {
        Section(L10n.t("settings.section.appearance")) {
            Picker(L10n.t("settings.theme"), selection: Binding(get: { theme },
                                                                set: { themeRawValue = $0.rawValue })) {
                ForEach(AppTheme.allCases) { option in
                    Label(L10n.t(option.titleKey), systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.inline)
        }
    }

    private var languageSection: some View {
        Section {
            Picker(L10n.t("settings.language"),
                   selection: Binding(get: { localization.language },
                                      set: { localization.setLanguage($0) })) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.inline)
        } header: {
            Text(L10n.t("settings.section.language"))
        } footer: {
            Text(L10n.t("settings.language.hint"))
        }
    }

    private var diagnosticsSection: some View {
        Section(L10n.t("settings.section.diagnostics")) {
            if rateLimit.limit > 0 {
                DetailRow(title: L10n.t("settings.rate_limit"),
                          value: "\(rateLimit.remaining)/\(rateLimit.limit)")
                DetailRow(title: L10n.t("settings.rate_reset"),
                          value: Formatters.relative(rateLimit.resetDate))
            } else {
                Text(L10n.t("settings.rate_unknown"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(L10n.t("common.refresh")) {
                rateLimit = environment.rateLimit
            }
            DetailRow(title: L10n.t("settings.queue"),
                      value: "\(environment.uploads.activeJobs.count)")
        }
    }

    private var aboutSection: some View {
        Section(L10n.t("settings.section.about")) {
            DetailRow(title: L10n.t("settings.version"),
                      value: "\(AppInfo.version) (\(AppInfo.build))")
            Text(L10n.t("settings.about.blurb"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
