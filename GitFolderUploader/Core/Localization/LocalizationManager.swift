//
//  LocalizationManager.swift
//  GitFolderUploader
//
//  Runtime language switching. iOS normally requires an app restart to change
//  language; loading the `.lproj` bundle ourselves lets the user flip between
//  Arabic and English instantly, including layout direction.
//

import Foundation
import SwiftUI

/// Languages shipped with the app.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case arabic = "ar"

    var id: String { rawValue }

    /// Name shown in the picker, written in the language itself.
    var displayName: String {
        switch self {
        case .system: return L10n.t("settings.language.system")
        case .english: return "English"
        case .arabic: return "العربية"
        }
    }

    /// Resolves `.system` against the device preference.
    var resolvedCode: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("ar") ? "ar" : "en"
        case .english: return "en"
        case .arabic: return "ar"
        }
    }

    var layoutDirection: LayoutDirection {
        resolvedCode == "ar" ? .rightToLeft : .leftToRight
    }

    var locale: Locale { Locale(identifier: resolvedCode) }
}

/// Owns the active language and vends localized strings.
///
/// Views observe the shared instance so a language change re-renders the whole
/// tree without a restart.
final class LocalizationManager: ObservableObject {

    static let shared = LocalizationManager()

    private static let storageKey = "app.language"

    @Published private(set) var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
            reloadBundle()
        }
    }

    private var bundle: Bundle = .main

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguage.system.rawValue
        self.language = AppLanguage(rawValue: stored) ?? .system
        reloadBundle()
    }

    /// Changes the active language and notifies observers.
    func setLanguage(_ newValue: AppLanguage) {
        guard newValue != language else { return }
        language = newValue
    }

    /// Looks up `key` in the active `.lproj` bundle, falling back to the key itself.
    func string(_ key: String, comment: String = "") -> String {
        let value = bundle.localizedString(forKey: key, value: nil, table: nil)
        if value != key { return value }
        // Fall back to the base bundle so a missing translation still reads well.
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    private func reloadBundle() {
        let code = language.resolvedCode
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let localized = Bundle(path: path) {
            bundle = localized
        } else {
            bundle = .main
        }
    }
}

/// Global shorthand used throughout the UI: `L10n.t("repos.title")`.
enum L10n {
    static func t(_ key: String) -> String {
        LocalizationManager.shared.string(key)
    }

    /// Localized string with `String(format:)` arguments.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: LocalizationManager.shared.string(key), arguments: arguments)
    }
}
