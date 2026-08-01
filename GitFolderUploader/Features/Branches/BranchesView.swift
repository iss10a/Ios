//
//  BranchesView.swift
//  GitFolderUploader
//
//  Lists branches, switches the active one and creates new branches from any
//  existing head.
//

import SwiftUI

struct BranchesView: View {

    let repository: Repository
    @Binding var selectedBranch: String

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var branches: [Branch] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isCreating = false
    @State private var newBranchName = ""
    @State private var baseBranch: Branch?
    @State private var filter = ""

    private var visibleBranches: [Branch] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return branches }
        return branches.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage = errorMessage {
                    ErrorBanner(message: errorMessage) { Task { await load(force: true) } }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                ForEach(visibleBranches) { branch in
                    Button {
                        selectedBranch = branch.name
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.branch")
                                .foregroundStyle(Color.brand)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(branch.name)
                                    .foregroundStyle(.primary)
                                Text(String(branch.commitSHA.prefix(7)))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if branch.isProtected {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if branch.name == selectedBranch {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.brand)
                            }
                        }
                    }
                }
            }
            .searchable(text: $filter, prompt: L10n.t("branch.filter"))
            .navigationTitle(L10n.t("branch.title"))
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if isLoading && branches.isEmpty { LoadingView() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("common.done")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        baseBranch = branches.first { $0.name == selectedBranch } ?? branches.first
                        newBranchName = ""
                        isCreating = true
                    } label: {
                        Label(L10n.t("branch.create"), systemImage: "plus")
                    }
                    .disabled(branches.isEmpty)
                }
            }
            .alert(L10n.t("branch.create"), isPresented: $isCreating) {
                TextField(L10n.t("branch.name"), text: $newBranchName)
                    .textInputAutocapitalization(.never)
                Button(L10n.t("common.cancel"), role: .cancel) {}
                Button(L10n.t("common.create")) {
                    Task { await create() }
                }
            } message: {
                Text(L10n.format("branch.create.hint", baseBranch?.name ?? selectedBranch))
            }
            .task { await load(force: false) }
        }
    }

    private func load(force: Bool) async {
        if !force && !branches.isEmpty { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            branches = try await environment.listBranches(repository.ref)
        } catch {
            errorMessage = FileBrowserViewModel.describe(error)
        }
    }

    private func create() async {
        guard let base = baseBranch else { return }
        do {
            let created = try await environment.createBranch(repository.ref,
                                                             name: newBranchName,
                                                             fromBranch: base)
            branches.append(created)
            branches.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            selectedBranch = created.name
            dismiss()
        } catch {
            errorMessage = FileBrowserViewModel.describe(error)
        }
    }
}
