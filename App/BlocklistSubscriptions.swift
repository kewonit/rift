import Foundation
import Observation
import RiftControl

/// Keeps subscribed blocklists up to date: once a day while Rift runs, and
/// whenever the person asks. Only lists the person subscribed to are
/// downloaded, over HTTPS, with no cookies and nothing about the Mac.
@MainActor
@Observable
final class BlocklistSubscriptions {
    static let shared = BlocklistSubscriptions()
    private static let storageKey = "blocklistSubscriptions"

    private(set) var items: [UUID: BlocklistSubscription] = [:]
    private(set) var refreshing: Set<UUID> = []
    @ObservationIgnored private weak var controlPlane: ControlPlaneController?
    @ObservationIgnored private var loop: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([BlocklistSubscription].self, from: data) {
            items = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Starts the daily check. Safe to call more than once.
    func start(controlPlane: ControlPlaneController) {
        self.controlPlane = controlPlane
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDue()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    /// Downloads a list and adds it as a blocklist that stays up to date.
    func subscribe(address: String, name: String) async throws -> ConfigurationMutationResult {
        let url = try BlocklistSubscriptionAddress.validate(address)
        guard let controlPlane else { throw BlocklistSubscriptionError.invalidAddress }
        guard case .changed(let data, let tag, let modified) = try await BlocklistDownloader.fetch(url) else {
            throw BlocklistSubscriptionError.notAList
        }
        let id = UUID()
        let result = try await controlPlane.importBlocklist(data: data, name: name, sourceID: id)
        var item = BlocklistSubscription(id: id, url: url, lastCheckedAt: Date(), lastChangedAt: Date())
        item.entityTag = tag
        item.lastModified = modified
        items[id] = item
        save()
        return result
    }

    /// Checks one list now. Returns what happened, in a sentence.
    @discardableResult
    func refresh(_ id: UUID) async -> String {
        guard var item = items[id] else { return "This blocklist isn’t a subscription." }
        guard let controlPlane else { return "Rift isn’t ready to check blocklists yet." }
        guard !refreshing.contains(id) else { return "This blocklist is already being checked." }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        let now = Date()
        do {
            switch try await BlocklistDownloader.fetch(
                item.url, entityTag: item.entityTag, lastModified: item.lastModified
            ) {
            case .notModified:
                item.lastFailure = nil
                item.lastCheckedAt = now
                keep(item)
                return "The blocklist is up to date."
            case .changed(let data, let tag, let modified):
                let result = try await controlPlane.replaceBlocklist(id, data: data)
                item.lastFailure = nil
                item.lastCheckedAt = now
                item.entityTag = tag
                item.lastModified = modified
                if result != nil { item.lastChangedAt = now }
                keep(item)
                return result.map { $0.message } ?? "The blocklist is up to date."
            }
        } catch {
            item.lastFailure = Self.message(for: error)
            item.lastCheckedAt = now
            keep(item)
            return item.lastFailure ?? "The blocklist couldn’t be checked."
        }
    }

    /// Saves a check's result, unless the list was removed meanwhile.
    private func keep(_ item: BlocklistSubscription) {
        guard items[item.id] != nil else { return }
        items[item.id] = item
        save()
    }

    /// Stops updating a list, as when it's removed.
    func forget(_ id: UUID) {
        guard items.removeValue(forKey: id) != nil else { return }
        save()
    }

    func refreshDue() async {
        guard let controlPlane else { return }
        // A list removed elsewhere, such as by a restore, stops updating.
        let existing = Set((try? await controlPlane.blocklistSources())?.map(\.id) ?? Array(items.keys))
        for id in items.keys where !existing.contains(id) { forget(id) }
        let now = Date()
        for item in items.values where item.isDue(now: now) {
            await refresh(item.id)
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case BlocklistSubscriptionError.invalidAddress:
            "Enter the full web address of a list, starting with https://."
        case BlocklistSubscriptionError.insecureAddress:
            "Rift downloads lists only over HTTPS, so nobody on the network can change them. Use an address that starts with https://."
        case BlocklistSubscriptionError.credentialsInAddress:
            "Leave the user name and password out of the address."
        case BlocklistSubscriptionError.tooLarge:
            "The list is too large for Rift to use."
        case BlocklistSubscriptionError.server(let status):
            "The server answered with error \(status)."
        case BlocklistSubscriptionError.notAList:
            "The server didn’t send a list."
        case PolicyDefinitionError.duplicateName:
            "You already have a blocklist with that name. Choose another name."
        case is BlocklistParserError, is LSRulesFileError:
            "The download isn’t a list Rift can read."
        case let error as URLError where error.code == .notConnectedToInternet:
            "The Mac isn’t connected to the internet."
        case is URLError:
            "Rift couldn’t reach the server."
        default:
            "The list couldn’t be updated."
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(items.values)) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// Downloads a subscribed list without cookies, caches or identifiers.
enum BlocklistDownloader {
    enum Result: Sendable {
        case notModified
        case changed(Data, entityTag: String?, lastModified: String?)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpAdditionalHeaders = ["User-Agent": "Rift"]
        return URLSession(configuration: configuration, delegate: HTTPSOnlyRedirects(), delegateQueue: nil)
    }()

    static func fetch(_ url: URL, entityTag: String? = nil, lastModified: String? = nil) async throws -> Result {
        var request = URLRequest(url: url)
        if let entityTag { request.setValue(entityTag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.scheme?.lowercased() == "https" else {
            throw BlocklistSubscriptionError.insecureAddress
        }
        if http.statusCode == 304 { return .notModified }
        guard (200..<300).contains(http.statusCode) else { throw BlocklistSubscriptionError.server(http.statusCode) }
        if http.expectedContentLength > Int64(BlocklistParser.maximumBytes) { throw BlocklistSubscriptionError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > BlocklistParser.maximumBytes { throw BlocklistSubscriptionError.tooLarge }
        }
        guard !data.isEmpty else { throw BlocklistSubscriptionError.notAList }
        return .changed(
            data,
            entityTag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }
}

/// Refuses a redirect to plain HTTP.
private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }
}
