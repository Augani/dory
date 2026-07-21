import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do {
            let catalog = try StorageCatalog.load()
            guard let item = catalog.item(identifier) else {
                completionHandler(nil, StorageProviderError.noSuchItem(identifier))
                return progress
            }
            progress.completedUnitCount = 1
            completionHandler(item, nil)
        } catch {
            completionHandler(nil, StorageProviderError.available(error))
        }
        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do {
            let catalog = try StorageCatalog.load()
            guard let item = catalog.item(itemIdentifier), let contents = item.contents else {
                completionHandler(nil, nil, StorageProviderError.noSuchItem(itemIdentifier))
                return progress
            }
            guard let manager = NSFileProviderManager(for: domain) else {
                completionHandler(nil, nil, StorageProviderError.serverUnavailable)
                return progress
            }
            let directory = try manager.temporaryDirectoryURL()
            let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
            try Data(contents.utf8).write(to: url, options: .atomic)
            progress.completedUnitCount = 1
            completionHandler(url, item, nil)
        } catch {
            completionHandler(nil, nil, StorageProviderError.available(error))
        }
        return progress
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        completionHandler(nil, [], false, CocoaError(.fileWriteNoPermission))
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        completionHandler(nil, [], false, CocoaError(.fileWriteNoPermission))
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        completionHandler(CocoaError(.fileWriteNoPermission))
        return progress
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        let catalog = try StorageCatalog.load()
        guard containerItemIdentifier == .workingSet
                || catalog.item(containerItemIdentifier)?.isFolder == true else {
            throw StorageProviderError.noSuchItem(containerItemIdentifier)
        }
        return StorageEnumerator(containerIdentifier: containerItemIdentifier)
    }
}

private enum StorageProviderError {
    static let serverUnavailable = NSError(
        domain: NSFileProviderErrorDomain,
        code: -1004,
        userInfo: [NSLocalizedDescriptionKey: "Dory's engine is not running."]
    )

    static func noSuchItem(_ identifier: NSFileProviderItemIdentifier) -> NSError {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: -1005,
            userInfo: [NSFileProviderErrorNonExistentItemIdentifierKey: identifier]
        )
    }

    static func available(_ error: Error) -> Error {
        if (error as NSError).domain == NSFileProviderErrorDomain { return error }
        return serverUnavailable
    }
}

