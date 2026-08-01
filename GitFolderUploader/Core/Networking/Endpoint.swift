//
//  Endpoint.swift
//  GitFolderUploader
//
//  Transport-agnostic description of a single HTTP call.
//

import Foundation

/// HTTP verbs used by the GitHub REST API.
enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case put = "PUT"
    case delete = "DELETE"
}

/// A value type describing one request. Endpoints are built by the Data layer
/// (see `GitHubEndpoints`) and executed by `HTTPClient`.
struct Endpoint {

    /// Base URL. Defaults to the public GitHub REST API host.
    var baseURL: URL = GitHubHost.api

    /// Path component, always beginning with `/`.
    var path: String

    var method: HTTPMethod = .get

    /// Query items appended to the URL.
    var query: [String: String] = [:]

    /// Raw HTTP body (already encoded).
    var body: Data?

    /// Additional headers merged on top of the client defaults.
    var headers: [String: String] = [:]

    /// Value of the `Accept` header.
    var accept: String = "application/vnd.github+json"

    /// When `false` the request is sent without an `Authorization` header.
    var requiresAuthentication: Bool = true

    /// Builds a `URLRequest`, injecting the token when required.
    func urlRequest(token: String?) throws -> URLRequest {
        let composed = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: composed, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(composed.absoluteString)
        }
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw APIError.invalidURL(composed.absoluteString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if requiresAuthentication, let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    /// Convenience factory that JSON-encodes a dictionary body.
    static func json(path: String,
                     method: HTTPMethod,
                     payload: [String: Any],
                     query: [String: String] = [:]) throws -> Endpoint {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return Endpoint(path: path, method: method, query: query, body: data)
    }
}

/// Well-known GitHub hosts.
enum GitHubHost {
    static let api = URL(string: "https://api.github.com")!
    static let web = URL(string: "https://github.com")!
}

/// Static application metadata used in headers and UI.
enum AppInfo {
    static let name = "GitFolderUploader"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
    static var userAgent: String { "\(name)/\(version) (iOS)" }
}
