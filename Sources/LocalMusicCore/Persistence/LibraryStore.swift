import CoreData
import Foundation

/// Core Data backed index of the music library. All access goes through async methods that run
/// on private queues and return `Sendable` value types; no `NSManagedObject` leaves this file.
public final class LibraryStore: @unchecked Sendable {
    private let container: NSPersistentContainer

    /// Pass `nil` for an in-memory store (previews and tests).
    public init(storeURL: URL?) throws {
        container = NSPersistentContainer(name: "LocalMusic", managedObjectModel: LibraryModel.make())
        let description: NSPersistentStoreDescription
        if let storeURL {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            description = NSPersistentStoreDescription(url: storeURL)
            description.type = NSSQLiteStoreType
        } else {
            description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
        }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            throw LocalMusicError(kind: .database, message: "The library database could not be opened.", technicalDetails: loadError.localizedDescription)
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    private func background() -> NSManagedObjectContext {
        let ctx = container.newBackgroundContext()
        ctx.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        return ctx
    }

    // MARK: Reads

    public func allTracks() async throws -> [TrackRecord] {
        let ctx = background()
        return try await ctx.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.trackEntityName)
            request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]
            return try ctx.fetch(request).map(Self.record)
        }
    }

    public func track(id: UUID) async throws -> TrackRecord? {
        try await fetchOne(NSPredicate(format: "id == %@", id as CVarArg))
    }

    public func track(filePath: String) async throws -> TrackRecord? {
        try await fetchOne(NSPredicate(format: "filePath == %@", filePath))
    }

    public func tracks(sourceURL: String) async throws -> [TrackRecord] {
        let ctx = background()
        return try await ctx.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.trackEntityName)
            request.predicate = NSPredicate(format: "sourceURL == %@", sourceURL)
            return try ctx.fetch(request).map(Self.record)
        }
    }

    private func fetchOne(_ predicate: NSPredicate) async throws -> TrackRecord? {
        let ctx = background()
        return try await ctx.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.trackEntityName)
            request.predicate = predicate
            request.fetchLimit = 1
            return try ctx.fetch(request).first.map(Self.record)
        }
    }

    // MARK: Writes

    /// Inserts or updates by `id`, falling back to `filePath` so a rescanned file keeps one row.
    public func upsert(_ records: [TrackRecord]) async throws {
        guard !records.isEmpty else { return }
        let ctx = background()
        try await ctx.perform {
            for record in records {
                let object = try Self.find(in: ctx, id: record.id) ?? Self.find(in: ctx, filePath: record.fileURL.path)
                    ?? NSEntityDescription.insertNewObject(forEntityName: LibraryModel.trackEntityName, into: ctx)
                Self.apply(record, to: object)
            }
            if ctx.hasChanges { try ctx.save() }
        }
    }

    public func delete(ids: [UUID]) async throws {
        let ctx = background()
        try await ctx.perform {
            for id in ids {
                if let object = try Self.find(in: ctx, id: id) { ctx.delete(object) }
            }
            if ctx.hasChanges { try ctx.save() }
        }
    }

    /// Removes rows whose file path is not in `keep`. Used after a scan to drop deleted files.
    public func deleteTracks(notIn keep: Set<String>) async throws -> Int {
        let ctx = background()
        return try await ctx.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.trackEntityName)
            var removed = 0
            for object in try ctx.fetch(request) {
                let path = object.value(forKey: "filePath") as? String ?? ""
                if !keep.contains(path) { ctx.delete(object); removed += 1 }
            }
            if ctx.hasChanges { try ctx.save() }
            return removed
        }
    }

    public func deleteAll() async throws {
        let ctx = background()
        try await ctx.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.trackEntityName)
            for object in try ctx.fetch(request) { ctx.delete(object) }
            if ctx.hasChanges { try ctx.save() }
        }
    }

    public func recordPlay(id: UUID) async throws {
        try await mutate(id: id) { object in
            let count = (object.value(forKey: "playCount") as? Int32 ?? 0) + 1
            object.setValue(count, forKey: "playCount")
            object.setValue(Date(), forKey: "lastPlayedAt")
        }
    }

    public func setFavorite(id: UUID, _ isFavorite: Bool) async throws {
        try await mutate(id: id) { $0.setValue(isFavorite, forKey: "isFavorite") }
    }

    public func savePlaybackPosition(id: UUID, position: TimeInterval?) async throws {
        try await mutate(id: id) { $0.setValue(position, forKey: "playbackPosition") }
    }

    private func mutate(id: UUID, _ body: @escaping @Sendable (NSManagedObject) -> Void) async throws {
        let ctx = background()
        try await ctx.perform {
            guard let object = try Self.find(in: ctx, id: id) else { return }
            body(object)
            if ctx.hasChanges { try ctx.save() }
        }
    }

    // MARK: Mapping

    private static func find(in ctx: NSManagedObjectContext, id: UUID) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.trackEntityName)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try ctx.fetch(request).first
    }

    private static func find(in ctx: NSManagedObjectContext, filePath: String) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.trackEntityName)
        request.predicate = NSPredicate(format: "filePath == %@", filePath)
        request.fetchLimit = 1
        return try ctx.fetch(request).first
    }

    private static func apply(_ r: TrackRecord, to o: NSManagedObject) {
        o.setValue(r.id, forKey: "id")
        o.setValue(r.fileURL.path, forKey: "filePath")
        o.setValue(r.sourceURL, forKey: "sourceURL")
        o.setValue(r.extractor, forKey: "extractor")
        o.setValue(r.title, forKey: "title")
        o.setValue(r.artist, forKey: "artist")
        o.setValue(r.albumArtist, forKey: "albumArtist")
        o.setValue(r.album, forKey: "album")
        o.setValue(r.trackNumber.map { Int32($0) }, forKey: "trackNumber")
        o.setValue(r.discNumber.map { Int32($0) }, forKey: "discNumber")
        o.setValue(r.genre, forKey: "genre")
        o.setValue(r.year.map { Int32($0) }, forKey: "year")
        o.setValue(r.composer, forKey: "composer")
        o.setValue(r.duration, forKey: "duration")
        o.setValue(r.fileFormat, forKey: "fileFormat")
        o.setValue(r.fileSize, forKey: "fileSize")
        o.setValue(r.artworkFileName, forKey: "artworkFileName")
        o.setValue(r.musicBrainzRecordingID, forKey: "musicBrainzRecordingID")
        o.setValue(r.musicBrainzReleaseID, forKey: "musicBrainzReleaseID")
        o.setValue(r.dateAdded, forKey: "dateAdded")
        o.setValue(r.downloadDate, forKey: "downloadDate")
        o.setValue(Int32(r.playCount), forKey: "playCount")
        o.setValue(r.isFavorite, forKey: "isFavorite")
        o.setValue(r.lastPlayedAt, forKey: "lastPlayedAt")
        o.setValue(r.playbackPosition, forKey: "playbackPosition")
    }

    private static func record(_ o: NSManagedObject) -> TrackRecord {
        func s(_ k: String) -> String? { o.value(forKey: k) as? String }
        func i(_ k: String) -> Int? { (o.value(forKey: k) as? Int32).map(Int.init) }
        return TrackRecord(
            id: o.value(forKey: "id") as? UUID ?? UUID(),
            fileURL: URL(fileURLWithPath: s("filePath") ?? ""),
            sourceURL: s("sourceURL"),
            extractor: s("extractor"),
            title: s("title") ?? "",
            artist: s("artist"),
            albumArtist: s("albumArtist"),
            album: s("album"),
            trackNumber: i("trackNumber"),
            discNumber: i("discNumber"),
            genre: s("genre"),
            year: i("year"),
            composer: s("composer"),
            duration: o.value(forKey: "duration") as? Double ?? 0,
            fileFormat: s("fileFormat") ?? "",
            fileSize: o.value(forKey: "fileSize") as? Int64 ?? 0,
            artworkFileName: s("artworkFileName"),
            musicBrainzRecordingID: s("musicBrainzRecordingID"),
            musicBrainzReleaseID: s("musicBrainzReleaseID"),
            dateAdded: o.value(forKey: "dateAdded") as? Date ?? Date(),
            downloadDate: o.value(forKey: "downloadDate") as? Date,
            playCount: i("playCount") ?? 0,
            isFavorite: o.value(forKey: "isFavorite") as? Bool ?? false,
            lastPlayedAt: o.value(forKey: "lastPlayedAt") as? Date,
            playbackPosition: o.value(forKey: "playbackPosition") as? Double)
    }
}
