//
//  BranchUseCases.swift
//  GitFolderUploader
//

import Foundation

struct ListBranchesUseCase {
    let service: GitDataServiceProtocol

    func callAsFunction(_ ref: RepoRef) async throws -> [Branch] {
        try await service.listBranches(ref)
    }
}

/// Creates a branch pointing at the head of an existing one.
struct CreateBranchUseCase {
    let service: GitDataServiceProtocol

    static func validate(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return L10n.t("branch.error.empty") }
        // Restrictions taken from `git check-ref-format`.
        let forbidden = [" ", "..", "~", "^", ":", "?", "*", "[", "\\", "//", "@{"]
        if forbidden.contains(where: { trimmed.contains($0) }) { return L10n.t("branch.error.chars") }
        if trimmed.hasPrefix("/") || trimmed.hasSuffix("/") || trimmed.hasSuffix(".lock") {
            return L10n.t("branch.error.chars")
        }
        return nil
    }

    func callAsFunction(_ ref: RepoRef, name: String, fromBranch: Branch) async throws -> Branch {
        if let problem = Self.validate(name: name) {
            throw APIError.validationFailed(problem)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = try await service.createBranch(ref, name: trimmed, fromSHA: fromBranch.commitSHA)
        return Branch(name: trimmed, commitSHA: reference.sha, isProtected: false)
    }
}
