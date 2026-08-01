//
//  AppTheme.swift
//  GitFolderUploader
//
//  Appearance preference plus the small design-token layer the views share.
//

import SwiftUI

/// User selectable colour scheme.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var titleKey: String {
        switch self {
        case .system: return "settings.theme.system"
        case .light: return "settings.theme.light"
        case .dark: return "settings.theme.dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// Shared spacing / radius tokens so screens stay visually consistent.
enum Design {
    static let cornerRadius: CGFloat = 14
    static let smallRadius: CGFloat = 8
    static let spacing: CGFloat = 12
    static let tightSpacing: CGFloat = 6
    static let rowIconSize: CGFloat = 26
}

extension Color {
    /// Accent colour defined in the asset catalog.
    static var brand: Color { Color("AccentColor") }

    /// Colour used for a repository content row icon.
    static func icon(for isDirectory: Bool) -> Color {
        isDirectory ? .brand : .secondary
    }
}
