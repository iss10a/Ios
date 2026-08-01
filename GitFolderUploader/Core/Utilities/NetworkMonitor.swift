//
//  NetworkMonitor.swift
//  GitFolderUploader
//
//  Watches connectivity so an upload interrupted by a dropped connection
//  restarts on its own once the network is back, without the user having to
//  reopen the app and tap resume.
//

import Combine
import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {

    static let shared = NetworkMonitor()

    /// `true` while a usable route exists. Starts optimistic so nothing is
    /// blocked during the first fraction of a second before the first update.
    @Published private(set) var isOnline = true
    /// `true` when the current route is metered, shown in the queue screen.
    @Published private(set) var isExpensive = false

    /// Fires every time connectivity is regained after being lost.
    let didComeOnline = PassthroughSubject<Void, Never>()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.gitfolderuploader.network-monitor")
    private var isStarted = false

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true

        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor in
                self?.apply(online: online, expensive: expensive)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard isStarted else { return }
        monitor.cancel()
        isStarted = false
    }

    private func apply(online: Bool, expensive: Bool) {
        isExpensive = expensive
        guard online != isOnline else { return }
        isOnline = online
        if online {
            AppLog.network.info("Connectivity restored")
            didComeOnline.send()
        } else {
            AppLog.network.info("Connectivity lost")
        }
    }
}
