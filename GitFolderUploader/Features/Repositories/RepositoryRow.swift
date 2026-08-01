//
//  RepositoryRow.swift
//  GitFolderUploader
//

import SwiftUI

/// Single row in a repository list.
struct RepositoryRow: View {

    let repository: Repository

    var body: some View {
        HStack(alignment: .top, spacing: Design.spacing) {
            Image(systemName: repository.isPrivate ? "lock.fill" : "book.closed")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.brand)
                .frame(width: Design.rowIconSize)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(repository.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(repository.fullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let description = repository.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: Design.spacing) {
                    if let language = repository.language, !language.isEmpty {
                        Label(language, systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Label("\(repository.stargazersCount)", systemImage: "star")
                    if repository.sizeKB > 0 {
                        Text(Formatters.size(repository.sizeKB * 1024))
                    }
                    if let updated = repository.updatedAt {
                        Text(Formatters.relative(updated))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}
