//
//  Array+Chunked.swift
//  GitFolderUploader
//

import Foundation

extension Array {
    /// Splits the array into consecutive slices of at most `size` elements.
    ///
    /// Used to keep `POST /git/trees` payloads well below GitHub's limits when
    /// committing folders with thousands of files.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        var result: [[Element]] = []
        result.reserveCapacity((count + size - 1) / size)
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            result.append(Array(self[index..<end]))
            index = end
        }
        return result
    }
}
