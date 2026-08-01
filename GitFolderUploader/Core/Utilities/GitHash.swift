//
//  GitHash.swift
//  GitFolderUploader
//
//  Computes Git object identifiers locally.
//
//  Git addresses a file by `SHA1("blob " + <byte count> + "\0" + <contents>)`.
//  Computing this on device lets the uploader compare a local file against the
//  SHA already stored in the remote tree and skip identical content entirely —
//  which is what makes re-uploading a large folder cheap.
//

import Foundation
import CryptoKit

enum GitHash {

    /// Chunk size used when streaming large files through the digest.
    static let chunkSize = 1 * 1024 * 1024

    /// Computes the Git blob SHA-1 for in-memory data.
    static func blobSHA(for data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Streams a file from disk through the digest without loading it whole.
    ///
    /// - Parameters:
    ///   - url: File to hash. The caller is responsible for security-scoped access.
    ///   - size: Known byte count (avoids a second `stat`).
    /// - Returns: The 40 character hexadecimal Git blob SHA-1.
    static func blobSHA(ofFileAt url: URL, size: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))

        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
