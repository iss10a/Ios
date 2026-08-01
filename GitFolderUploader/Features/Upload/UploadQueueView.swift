//
//  UploadQueueView.swift
//  GitFolderUploader
//
//  The upload queue: live progress, pause / resume / cancel, and history.
//

import SwiftUI

struct UploadQueueView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var uploads: UploadManager

    init(uploads: UploadManager? = nil) {
        _uploads = ObservedObject(wrappedValue: uploads ?? AppEnvironment.shared.uploads)
    }

    var body: some View {
        List {
            if uploads.isOffline && uploads.hasResumableWork {
                Section {
                    Label(L10n.t("upload.offline"), systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if !uploads.activeJobs.isEmpty {
                Section(L10n.t("upload.section.active")) {
                    ForEach(uploads.activeJobs) { job in
                        NavigationLink {
                            UploadJobDetailView(jobID: job.id)
                        } label: {
                            UploadJobRow(job: job, isRunning: uploads.runningJobID == job.id)
                        }
                        .id(job.id)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                uploads.cancel(job.id)
                            } label: {
                                Label(L10n.t("common.cancel"), systemImage: "xmark")
                            }
                            if job.state.isResumable {
                                Button { uploads.resume(job.id) } label: {
                                    Label(L10n.t("upload.resume"), systemImage: "play.fill")
                                }
                                .tint(.green)
                            } else {
                                Button { uploads.pause(job.id) } label: {
                                    Label(L10n.t("upload.pause"), systemImage: "pause.fill")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }

            if !uploads.finishedJobs.isEmpty {
                Section(L10n.t("upload.section.finished")) {
                    ForEach(uploads.finishedJobs) { job in
                        NavigationLink {
                            UploadJobDetailView(jobID: job.id)
                        } label: {
                            UploadJobRow(job: job, isRunning: false)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                uploads.remove(job.id)
                            } label: {
                                Label(L10n.t("common.delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("upload.title"))
        .overlay {
            if uploads.jobs.isEmpty {
                EmptyStateView(symbol: "tray",
                               title: L10n.t("upload.empty.title"),
                               message: L10n.t("upload.empty.message"))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        uploads.resumeAll()
                    } label: {
                        Label(L10n.t("upload.resume_all"), systemImage: "play.circle")
                    }
                    .disabled(!uploads.hasResumableWork)

                    Button(role: .destructive) {
                        uploads.clearFinished()
                    } label: {
                        Label(L10n.t("upload.clear_finished"), systemImage: "trash")
                    }
                    .disabled(uploads.finishedJobs.isEmpty)
                } label: {
                    Label(L10n.t("common.actions"), systemImage: "ellipsis.circle")
                }
            }
        }
    }
}

/// One row of the queue.
struct UploadJobRow: View {

    let job: UploadJob
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Design.tightSpacing) {
            HStack(spacing: Design.tightSpacing) {
                Image(systemName: job.state.symbol)
                    .foregroundStyle(tint)
                Text(job.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isRunning {
                    ProgressView().controlSize(.small)
                }
            }

            Text(job.repo.fullName + " · " + job.branch)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !job.state.isTerminal {
                ProgressBar(fraction: job.fractionCompleted,
                            caption: caption,
                            tint: tint)
            } else {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var caption: String {
        var parts: [String] = [L10n.t(job.state.titleKey)]
        if job.totalFiles > 0 {
            parts.append("\(job.settledFiles)/\(job.totalFiles)")
            if job.skippedFiles > 0 {
                parts.append(L10n.format("upload.skipped", job.skippedFiles))
            }
        }
        if isRunning {
            if let speed = job.bytesPerSecond {
                parts.append(Formatters.speed(speed))
            }
            if let remaining = job.estimatedSecondsRemaining {
                parts.append(L10n.format("upload.eta", Formatters.duration(remaining)))
            }
        }
        return parts.joined(separator: " · ")
    }

    private var tint: Color {
        switch job.state {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .paused: return .orange
        default: return .brand
        }
    }
}
