//
//  SourceCapture.swift
//  GitFolderUploader
//
//  Turning a picked file or folder into something that still works later.
//
//  Why everything is copied into app storage
//  -----------------------------------------
//  The obvious approach is a security-scoped bookmark: keep a reference, use
//  it later, copy nothing. That was tried and it does not hold up. A bookmark
//  taken from a document-picker URL resolves fine *while the picker's grant is
//  still open* and then fails once that grant is gone — so a verification step
//  right after creating it reports success and the reference still breaks a
//  moment later. The visible symptom is a selection that arrives correctly and
//  then reports every item as "no longer available", with zero files scanned.
//
//  So capture is deterministic instead of clever: while the grant is
//  unambiguously valid, the item is copied into the app's own container with
//  `FileManager.copyItem`, which is recursive and brings an entire folder tree
//  across in one call. Afterwards nothing depends on security scope, bookmark
//  validity, or how much time has passed — a resumed job days later reads the
//  same bytes.
//
//  The cost is disk space and a copy pass. That is the right trade for a
//  feature whose whole job is to not lose the user's files, and the copies are
//  deleted as soon as their job leaves the queue.
//

import Foundation

enum SourceCapture {

    /// Why an item could not be captured, surfaced in the review sheet.
    ///
    /// Conforms to `Error` because it is carried in a `Result`, whose failure
    /// type is constrained to `Error`.
    struct Failure: Error, LocalizedError {
        let name: String
        let reason: String

        var errorDescription: String? { "\(name): \(reason)" }
    }

    /// Directory holding the app's private copies of picked items.
    static var importsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Imports", isDirectory: true)
    }

    /// Builds an `UploadSource` from a freshly delivered URL.
    ///
    /// Must be called while the URL is still live — inside the picker delegate
    /// callback, or inside an `NSItemProvider` completion handler.
    ///
    /// - Parameter alreadyScoped: `true` when the caller already holds
    ///   security-scoped access, so this does not request it a second time.
    /// - Returns: The source, or the reason capture failed.
    static func capture(url: URL,
                        isFolder declaredFolder: Bool,
                        alreadyScoped: Bool = false,
                        preferredName: String? = nil) -> Result<UploadSource, Failure> {

        // `preferredName` matters for drops and pastes: the URL an
        // `NSItemProvider` hands over is a temporary file whose name the system
        // may rebuild from the content type's preferred extension, so
        // `config.yaml` can arrive as `config.yml`. The provider's
        // `suggestedName` still holds the original, and it wins here.
        let name = preservedName(delivered: url, suggested: preferredName)
        if name != url.lastPathComponent {
            AppLog.picker.info("Restoring original name: delivered '\(url.lastPathComponent)' -> '\(name)'")
        }

        // Step 1 — security-scoped access. Items outside the app container are
        // completely unreadable without it, including for `fileExists`.
        let granted = alreadyScoped ? false : url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        AppLog.picker.info("[\(name)] capture start; scopeGranted=\(granted), alreadyScoped=\(alreadyScoped)")

        // Step 2 — classify. The picker's declared type is not authoritative,
        // so the file system decides whether this is a folder.
        var flag: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &flag)
        let probed = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
        let isFolder = probed ?? (exists ? flag.boolValue : declaredFolder)
        AppLog.picker.info("[\(name)] exists=\(exists), isFolder=\(isFolder) (declared=\(declaredFolder))")

        guard exists else {
            let reason = granted
                ? "not found on disk even with security scope"
                : "security scope was refused, so the path is unreachable"
            AppLog.picker.error("[\(name)] \(reason)")
            return .failure(Failure(name: name, reason: reason))
        }

        // Step 3 — confirm it can actually be read before copying anything.
        if isFolder {
            do {
                let children = try FileManager.default.contentsOfDirectory(atPath: url.path)
                AppLog.picker.info("[\(name)] directory listing succeeded, \(children.count) direct child(ren)")
            } catch {
                let reason = "directory could not be listed: \(error.localizedDescription)"
                AppLog.picker.error("[\(name)] \(reason)")
                return .failure(Failure(name: name, reason: reason))
            }
        } else if !FileManager.default.isReadableFile(atPath: url.path) {
            let reason = "file is not readable"
            AppLog.picker.error("[\(name)] \(reason)")
            return .failure(Failure(name: name, reason: reason))
        }

        // Step 4 — copy into app storage. Recursive, so sub-folders come too.
        do {
            let copied = try importItem(at: url, name: name)
            let count = isFolder
                ? (try? FileManager.default.contentsOfDirectory(atPath: copied.path).count) ?? 0
                : 1
            AppLog.picker.info("[\(name)] imported to \(copied.path); top-level entries=\(count)")

            return .success(UploadSource(kind: isFolder ? .folder : .file,
                                         bookmark: nil,
                                         path: copied.path,
                                         displayName: name,
                                         isImported: true))
        } catch {
            let reason = "copy into app storage failed: \(error.localizedDescription)"
            AppLog.picker.error("[\(name)] \(reason)")
            return .failure(Failure(name: name, reason: reason))
        }
    }

    /// Chooses the name to store an item under.
    ///
    /// The extension is part of a file's identity — Flutter only accepts
    /// `pubspec.yaml`, Codemagic only reads `codemagic.yaml` — so a delivered
    /// name is never trusted over the originally suggested one.
    static func preservedName(delivered: URL, suggested: String?) -> String {
        guard let suggested = suggested?.trimmingCharacters(in: .whitespacesAndNewlines),
              !suggested.isEmpty else {
            return delivered.lastPathComponent
        }
        // A suggestion that already carries an extension is authoritative.
        if !(suggested as NSString).pathExtension.isEmpty { return suggested }

        // Otherwise keep the suggested stem and the delivered extension.
        let deliveredExtension = delivered.pathExtension
        return deliveredExtension.isEmpty ? suggested : suggested + "." + deliveredExtension
    }

    /// Recursively copies an item into the app container.
    static func importItem(at url: URL, name: String) throws -> URL {
        let container = importsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        // Imports are working data, not user documents.
        var mutable = container
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)

        let destination = container.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        // `copyItem` walks the whole tree, sub-folders included.
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Deletes the copies belonging to these sources.
    ///
    /// Called when a job leaves the queue so imports do not pile up.
    static func discardImports(for sources: [UploadSource]) {
        for source in sources where source.isImported {
            // The container is the parent: <Imports>/<uuid>/<name>
            let container = URL(fileURLWithPath: source.path).deletingLastPathComponent()
            guard container.path.hasPrefix(importsDirectory.path) else { continue }
            do {
                try FileManager.default.removeItem(at: container)
                AppLog.picker.info("Discarded import for \(source.displayName)")
            } catch {
                AppLog.picker.error("Could not discard \(source.displayName): \(error.localizedDescription)")
            }
        }
    }

    /// Total bytes currently held by imports, shown in Settings diagnostics.
    static func importsSize() -> Int {
        guard let enumerator = FileManager.default.enumerator(at: importsDirectory,
                                                              includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total = 0
        for case let url as URL in enumerator {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return total
    }
}
