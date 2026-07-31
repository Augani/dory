import AppKit
import FileProvider
import Foundation

enum DoryFinderStorageLocationError: LocalizedError {
    case sharedContainerUnavailable
    case providerUnavailable
    case visibleURLUnavailable

    var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable:
            "Dory's shared storage inventory container is unavailable."
        case .providerUnavailable:
            "Dory's Finder storage provider is unavailable."
        case .visibleURLUnavailable:
            "Finder did not return a location for Dory storage."
        }
    }
}

@MainActor
final class DoryFinderStorageLocation {
    private var publishedIdentifiers: Set<String> = []
    private var retiredIdentifiers: Set<String> = []
    private var domainKnownAbsent = false

    private static var identifier: NSFileProviderDomainIdentifier {
        NSFileProviderDomainIdentifier(rawValue: DoryStorageInventoryContract.domainIdentifier)
    }

    private static func domain(hidden: Bool = false) -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(identifier: identifier, displayName: "Dory")
        domain.isHidden = hidden
        return domain
    }

    func publish(_ newSnapshot: DoryStorageInventorySnapshot) throws {
        guard let url = DoryStorageInventoryContract.snapshotURL() else {
            throw DoryFinderStorageLocationError.sharedContainerUnavailable
        }
        var snapshot = newSnapshot
        if publishedIdentifiers.isEmpty,
           let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            if let previous = try? decoder.decode(DoryStorageInventorySnapshot.self, from: data) {
                publishedIdentifiers = Set(previous.groups.flatMap { $0.entries.map(\.identifier) })
                retiredIdentifiers = Set(previous.removedIdentifiers)
            }
        }
        let identifiers = Set(snapshot.groups.flatMap { $0.entries.map(\.identifier) })
        retiredIdentifiers.formUnion(publishedIdentifiers.subtracting(identifiers))
        retiredIdentifiers.subtract(identifiers)
        publishedIdentifiers = identifiers
        snapshot.removedIdentifiers = retiredIdentifiers.sorted()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    func show() async throws {
        let existing = (try await allDomains()).first { $0.identifier == Self.identifier }
        let needsMaterialization = existing == nil || existing?.isHidden == true
        let domain = Self.domain(hidden: needsMaterialization)
        // Adding an existing domain is intentionally idempotent. macOS uses this call to refresh
        // the display name and hidden state, which repairs domains retained across app upgrades or
        // a previous provider registration failure.
        try await add(domain)
        domainKnownAbsent = false
        try await signalInventoryChanged(domain: domain)
        if needsMaterialization {
            try await materializePublishedItems(domain: domain)
            try await add(Self.domain())
        }
    }

    func hide() async {
        guard !domainKnownAbsent else { return }
        let domain = Self.domain()
        guard let domains = try? await allDomains() else { return }
        guard domains.contains(where: { $0.identifier == domain.identifier }) else {
            domainKnownAbsent = true
            publishedIdentifiers = []
            retiredIdentifiers = []
            return
        }
        await withCheckedContinuation { continuation in
            NSFileProviderManager.remove(domain) { _ in continuation.resume() }
        }
        domainKnownAbsent = true
        publishedIdentifiers = []
        retiredIdentifiers = []
    }

    func openInFinder() async throws {
        try await show()
        guard let manager = NSFileProviderManager(for: Self.domain()) else {
            throw DoryFinderStorageLocationError.providerUnavailable
        }
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            manager.getUserVisibleURL(for: .rootContainer) { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: DoryFinderStorageLocationError.visibleURLUnavailable) }
            }
        }
        NSWorkspace.shared.open(url)
    }

    private func allDomains() async throws -> [NSFileProviderDomain] {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: domains) }
            }
        }
    }

    private func add(_ domain: NSFileProviderDomain) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.add(domain) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    /// A replicated provider starts with dataless placeholders. Keep a newly registered domain
    /// hidden until every tiny inventory document has been fetched, then reveal it as a normal
    /// local Finder location without transient cloud badges.
    private func materializePublishedItems(domain: NSFileProviderDomain) async throws {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw DoryFinderStorageLocationError.providerUnavailable
        }
        let rawIdentifiers = publishedIdentifiers
            .union([DoryStorageInventoryContract.summaryIdentifier])
            .sorted()
        var pending = rawIdentifiers.map(NSFileProviderItemIdentifier.init(rawValue:))

        for _ in 0..<30 where !pending.isEmpty {
            var retry: [NSFileProviderItemIdentifier] = []
            for identifier in pending {
                let accepted = await requestDownload(identifier, manager: manager)
                guard accepted else {
                    retry.append(identifier)
                    continue
                }
                do {
                    let url = try await visibleURL(identifier, manager: manager)
                    try await readMaterializedFile(url)
                } catch {
                    retry.append(identifier)
                }
            }
            pending = retry
            if !pending.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard pending.isEmpty else {
            throw DoryFinderStorageLocationError.providerUnavailable
        }
    }

    private func requestDownload(
        _ identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            manager.requestDownloadForItem(
                withIdentifier: identifier,
                requestedRange: NSRange(location: NSNotFound, length: 0)
            ) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private func visibleURL(
        _ identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            manager.getUserVisibleURL(for: identifier) { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: DoryFinderStorageLocationError.visibleURLUnavailable) }
            }
        }
    }

    nonisolated private func readMaterializedFile(_ url: URL) async throws {
        _ = try await Task.detached(priority: .utility) {
            try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
    }

    private func signalInventoryChanged(domain: NSFileProviderDomain) async throws {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw DoryFinderStorageLocationError.providerUnavailable
        }
        let identifiers: [NSFileProviderItemIdentifier] = [.rootContainer, .workingSet]
            + DoryStorageInventoryKind.allCases.map {
                NSFileProviderItemIdentifier(rawValue: $0.folderIdentifier)
            }
        for identifier in identifiers {
            await withCheckedContinuation { continuation in
                manager.signalEnumerator(for: identifier) { _ in continuation.resume() }
            }
        }
    }

    /// `applicationWillTerminate` has no async completion point. Wait briefly so Finder receives
    /// the domain removal before the host process exits.
    nonisolated static func removeBeforeExit(timeout: TimeInterval = 2) {
        let identifier = NSFileProviderDomainIdentifier(rawValue: DoryStorageInventoryContract.domainIdentifier)
        let domain = NSFileProviderDomain(identifier: identifier, displayName: "Dory")
        let completion = DispatchSemaphore(value: 0)
        NSFileProviderManager.remove(domain) { _ in completion.signal() }
        _ = completion.wait(timeout: .now() + timeout)
    }
}