private final class StorageEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerIdentifier: NSFileProviderItemIdentifier

    init(containerIdentifier: NSFileProviderItemIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        do {
            let catalog = try StorageCatalog.load()
            let items = containerIdentifier == .workingSet
                ? catalog.allItems
                : catalog.children(of: containerIdentifier)
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
        } catch {
            observer.finishEnumeratingWithError(StorageProviderError.available(error))
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    ) {
        do {
            let catalog = try StorageCatalog.load()
            if syncAnchor != catalog.syncAnchor {
                observer.didUpdate(catalog.allItems)
                observer.didDeleteItems(withIdentifiers: catalog.removedIdentifiers)
            }
            observer.finishEnumeratingChanges(upTo: catalog.syncAnchor, moreComing: false)
        } catch {
            observer.finishEnumeratingWithError(StorageProviderError.available(error))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler((try? StorageCatalog.load())?.syncAnchor)
    }
}

private struct StorageCatalog {
    static let summaryIdentifier = NSFileProviderItemIdentifier(
        rawValue: DoryStorageInventoryContract.summaryIdentifier
    )

    let snapshot: DoryStorageInventorySnapshot
    let itemsByIdentifier: [NSFileProviderItemIdentifier: StorageItem]

    static func load() throws -> StorageCatalog {
        guard let url = DoryStorageInventoryContract.snapshotURL(),
              let data = try? Data(contentsOf: url) else {
            throw StorageProviderError.serverUnavailable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DoryStorageInventorySnapshot.self, from: data)
        guard snapshot.schemaVersion == DoryStorageInventorySnapshot.schemaVersion else {
            throw StorageProviderError.serverUnavailable
        }
        return StorageCatalog(snapshot: snapshot)
    }

    init(snapshot: DoryStorageInventorySnapshot) {
        self.snapshot = snapshot
        let root = StorageItem(
            identifier: .rootContainer,
            parentIdentifier: .rootContainer,
            filename: "Dory",
            isFolder: true,
            contents: nil,
            childCount: snapshot.groups.count + 1
        )
        let summary = StorageItem(
            identifier: Self.summaryIdentifier,
            parentIdentifier: .rootContainer,
            filename: "Storage Summary.txt",
            isFolder: false,
            contents: snapshot.summary,
            childCount: nil
        )
        var items = [root, summary]
        for group in snapshot.groups {
            let folderIdentifier = NSFileProviderItemIdentifier(rawValue: group.kind.folderIdentifier)
            items.append(StorageItem(
                identifier: folderIdentifier,
                parentIdentifier: .rootContainer,
                filename: group.finderFolderName,
                isFolder: true,
                contents: nil,
                childCount: group.entries.count
            ))
            items.append(contentsOf: group.entries.map { entry in
                StorageItem(
                    identifier: NSFileProviderItemIdentifier(rawValue: entry.identifier),
                    parentIdentifier: folderIdentifier,
                    filename: entry.finderFilename,
                    isFolder: false,
                    contents: entry.detail,
                    childCount: nil
                )
            })
        }
        itemsByIdentifier = Dictionary(uniqueKeysWithValues: items.map { ($0.itemIdentifier, $0) })
    }

    var syncAnchor: NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(rawValue: Data(String(snapshot.revision).utf8))
    }

    var allItems: [NSFileProviderItem] {
        itemsByIdentifier.values
            .filter { $0.itemIdentifier != .rootContainer }
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }

    var removedIdentifiers: [NSFileProviderItemIdentifier] {
        snapshot.removedIdentifiers.map(NSFileProviderItemIdentifier.init(rawValue:))
    }

    func item(_ identifier: NSFileProviderItemIdentifier) -> StorageItem? {
        itemsByIdentifier[identifier]
    }

    func children(of identifier: NSFileProviderItemIdentifier) -> [NSFileProviderItem] {
        itemsByIdentifier.values
            .filter { $0.parentItemIdentifier == identifier && $0.itemIdentifier != identifier }
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }
}

private final class StorageItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let isFolder: Bool
    let contents: String?
    let childCount: Int?

    init(
        identifier: NSFileProviderItemIdentifier,
        parentIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        isFolder: Bool,
        contents: String?,
        childCount: Int?
    ) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parentIdentifier
        self.filename = filename
        self.isFolder = isFolder
        self.contents = contents
        self.childCount = childCount
    }

    var contentType: UTType { isFolder ? .folder : .plainText }
    var capabilities: NSFileProviderItemCapabilities { .allowsReading }
    var contentPolicy: NSFileProviderContentPolicy { .downloadEagerlyAndKeepDownloaded }
    var isUploaded: Bool { true }
    var isDownloaded: Bool { true }
    var isMostRecentVersionDownloaded: Bool { true }
    var documentSize: NSNumber? { contents.map { NSNumber(value: $0.utf8.count) } }
    var childItemCount: NSNumber? { childCount.map(NSNumber.init(value:)) }
    var itemVersion: NSFileProviderItemVersion {
        // Content versions must only change when this item's bytes change. A global inventory
        // revision made every entry dataless whenever one image or cache record changed, which
        // briefly showed Finder cloud badges for otherwise local files.
        let contentVersion = Data((contents ?? "folder").utf8)
        let metadataVersion = Data("\(filename)\u{0}\(childCount ?? -1)".utf8)
        return NSFileProviderItemVersion(
            contentVersion: contentVersion,
            metadataVersion: metadataVersion
        )
    }
}
