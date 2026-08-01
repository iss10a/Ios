//
//  RepositoryItem.swift
//  GitFolderUploader
//

import Foundation

/// A single entry inside a repository directory listing.
struct RepositoryItem: Identifiable, Hashable, Codable {

    enum Kind: String, Codable {
        case file
        case directory
        case symlink
        case submodule

        var symbol: String {
            switch self {
            case .file: return "doc.text"
            case .directory: return "folder.fill"
            case .symlink: return "link"
            case .submodule: return "shippingbox"
            }
        }
    }

    let name: String
    /// Repository-relative path, `/` separated.
    let path: String
    let sha: String
    let size: Int
    let kind: Kind
    let downloadURL: URL?

    var id: String { path.isEmpty ? name : path }
    var isDirectory: Bool { kind == .directory }

    /// Lowercased extension, used to pick a preview mode.
    var pathExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    var isProbablyText: Bool {
        let binary: Set<String> = ["png", "jpg", "jpeg", "gif", "pdf", "zip", "ipa", "mp4", "mov",
                                   "heic", "webp", "tar", "gz", "bin", "so", "dylib", "a", "o"]
        return !binary.contains(pathExtension)
    }

    var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(pathExtension)
    }
}

/// Decoded contents of a single file.
struct FileContent {
    let path: String
    let sha: String
    let size: Int
    let data: Data

    var text: String? { String(data: data, encoding: .utf8) }
}
