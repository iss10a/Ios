//
//  HTTPClient.swift
//  GitFolderUploader
//
//  Thin async wrapper around URLSession with GitHub-aware error mapping,
//  automatic retry/backoff, rate-limit accounting and Link pagination.
//

import Foundation

/// Snapshot of the `X-RateLimit-*` headers returned by GitHub.
struct RateLimitSnapshot: Equatable {
    var limit: Int = 0
    var remaining: Int = 0
    var resetDate: Date = .distantPast

    var isCritical: Bool { limit > 0 && remaining <= 20 }
}

/// A response body plus the metadata callers need for pagination.
struct APIResponse<Value> {
    let value: Value
    let linkHeader: String?
    let etag: String?
    let statusCode: Int

    var nextPage: Int? { LinkHeaderParser.nextPage(from: linkHeader) }
}

/// Reports how much of a request body has reached the network, so the UI can
/// draw a real per-file progress bar instead of a spinner.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {

    private let onProgress: (Int64, Int64) -> Void

    init(onProgress: @escaping (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}

/// Executes `Endpoint` values. One shared instance lives in `AppEnvironment`.
final class HTTPClient {

    private let session: URLSession
    private let tokenProvider: () -> String?
    private let decoder: JSONDecoder
    private let maxRetries: Int

    /// Latest observed rate limit; updated on every response.
    private(set) var rateLimit = RateLimitSnapshot()

    private let rateLimitLock = NSLock()

    init(tokenProvider: @escaping () -> String?,
         session: URLSession? = nil,
         maxRetries: Int = 4) {
        self.tokenProvider = tokenProvider
        self.maxRetries = maxRetries

        if let session = session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Public API

    /// Sends a request and decodes the JSON body into `T`.
    func send<T: Decodable>(_ endpoint: Endpoint, as type: T.Type = T.self) async throws -> T {
        try await sendWithMetadata(endpoint, as: type).value
    }

    /// Sends a request and returns the decoded body together with response metadata.
    func sendWithMetadata<T: Decodable>(_ endpoint: Endpoint,
                                        as type: T.Type = T.self) async throws -> APIResponse<T> {
        let raw = try await sendRaw(endpoint)
        do {
            let value = try decoder.decode(T.self, from: raw.value)
            return APIResponse(value: value,
                               linkHeader: raw.linkHeader,
                               etag: raw.etag,
                               statusCode: raw.statusCode)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Sends a request that carries a body, reporting how much of it has been
    /// written. Used by blob uploads so each file gets its own progress bar.
    ///
    /// - Parameter onProgress: Receives a 0...1 fraction. Called on a URLSession
    ///   delegate queue, so hop to the main actor before touching UI state.
    func sendUploading<T: Decodable>(_ endpoint: Endpoint,
                                     as type: T.Type = T.self,
                                     onProgress: ((Double) -> Void)?) async throws -> T {
        let raw = try await sendRaw(endpoint, onProgress: onProgress)
        do {
            return try decoder.decode(T.self, from: raw.value)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Sends a request whose response body is ignored.
    @discardableResult
    func sendIgnoringBody(_ endpoint: Endpoint) async throws -> Int {
        try await sendRaw(endpoint).statusCode
    }

    /// Walks every page of a collection endpoint until exhaustion or `pageLimit`.
    func sendAllPages<T: Decodable>(_ endpoint: Endpoint,
                                    perPage: Int = 100,
                                    pageLimit: Int = 50) async throws -> [T] {
        var aggregate: [T] = []
        var page = 1
        var endpoint = endpoint

        while page <= pageLimit {
            endpoint.query["per_page"] = String(perPage)
            endpoint.query["page"] = String(page)
            let response: APIResponse<[T]> = try await sendWithMetadata(endpoint)
            aggregate.append(contentsOf: response.value)
            guard let next = response.nextPage, !response.value.isEmpty else { break }
            page = next
        }
        return aggregate
    }

    /// Performs the request, applying retry/backoff, and returns the raw body.
    func sendRaw(_ endpoint: Endpoint,
                 onProgress: ((Double) -> Void)? = nil) async throws -> APIResponse<Data> {
        var attempt = 0
        var lastError: Error = APIError.invalidResponse

        while attempt <= maxRetries {
            if Task.isCancelled { throw APIError.cancelled }
            do {
                return try await performOnce(endpoint, onProgress: onProgress)
            } catch let error as APIError {
                lastError = error
                guard error.isRetryable, attempt < maxRetries else { throw error }

                let delay: TimeInterval
                if case .rateLimited(let retryAfter) = error {
                    delay = min(max(retryAfter, 1), 90)
                } else {
                    delay = Self.backoffDelay(attempt: attempt)
                }
                AppLog.network.debug("Retrying \(endpoint.path) in \(delay)s (attempt \(attempt + 1))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            } catch is CancellationError {
                throw APIError.cancelled
            } catch {
                throw APIError.transport(error.localizedDescription)
            }
        }
        throw lastError
    }

    /// Downloads arbitrary binary content from an absolute URL (raw blobs, avatars…).
    func download(from url: URL, authenticated: Bool = true) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        if authenticated, let token = tokenProvider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.mapFailure(status: http.statusCode, data: data, response: http)
            }
            return data
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func performOnce(_ endpoint: Endpoint,
                             onProgress: ((Double) -> Void)? = nil) async throws -> APIResponse<Data> {
        let request = try endpoint.urlRequest(token: tokenProvider())
        let data: Data
        let response: URLResponse
        do {
            if let onProgress = onProgress, let body = request.httpBody, !body.isEmpty {
                // `upload(for:from:)` is the only variant that reports how much
                // of the body has been written, so the body moves out of the
                // request and into the call.
                var stripped = request
                stripped.httpBody = nil
                let delegate = UploadProgressDelegate { sent, expected in
                    guard expected > 0 else { return }
                    onProgress(min(1, Double(sent) / Double(expected)))
                }
                (data, response) = try await session.upload(for: stripped,
                                                            from: body,
                                                            delegate: delegate)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch let error as URLError where error.code == .cancelled {
            throw APIError.cancelled
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        updateRateLimit(from: http)

        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapFailure(status: http.statusCode, data: data, response: http)
        }

        return APIResponse(value: data,
                           linkHeader: http.value(forHTTPHeaderField: "Link"),
                           etag: http.value(forHTTPHeaderField: "ETag"),
                           statusCode: http.statusCode)
    }

    private func updateRateLimit(from response: HTTPURLResponse) {
        rateLimitLock.lock()
        defer { rateLimitLock.unlock() }

        if let limit = Int(response.value(forHTTPHeaderField: "x-ratelimit-limit") ?? "") {
            rateLimit.limit = limit
        }
        if let remaining = Int(response.value(forHTTPHeaderField: "x-ratelimit-remaining") ?? "") {
            rateLimit.remaining = remaining
        }
        if let reset = Double(response.value(forHTTPHeaderField: "x-ratelimit-reset") ?? "") {
            rateLimit.resetDate = Date(timeIntervalSince1970: reset)
        }
    }

    private static func backoffDelay(attempt: Int) -> TimeInterval {
        let base = pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...0.5)
        return min(base + jitter, 30)
    }

    /// Translates a non-2xx response into a typed `APIError`.
    static func mapFailure(status: Int, data: Data, response: HTTPURLResponse) -> APIError {
        let message = extractMessage(from: data)

        switch status {
        case 401:
            return .unauthorized
        case 403, 429:
            let remaining = Int(response.value(forHTTPHeaderField: "x-ratelimit-remaining") ?? "")
            if let retryAfter = Double(response.value(forHTTPHeaderField: "retry-after") ?? "") {
                return .rateLimited(retryAfter: retryAfter)
            }
            if remaining == 0, let reset = Double(response.value(forHTTPHeaderField: "x-ratelimit-reset") ?? "") {
                let wait = max(Date(timeIntervalSince1970: reset).timeIntervalSinceNow, 1)
                return .rateLimited(retryAfter: wait)
            }
            return .forbidden(message)
        case 404:
            return .notFound
        case 409:
            return .conflict(message)
        case 422:
            return .validationFailed(message)
        default:
            return .server(status: status, message: message)
        }
    }

    /// Pulls the human readable text out of GitHub's error envelope.
    private static func extractMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        var message = object["message"] as? String ?? ""
        if let errors = object["errors"] as? [[String: Any]] {
            let details = errors.compactMap { entry -> String? in
                if let value = entry["message"] as? String { return value }
                if let field = entry["field"] as? String, let code = entry["code"] as? String {
                    return "\(field): \(code)"
                }
                return nil
            }
            if !details.isEmpty {
                message += " — " + details.joined(separator: ", ")
            }
        }
        return message
    }
}
