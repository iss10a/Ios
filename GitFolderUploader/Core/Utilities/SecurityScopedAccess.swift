//
//  SecurityScopedAccess.swift
//  GitFolderUploader
//
//  Folders picked from the Files app are handed to us as security-scoped URLs.
//  To keep uploading after the app is relaunched (resume support) we persist a
//  bookmark and re-resolve it later.
//

import Foundation

/// RAII helper that starts security-scoped access and always balances the call.
final class SecurityScopedAccess {

    let url: URL
    private var isAccessing = false

    init(url: URL) {
        self.url = url
        self.isAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Explicitly ends access before deallocation.
    func end() {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
            isAccessing = false
        }
    }
}

enum FolderBookmark {

    /// Creates persistable bookmark data for a picked folder.
    static func makeBookmark(for url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves bookmark data back into a usable URL.
    ///
    /// - Returns: The resolved URL and whether the bookmark should be refreshed.
    static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [],
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }
}
