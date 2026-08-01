//
//  RootView.swift
//  GitFolderUploader
//
//  Switches between the sign-in screen and the main tab bar, and adapts the
//  navigation style for iPad.
//

import SwiftUI

struct RootView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        Group {
            if environment.isRestoringSession {
                LaunchPlaceholder()
            } else if environment.isAuthenticated {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: environment.isAuthenticated)
        .animation(.easeInOut(duration: 0.2), value: environment.isRestoringSession)
    }
}

/// Shown for the brief moment while the stored session is validated.
private struct LaunchPlaceholder: View {
    var body: some View {
        VStack(spacing: Design.spacing) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color.brand)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

/// The four primary sections of the app.
struct MainTabView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var selection: Tab = .repositories

    enum Tab: Hashable {
        case repositories, uploads, search, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                RepositoryListView()
            }
            .tabItem { Label(L10n.t("tab.repositories"), systemImage: "square.stack.3d.up") }
            .tag(Tab.repositories)

            NavigationStack {
                UploadQueueView()
            }
            .tabItem { Label(L10n.t("tab.uploads"), systemImage: "arrow.up.circle") }
            .badge(environment.uploads.activeJobs.count)
            .tag(Tab.uploads)

            NavigationStack {
                RepositorySearchView()
            }
            .tabItem { Label(L10n.t("tab.search"), systemImage: "magnifyingglass") }
            .tag(Tab.search)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label(L10n.t("tab.settings"), systemImage: "gearshape") }
            .tag(Tab.settings)
        }
        .tint(Color.brand)
    }
}
