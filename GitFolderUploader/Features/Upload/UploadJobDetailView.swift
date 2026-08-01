//
//  UploadJobDetailView.swift
//  GitFolderUploader
//
//  Per-job breakdown: overall progress, per-file state and controls.
//

import SwiftUI

struct UploadJobDetailView: View {

    let jobID: UUID

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var uploads: UploadManager
    @Environment(\.dismiss) private var dismiss

    @State private var filter: FileFilter = .all

    enum FileFilter: String, CaseIterable, Identifiable {
        case all, pending, uploaded, skipped, failed
        var id: String { rawValue }
        var titleKey: String { "upload.filter." + rawValue }
    }

    init(jobID: UUID, uploads: UploadManager? = nil) {
        self.jobID = jobID
        _uploads = ObservedObject(wrappedValue: uploads ?? AppEnvironment.shared.uploads)
    }

    private var job: UploadJob? { uploads.job(with: jobID) }

    var body: some View {
        Group {
            if let job = job {
                content(job)
            } else {
                EmptyStateView(symbol: "tray",
                               title: L10n.t("upload.missing.title"),
                               message: L10n.t("upload.missing.message"))
            }
        }
        .navigationTitle(job?.displayName ?? L10n.t("upload.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ job: UploadJob) -> some View {
        List {
            Section(L10n.t("upload.detail.summary")) {
                ProgressBar(fraction: job.fractionCompleted,
                            caption: L10n.t(job.state.titleKey))
                DetailRow(title: L10n.t("upload.detail.repository"), value: job.repo.fullName)
                DetailRow(title: L10n.t("upload.detail.branch"), value: job.branch)
                DetailRow(title: L10n.t("upload.detail.destination"),
                          value: job.remoteRoot.isEmpty ? "/" : "/" + job.remoteRoot,
                          monospaced: true)
                DetailRow(title: L10n.t("upload.detail.files"), value: "\(job.settledFiles)/\(job.totalFiles)")
                DetailRow(title: L10n.t("upload.detail.skipped"), value: "\(job.skippedFiles)")
                DetailRow(title: L10n.t("upload.detail.size"), value: Formatters.size(job.totalBytes))
                DetailRow(title: L10n.t("upload.detail.transferred"),
                          value: Formatters.size(job.transferredBytes))
                if let speed = job.bytesPerSecond {
                    DetailRow(title: L10n.t("upload.detail.speed"),
                              value: Formatters.speed(speed))
                }
                if let remaining = job.estimatedSecondsRemaining {
                    DetailRow(title: L10n.t("upload.detail.remaining"),
                              value: Formatters.duration(remaining))
                }
                if job.conflictCount > 0 {
                    DetailRow(title: L10n.t("conflict.policy"),
                              value: L10n.t(job.conflictPolicy.titleKey))
                }
                if let commit = job.resultCommitSHA {
                    DetailRow(title: L10n.t("upload.detail.commit"),
                              value: String(commit.prefix(10)),
                              monospaced: true)
                }
                if let error = job.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                controls(job)
            }

            Section {
                Picker(L10n.t("upload.filter"), selection: $filter) {
                    ForEach(FileFilter.allCases) { option in
                        Text(L10n.t(option.titleKey)).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                ForEach(filteredFiles(job).prefix(500)) { file in
                    fileRow(file)
                }
            } header: {
                Text(L10n.t("upload.detail.files"))
            } footer: {
                if filteredFiles(job).count > 500 {
                    Text(L10n.format("upload.detail.truncated", filteredFiles(job).count))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func controls(_ job: UploadJob) -> some View {
        if job.state.isResumable {
            Button {
                uploads.resume(job.id)
            } label: {
                Label(L10n.t("upload.resume"), systemImage: "play.fill")
            }
        } else if job.state.isActive {
            Button {
                uploads.pause(job.id)
            } label: {
                Label(L10n.t("upload.pause"), systemImage: "pause.fill")
            }
        }

        if !job.state.isTerminal {
            Button(role: .destructive) {
                uploads.cancel(job.id)
            } label: {
                Label(L10n.t("common.cancel"), systemImage: "xmark.circle")
            }
        }

        Button(role: .destructive) {
            uploads.remove(job.id)
            dismiss()
        } label: {
            Label(L10n.t("upload.remove"), systemImage: "trash")
        }
    }

    private func fileRow(_ file: UploadFileItem) -> some View {
        HStack(spacing: Design.spacing) {
            Image(systemName: symbol(for: file.state))
                .foregroundStyle(color(for: file.state))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.relativePath)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(Formatters.size(file.size))
                    if file.state == .uploading && file.size > 0 {
                        Text(Formatters.size(file.bytesSent))
                    }
                    if file.renamedRelativePath != nil {
                        Label(L10n.t("conflict.renamed"), systemImage: "character.cursor.ibeam")
                    }
                    if let error = file.errorMessage {
                        Text(error).foregroundStyle(.red).lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                // Per-file progress, driven by the bytes URLSession reports.
                if file.state == .uploading {
                    ProgressView(value: file.fractionCompleted)
                        .tint(Color.brand)
                }
            }
        }
    }

    private func filteredFiles(_ job: UploadJob) -> [UploadFileItem] {
        switch filter {
        case .all: return job.files
        case .pending: return job.files.filter { $0.state == .pending || $0.state == .uploading }
        case .uploaded: return job.files.filter { $0.state == .uploaded }
        case .skipped: return job.files.filter { $0.state == .skipped }
        case .failed: return job.files.filter { $0.state == .failed }
        }
    }

    private func symbol(for state: UploadFileItem.State) -> String {
        switch state {
        case .pending: return "circle"
        case .uploading: return "arrow.up.circle"
        case .uploaded: return "checkmark.circle.fill"
        case .skipped: return "equal.circle"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private func color(for state: UploadFileItem.State) -> Color {
        switch state {
        case .pending: return .secondary
        case .uploading: return .brand
        case .uploaded: return .green
        case .skipped: return .blue
        case .failed: return .red
        }
    }
}
