//
//  AppEnvironment.swift
//  GitFolderUploader
//
//  Composition root. Every concrete implementation is wired here exactly once;
//  view models depend on protocols and receive them through initialisers, with
//  the shared environment as the default so previews stay one line long.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class AppEnvironment: ObservableObject {

    static let shared = AppEnvironment()

    // MARK: - Infrastructure

    let keychain: KeychainStore
    let httpClient: HTTPClient
    let jobStore: UploadJobStore

    // MARK: - Services

    let auth: AuthRepositoryProtocol
    let repositories: RepositoryServiceProtocol
    let contents: ContentServiceProtocol
    let gitData: GitDataServiceProtocol
    let search: GitHubSearchService

    // MARK: - Session

    @Published private(set) var currentUser: GitHubUser?
    @Published private(set) var isRestoringSession = true

    /// Live upload queue, shared by every screen.
    let uploads: UploadManager

    var isAuthenticated: Bool { currentUser != nil }

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    private init() {
        let keychain = KeychainStore()
        self.keychain = keychain

        // The client reads the token lazily so a fresh sign-in takes effect
        // immediately without rebuilding the object graph.
        var authBox: GitHubAuthRepository?
        let client = HTTPClient(tokenProvider: { authBox?.storedToken })
        self.httpClient = client

        let authRepository = GitHubAuthRepository(client: client, keychain: keychain)
        authBox = authRepository
        self.auth = authRepository

        let gitData = GitHubGitDataService(client: client)
        self.gitData = gitData
        self.repositories = GitHubRepositoryService(client: client)
        self.contents = GitHubContentService(client: client)
        self.search = GitHubSearchService(client: client, gitData: gitData)

        let store = UploadJobStore()
        self.jobStore = store
        self.uploads = UploadManager(gitData: gitData, store: store)

        // Re-publish queue changes so screens observing the environment (tab
        // badges, summary rows) refresh without observing the manager directly.
        uploads.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Session lifecycle

    /// Restores a previous session on launch.
    func restoreSession() async {
        defer { isRestoringSession = false }
        guard auth.storedToken?.isEmpty == false else {
            currentUser = nil
            return
        }
        currentUser = try? await auth.currentUser()
    }

    func setSignedIn(user: GitHubUser) {
        currentUser = user
        isRestoringSession = false
        uploads.reload()
    }

    func signOut() {
        uploads.cancelAll()
        auth.signOut()
        currentUser = nil
    }

    // MARK: - Use case factories

    var signInWithToken: SignInWithTokenUseCase { SignInWithTokenUseCase(repository: auth) }
    var deviceFlow: DeviceFlowUseCase { DeviceFlowUseCase(repository: auth) }
    var listRepositories: ListRepositoriesUseCase { ListRepositoriesUseCase(service: repositories) }
    var searchRepositories: SearchRepositoriesUseCase { SearchRepositoriesUseCase(service: repositories) }
    var createRepository: CreateRepositoryUseCase { CreateRepositoryUseCase(service: repositories) }
    var browseContents: BrowseContentsUseCase { BrowseContentsUseCase(service: contents) }
    var readFile: ReadFileUseCase { ReadFileUseCase(service: contents) }
    var createFolder: CreateFolderUseCase { CreateFolderUseCase(service: contents) }
    var renameEntry: RenameEntryUseCase { RenameEntryUseCase(gitData: gitData) }
    var deleteEntry: DeleteEntryUseCase { DeleteEntryUseCase(gitData: gitData) }
    var listBranches: ListBranchesUseCase { ListBranchesUseCase(service: gitData) }
    var createBranch: CreateBranchUseCase { CreateBranchUseCase(service: gitData) }
    var searchFiles: SearchFilesUseCase { SearchFilesUseCase(service: search) }
    var searchCode: SearchCodeUseCase { SearchCodeUseCase(service: search) }
    var downloadFolder: DownloadFolderUseCase { DownloadFolderUseCase(gitData: gitData) }

    /// Current API budget, surfaced in Settings.
    var rateLimit: RateLimitSnapshot { httpClient.rateLimit }
}
