//
//  UploadManager.swift
//  GitFolderUploader
//
//  Owns the upload queue: persistence, scheduling, background continuation and
//  the observable state the UI renders.
//
//  Concurrency model
//  -----------------
//  One job runs at a time (each job already parallelises its own blob uploads),
//  additional jobs wait in the queue. Every mutation is hopped to the main actor
//  so SwiftUI updates are always safe, and mirrored to disk so the queue
//  survives termination.
//

import Combine
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

@MainActor
final class UploadManager: ObservableObject {

    /// Identifier registered in Info.plist under `BGTaskSchedulerPermittedIdentifiers`.
    static let backgroundTaskIdentifier = "com.gitfolderuploader.resume"

    @Published private(set) var jobs: [UploadJob] = []
    /// Job currently being executed, if any.
    @Published private(set) var runningJobID: UUID?

    private let gitData: GitDataServiceProtocol
    private let store: UploadJobStoreProtocol
    private var runner: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// Jobs paused because the connection dropped; they restart on their own.
    private var pausedByNetwork: Set<UUID> = []

    /// Mirrors the reachability monitor so the queue screen can explain why
    /// nothing is moving.
    @Published private(set) var isOffline = false

    #if canImport(UIKit)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(gitData: GitDataServiceProtocol, store: UploadJobStoreProtocol) {
        self.gitData = gitData
        self.store = store
        self.jobs = store.loadAll()
        normalizeStatesAfterLaunch()
        observeConnectivity()
    }

    // MARK: - Connectivity

    /// Pauses on the way down and resumes on the way back up, so a dropped
    /// connection never needs a manual retry.
    private func observeConnectivity() {
        let monitor = NetworkMonitor.shared
        monitor.start()
        isOffline = !monitor.isOnline

        monitor.$isOnline
            .removeDuplicates()
            .sink { [weak self] online in
                guard let self = self else { return }
                self.isOffline = !online
                if online {
                    self.resumeAfterReconnect()
                } else {
                    self.pauseForConnectionLoss()
                }
            }
            .store(in: &cancellables)
    }

    private func pauseForConnectionLoss() {
        guard let running = runningJobID else { return }
        AppLog.upload.info("Connection lost; pausing the running job")
        pausedByNetwork.insert(running)
        runner?.cancel()
    }

    private func resumeAfterReconnect() {
        guard !pausedByNetwork.isEmpty || hasResumableWork else { return }
        AppLog.upload.info("Connection restored; resuming uploads")
        for id in pausedByNetwork { resume(id) }
        pausedByNetwork.removeAll()
        startNextIfIdle()
    }

    // MARK: - Derived state

    var activeJobs: [UploadJob] { jobs.filter { !$0.state.isTerminal } }
    var finishedJobs: [UploadJob] { jobs.filter { $0.state.isTerminal } }
    var hasResumableWork: Bool { jobs.contains { $0.state.isResumable } }

    /// Combined transfer rate of whatever is running, for the queue header.
    var currentBytesPerSecond: Double? {
        guard let id = runningJobID, let job = job(with: id) else { return nil }
        return job.bytesPerSecond
    }

    /// Seconds until the running job finishes.
    var currentSecondsRemaining: TimeInterval? {
        guard let id = runningJobID, let job = job(with: id) else { return nil }
        return job.estimatedSecondsRemaining
    }

    /// Aggregate progress across everything still in flight, for the tab badge.
    var overallProgress: Double {
        let pending = activeJobs
        guard !pending.isEmpty else { return 0 }
        return pending.reduce(0.0) { $0 + $1.fractionCompleted } / Double(pending.count)
    }

    // MARK: - Queue management

    /// Reloads from disk (used after sign-in).
    func reload() {
        jobs = store.loadAll()
        normalizeStatesAfterLaunch()
    }

    /// Adds a job and starts the queue.
    func enqueue(_ job: UploadJob) {
        jobs.append(job)
        store.save(job)
        startNextIfIdle()
    }

    /// Marks a paused/failed job as ready and restarts the queue.
    func resume(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state.isResumable else { return }
        jobs[index].state = .queued
        jobs[index].lastError = nil
        store.save(jobs[index])
        startNextIfIdle()
    }

    func resumeAll() {
        for job in jobs where job.state.isResumable {
            resume(job.id)
        }
    }

    /// Stops the running job; its progress is kept so it can be resumed.
    func pause(_ id: UUID) {
        // An explicit pause outranks the automatic one.
        pausedByNetwork.remove(id)
        if runningJobID == id {
            runner?.cancel()
        } else if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].state = .paused
            store.save(jobs[index])
        }
    }

    func cancel(_ id: UUID) {
        pausedByNetwork.remove(id)
        if runningJobID == id { runner?.cancel() }
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .cancelled
        store.save(jobs[index])
    }

    func cancelAll() {
        pausedByNetwork.removeAll()
        runner?.cancel()
        for index in jobs.indices where !jobs[index].state.isTerminal {
            jobs[index].state = .cancelled
            store.save(jobs[index])
        }
    }

    func remove(_ id: UUID) {
        if runningJobID == id { runner?.cancel() }
        pausedByNetwork.remove(id)
        if let job = job(with: id) {
            SourceCapture.discardImports(for: job.sources)
        }
        jobs.removeAll { $0.id == id }
        store.delete(id: id)
    }

    func clearFinished() {
        for job in finishedJobs {
            SourceCapture.discardImports(for: job.sources)
            store.delete(id: job.id)
        }
        jobs.removeAll { $0.state.isTerminal }
    }

    func job(with id: UUID) -> UploadJob? {
        jobs.first { $0.id == id }
    }

    // MARK: - Execution

    /// Starts the next queued job when nothing is running.
    func startNextIfIdle() {
        guard runner == nil else { return }
        guard let index = jobs.firstIndex(where: { $0.state == .queued }) else {
            endBackgroundTask()
            return
        }

        let job = jobs[index]
        runningJobID = job.id
        beginBackgroundTask()

        let useCase = UploadFolderUseCase(gitData: gitData)

        // `Task` inherits the main actor from this method, so every statement
        // after an `await` is already back on the main thread.
        runner = Task { [weak self] in
            let finished = await useCase.execute(job: job) { updated in
                Task { @MainActor in
                    self?.apply(updated)
                }
            }
            self?.apply(finished)
            self?.runner = nil
            self?.runningJobID = nil
            self?.startNextIfIdle()
        }
    }

    /// Writes an updated job value into the published array and to disk.
    private func apply(_ job: UploadJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            // A cancel issued while the engine was running wins.
            if jobs[index].state == .cancelled { return }
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        store.save(job)
    }

    /// Anything that claims to be running after a cold launch was interrupted.
    private func normalizeStatesAfterLaunch() {
        for index in jobs.indices where jobs[index].state.isActive {
            jobs[index].state = .paused
            store.save(jobs[index])
        }
    }

    // MARK: - Background execution

    /// Keeps the current job alive for the extra wall-clock time iOS grants
    /// after the app leaves the foreground.
    private func beginBackgroundTask() {
        #if canImport(UIKit)
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "FolderUpload") { [weak self] in
            Task { @MainActor in self?.pauseForBackgroundExpiry() }
        }
        #endif
    }

    private func endBackgroundTask() {
        #if canImport(UIKit)
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        #endif
    }

    /// Called when the extra background time runs out: pause cleanly and ask the
    /// scheduler to wake us up again later.
    func pauseForBackgroundExpiry() {
        AppLog.upload.info("Background time expired; pausing queue")
        runner?.cancel()
        endBackgroundTask()
        scheduleBackgroundResume()
    }

    /// Requests a background processing slot so paused jobs continue on their own.
    func scheduleBackgroundResume() {
        #if canImport(BackgroundTasks)
        guard hasResumableWork else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.upload.error("Could not schedule background resume: \(error.localizedDescription)")
        }
        #endif
    }

    /// The app is about to be suspended: stop cleanly and schedule a retry.
    func applicationDidEnterBackground() {
        scheduleBackgroundResume()
    }

    /// The app came back: pick up whatever was interrupted.
    func applicationWillEnterForeground() {
        startNextIfIdle()
    }
}
