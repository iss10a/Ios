//
//  DocumentPicker.swift
//  GitFolderUploader
//
//  Folder support, done the way UIKit actually allows it.
//
//  Why this exists instead of SwiftUI's `.fileImporter`
//  ---------------------------------------------------
//  Attaching two `.fileImporter` modifiers to the same view does not give you
//  two pickers: SwiftUI keeps only one of them, so the "choose folder" button
//  silently opened the file picker. Folders then behaved like navigation
//  targets rather than selectable items, which is exactly the symptom of
//  folders "not working at all".
//
//  Wrapping `UIDocumentPickerViewController` directly removes the ambiguity
//  and gives access to the parts SwiftUI does not expose: `asCopy: false`
//  (needed for in-place, security-scoped folder URLs), the starting directory,
//  and reliable multiple selection.
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// What the picker is being opened for.
///
/// `Identifiable` so a single `sheet(item:)` can drive both modes; two
/// separate presentations on one view do not survive SwiftUI's diffing.
enum DocumentPickerMode: String, Identifiable {
    case files
    case folders

    var id: String { rawValue }

    /// `UTType.folder` is the only type that makes a folder *selectable*.
    /// With `.item`, iOS treats a folder as something to navigate into.
    var contentTypes: [UTType] {
        switch self {
        case .files: return [.item]
        case .folders: return [.folder]
        }
    }

    var label: String { rawValue }
}

/// Presents the system document picker and hands back security-scoped URLs.
struct DocumentPicker: UIViewControllerRepresentable {

    let mode: DocumentPickerMode
    var allowsMultipleSelection: Bool = true
    var onPick: ([URL]) -> Void
    var onCancel: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // `asCopy: false` is essential for folders: it returns the original,
        // security-scoped URL instead of a snapshot copy, which is what lets
        // the app walk the real directory tree.
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: mode.contentTypes,
                                                        asCopy: false)
        controller.allowsMultipleSelection = allowsMultipleSelection
        controller.shouldShowFileExtensions = true
        controller.delegate = context.coordinator
        AppLog.picker.info("Opening document picker for \(mode.label), multiple=\(allowsMultipleSelection)")
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {

        private let mode: DocumentPickerMode
        private let onPick: ([URL]) -> Void
        private let onCancel: (() -> Void)?

        init(mode: DocumentPickerMode,
             onPick: @escaping ([URL]) -> Void,
             onCancel: (() -> Void)?) {
            self.mode = mode
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            AppLog.picker.info("Picker returned \(urls.count) item(s) for \(self.mode.label)")
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            AppLog.picker.info("Picker cancelled")
            onCancel?()
        }
    }
}

/// Turns the `NSItemProvider` values produced by a drop or a paste into upload
/// sources.
///
/// iOS limitation, and the official way around it
/// ----------------------------------------------
/// A folder cannot travel through `UIPasteboard` as raw data, and the URL a
/// provider hands over is only valid *inside* the completion handler. So the
/// capture — bookmark or sandbox copy — happens right there, before the URL
/// goes stale. Returning URLs and capturing later simply does not work for
/// folders.
///
/// `loadInPlaceFileRepresentation` is tried first because it offers the
/// original item without copying; `loadFileRepresentation` is the fallback and
/// delivers a copy, which is fine for folders too since the copy is recursive.
enum ItemProviderLoader {

    /// Resolves every provider that can produce a file or folder.
    static func loadSources(from providers: [NSItemProvider]) async -> [UploadSource] {
        var sources: [UploadSource] = []
        for provider in providers {
            if let source = await loadSource(from: provider) {
                sources.append(source)
            }
        }
        AppLog.picker.info("Resolved \(sources.count) source(s) from \(providers.count) provider(s)")
        return sources
    }

