//
//  UploadJobStore.swift
//  GitFolderUploader
//
//  Durable queue storage. Jobs are written to Application Support after every
//  state change, which is what allows an interrupted upload to be resumed after
//  a crash, a force quit or a background suspension.
//

import Foundation

final class UploadJobStore: UploadJobStoreProtocol {

    private let directory: URL
    private let queue = DispatchQueue(label: "com.gitfolderuploader.jobstore", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directoryName: String = "UploadJobs") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = base.appendingPathComponent(directoryName, isDirectory: true)

        encoder.outputFormatting = [.withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup()
    }

    // MARK: - UploadJobStoreProtocol

    func loadAll() -> [UploadJob] {
        queue.sync { () -> [UploadJob] in
            guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                          includingPropertiesForKeys: nil) else {
                return []
            }
            var jobs: [UploadJob] = []
            for url in urls where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url) else { continue }
                if let job = try? decoder.decode(UploadJob.self, from: data) {
                    jobs.append(job)
                } else {
                    // A corrupt record must never block the queue.
                    AppLog.storage.error("Dropping unreadable job file \(url.lastPathComponent)")
                    try? FileManager.default.removeItem(at: url)
                }
            }
            return jobs.sorted { $0.createdAt < $1.createdAt }
        }
    }

    func save(_ jobs: [UploadJob]) {
        for job in jobs { save(job) }
    }

    func save(_ job: UploadJob) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let data = try self.encoder.encode(job)
                try data.write(to: self.url(for: job.id), options: .atomic)
            } catch {
                AppLog.storage.error("Failed to persist job: \(error.localizedDescription)")
            }
        }
    }

    func delete(id: UUID) {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.url(for: id))
        }
    }

    // MARK: - Private

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    /// Job metadata is reproducible state — keep it out of iCloud backups.
    private func excludeFromBackup() {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
