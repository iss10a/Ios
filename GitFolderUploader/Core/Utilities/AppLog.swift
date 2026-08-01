//
//  AppLog.swift
//  GitFolderUploader
//
//  Very small logging facade over `os.Logger`. Wrapping it keeps call sites
//  free from `OSLogMessage` constraints and lets us silence logs in release.
//

import Foundation
import os

struct AppLog {

    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case error = "ERROR"
    }

    private let logger: Logger

    init(category: String) {
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.gitfolderuploader",
                             category: category)
    }

    // The `os` interpolations take an *escaping* autoclosure, so the message is
    // evaluated into a local first; a non-escaping autoclosure cannot be handed
    // straight to `Logger`.

    func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger.debug("\(text, privacy: .public)")
        #endif
    }

    func info(_ message: @autoclosure () -> String) {
        let text = message()
        logger.info("\(text, privacy: .public)")
    }

    func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
    }

    static let app = AppLog(category: "app")
    static let network = AppLog(category: "network")
    static let upload = AppLog(category: "upload")
    static let storage = AppLog(category: "storage")
    /// File and folder selection: picker, drag & drop, paste, scanning.
    /// Filter the console with `subsystem:com.gitfolderuploader.app category:picker`.
    static let picker = AppLog(category: "picker")
}