    private static func loadSource(from provider: NSItemProvider) async -> UploadSource? {
        let types = provider.registeredTypeIdentifiers.joined(separator: ", ")
        AppLog.picker.info("Provider offers: \(types)")

        // Folders first: a provider able to offer a folder must never be
        // reduced to a plain item, or the tree is lost.
        let folderID = UTType.folder.identifier
        if provider.hasItemConformingToTypeIdentifier(folderID) {
            if let source = await capture(provider, identifier: folderID, isFolder: true) {
                return source
            }
            AppLog.picker.error("Provider declared a folder but produced nothing usable")
        }

        for identifier in [UTType.fileURL.identifier, UTType.item.identifier]
        where provider.hasItemConformingToTypeIdentifier(identifier) {
            if let source = await capture(provider, identifier: identifier, isFolder: false) {
                return source
            }
        }

        AppLog.picker.error("Provider produced no usable source; types: \(types)")
        return nil
    }

    /// Loads one representation and captures it before the URL expires.
    private static func capture(_ provider: NSItemProvider,
                                identifier: String,
                                isFolder declaredFolder: Bool) async -> UploadSource? {

        // Captured before any loading, because the URL that comes back may
        // carry a system-rebuilt name with the wrong extension.
        let suggested = provider.suggestedName
        AppLog.picker.info("Provider suggestedName=\(suggested ?? "nil")")

        if let source = await withCheckedContinuation({ (continuation: CheckedContinuation<UploadSource?, Never>) in
            var resumed = false
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: identifier) { url, isInPlace, error in
                guard !resumed else { return }
                resumed = true
                if let error = error {
                    AppLog.picker.error("In-place load failed for \(identifier): \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                guard let url = url else {
                    continuation.resume(returning: nil)
                    return
                }
                let isFolder = Self.isDirectory(url) ?? declaredFolder
                AppLog.picker.info("In-place URL \(url.lastPathComponent), inPlace=\(isInPlace), isFolder=\(isFolder)")
                // Capture now: this URL dies when the handler returns.
                switch SourceCapture.capture(url: url,
                                             isFolder: isFolder,
                                             preferredName: suggested) {
                case .success(let source):
                    continuation.resume(returning: source)
                case .failure(let failure):
                    AppLog.picker.error("In-place capture failed for \(failure.name): \(failure.reason)")
                    continuation.resume(returning: nil)
                }
            }
        }) {
            return source
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<UploadSource?, Never>) in
            var resumed = false
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                guard !resumed else { return }
                resumed = true
                if let error = error {
                    AppLog.picker.error("Copy load failed for \(identifier): \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                guard let url = url else {
                    continuation.resume(returning: nil)
                    return
                }
                let isFolder = Self.isDirectory(url) ?? declaredFolder
                AppLog.picker.info("Copied URL \(url.lastPathComponent), isFolder=\(isFolder)")
                // The delivered item is deleted when the handler returns, so it
                // is imported into app storage immediately.
                let name = SourceCapture.preservedName(delivered: url, suggested: suggested)
                if name != url.lastPathComponent {
                    AppLog.picker.info("Restoring original name: delivered '\(url.lastPathComponent)' -> '\(name)'")
                }
                do {
                    let imported = try SourceCapture.importItem(at: url, name: name)
                    continuation.resume(returning: UploadSource(kind: isFolder ? .folder : .file,
                                                                bookmark: nil,
                                                                path: imported.path,
                                                                displayName: name,
                                                                isImported: true))
                } catch {
                    AppLog.picker.error("Could not import dropped item: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Asks the file system rather than trusting the declared type.
    static func isDirectory(_ url: URL) -> Bool? {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
           let flag = values.isDirectory {
            return flag
        }
        var flag: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) {
            return flag.boolValue
        }
        return nil
    }

    /// Item providers currently sitting on the system pasteboard.
    ///
    /// iOS limitation: a folder copied in the Files app arrives as a provider,
    /// not as pasteboard data, so this is the only way to read it.
    static func pasteboardProviders() -> [NSItemProvider] {
        let providers = UIPasteboard.general.itemProviders
        AppLog.picker.info("Pasteboard holds \(providers.count) provider(s)")
        return providers
    }

    /// Whether the pasteboard currently holds something the app can upload.
    static var pasteboardHasFiles: Bool {
        UIPasteboard.general.itemProviders.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.folder.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.item.identifier)
        }
    }
}
