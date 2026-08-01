//
//  Branch.swift
//  GitFolderUploader
//

import Foundation

/// A branch head.
struct Branch: Identifiable, Hashable, Codable {
    let name: String
    let commitSHA: String
    let isProtected: Bool

    var id: String { name }

    /// Fully qualified ref used by the Git Data API.
    var qualifiedRef: String { "heads/" + name }
}
