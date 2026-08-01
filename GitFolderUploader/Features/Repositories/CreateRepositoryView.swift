//
//  CreateRepositoryView.swift
//  GitFolderUploader
//

import SwiftUI

/// Modal form that creates a repository through `POST /user/repos`.
struct CreateRepositoryView: View {

    /// Called with the created repository so the list can update in place.
    var onCreated: (Repository) -> Void

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var isPrivate = true
    @State private var autoInit = true
    @State private var gitignore = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    private var validationMessage: String? {
        name.isEmpty ? nil : CreateRepositoryUseCase.validate(name: name)
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validationMessage == nil
            && !isBusy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("create.section.basics")) {
                    TextField(L10n.t("create.name"), text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.t("create.description"), text: $description, axis: .vertical)
                        .lineLimit(1...3)
                    if let validationMessage = validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                // `Section` has no overload taking a title *and* a footer, so
                // the header is supplied as a builder here.
                Section {
                    Toggle(L10n.t("create.private"), isOn: $isPrivate)
                    Toggle(L10n.t("create.auto_init"), isOn: $autoInit)
                    TextField(L10n.t("create.gitignore"), text: $gitignore)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(L10n.t("create.section.options"))
                } footer: {
                    Text(L10n.t("create.auto_init.hint"))
                }

                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.t("repos.create"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isBusy { ProgressView() } else { Text(L10n.t("common.create")) }
                    }
                    .disabled(!canSubmit)
                }
            }
            .interactiveDismissDisabled(isBusy)
        }
    }

    private func submit() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        let request = NewRepositoryRequest(name: name,
                                           description: description,
                                           isPrivate: isPrivate,
                                           autoInit: autoInit,
                                           gitignoreTemplate: gitignore.isEmpty ? nil : gitignore)
        do {
            let created = try await environment.createRepository(request)
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
