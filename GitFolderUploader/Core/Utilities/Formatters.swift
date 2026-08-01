//
//  Formatters.swift
//  GitFolderUploader
//
//  Shared, cached formatters. Creating formatters is expensive, and the upload
//  screens format thousands of values while a job runs.
//

import Foundation

enum Formatters {

    /// "1.2 MB" style byte counts, localized to the active locale.
    static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    /// Relative date, e.g. "3 days ago".
    static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func size(_ bytes: Int) -> String {
        byteCount.string(fromByteCount: Int64(max(bytes, 0)))
    }

    static func relative(_ date: Date?) -> String {
        guard let date = date else { return "" }
        return relativeDate.localizedString(for: date, relativeTo: Date())
    }

    /// Renders a fractional value as an integer percentage.
    static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// Formats a duration in seconds as `m:ss` / `h:mm:ss`.
    /// Transfer rate, e.g. "1.4 MB/s".
    static func speed(_ bytesPerSecond: Double) -> String {
        size(Int(bytesPerSecond.rounded())) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
