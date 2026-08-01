//
//  LinkHeaderParser.swift
//  GitFolderUploader
//
//  Parses RFC-5988 `Link` headers so paginated endpoints can be walked
//  without guessing page counts.
//

import Foundation

enum LinkHeaderParser {

    /// Returns a mapping of `rel` value to URL for a raw `Link` header.
    static func parse(_ header: String?) -> [String: URL] {
        guard let header = header, !header.isEmpty else { return [:] }
        var result: [String: URL] = [:]

        for segment in header.components(separatedBy: ",") {
            let parts = segment.components(separatedBy: ";")
            guard parts.count >= 2 else { continue }

            let rawURL = parts[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard let url = URL(string: rawURL) else { continue }

            for attribute in parts.dropFirst() {
                let trimmed = attribute.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("rel=") else { continue }
                let rel = String(trimmed.dropFirst(4))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                result[rel] = url
            }
        }
        return result
    }

    /// Extracts the `page` query parameter of the `next` link, if present.
    static func nextPage(from header: String?) -> Int? {
        guard let next = parse(header)["next"],
              let components = URLComponents(url: next, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "page" })?.value else {
            return nil
        }
        return Int(value)
    }
}
