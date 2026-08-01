//
//  GitFolderUploaderApp.swift
//  GitFolderUploader
//
//  Application entry point: registers the background-processing task, injects
//  the composition root and applies the user's theme / language preferences.
//

import SwiftUI
import UIKit
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

@main
struct GitFolderUploaderApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var environment = AppEnvironment.shared
    @StateObject private var localization = LocalizationManager.shared

    @AppStorage("app.theme") private var themeRawValue = AppTheme.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private var theme: AppTheme { AppTheme(rawValue: themeRawValue) ?? .system }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(localization)
                .preferredColorScheme(theme.colorScheme)
                .environment(\.locale, localization.language.locale)
                .environment(\.layoutDirection, localization.language.layoutDirection)
                .task {
                    await environment.restoreSession()
                }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                environment.uploads.applicationDidEnterBackground()
            case .active:
                environment.uploads.applicationWillEnterForeground()
            default:
                break
            }
        }
    }
}

/// Hosts the pieces of app lifecycle SwiftUI does not expose directly.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        registerBackgroundTasks()
        return true
    }

    /// Registers the handler that resumes interrupted uploads while the app is
    /// not in the foreground. The identifier must match Info.plist.
    private func registerBackgroundTasks() {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: UploadManager.backgroundTaskIdentifier,
                                        using: nil) { task in
            Task { @MainActor in
                let manager = AppEnvironment.shared.uploads
                task.expirationHandler = {
                    Task { @MainActor in manager.pauseForBackgroundExpiry() }
                }
                manager.resumeAll()
                manager.startNextIfIdle()

                // Give the queue a bounded window, then hand time back to iOS.
                try? await Task.sleep(nanoseconds: 25 * 1_000_000_000)
                manager.scheduleBackgroundResume()
                task.setTaskCompleted(success: true)
            }
        }
        #endif
    }
}
