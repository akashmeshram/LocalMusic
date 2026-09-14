import CoreData

/// The Core Data model, declared in code so no `.xcdatamodeld` compilation step is required.
enum LibraryModel {
    static let trackEntityName = "Track"
    static let playlistEntityName = "Playlist"

    static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let track = NSEntityDescription()
        track.name = trackEntityName
        track.managedObjectClassName = "NSManagedObject"

        func attr(_ name: String, _ type: NSAttributeType, optional: Bool = true, indexed: Bool = false, defaultValue: Any? = nil) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            a.defaultValue = defaultValue
            return a
        }

        let attributes: [NSAttributeDescription] = [
            attr("id", .UUIDAttributeType, optional: false),
            attr("filePath", .stringAttributeType, optional: false),
            attr("sourceURL", .stringAttributeType),
            attr("extractor", .stringAttributeType),
            attr("title", .stringAttributeType, optional: false, defaultValue: ""),
            attr("artist", .stringAttributeType),
            attr("albumArtist", .stringAttributeType),
            attr("album", .stringAttributeType),
            attr("trackNumber", .integer32AttributeType),
            attr("discNumber", .integer32AttributeType),
            attr("genre", .stringAttributeType),
            attr("year", .integer32AttributeType),
            attr("composer", .stringAttributeType),
            attr("duration", .doubleAttributeType, optional: false, defaultValue: 0.0),
            attr("fileFormat", .stringAttributeType, optional: false, defaultValue: ""),
            attr("fileSize", .integer64AttributeType, optional: false, defaultValue: 0),
            attr("artworkFileName", .stringAttributeType),
            attr("musicBrainzRecordingID", .stringAttributeType),
            attr("musicBrainzReleaseID", .stringAttributeType),
            attr("dateAdded", .dateAttributeType, optional: false),
            attr("downloadDate", .dateAttributeType),
            attr("playCount", .integer32AttributeType, optional: false, defaultValue: 0),
            attr("isFavorite", .booleanAttributeType, optional: false, defaultValue: false),
            attr("lastPlayedAt", .dateAttributeType),
            attr("playbackPosition", .doubleAttributeType),
        ]
        track.properties = attributes
        track.uniquenessConstraints = [["id"], ["filePath"]]
        let byID = NSFetchIndexDescription(name: "byID", elements: [NSFetchIndexElementDescription(property: attributes[0], collationType: .binary)])
        let byPath = NSFetchIndexDescription(name: "byPath", elements: [NSFetchIndexElementDescription(property: attributes[1], collationType: .binary)])
        let bySource = NSFetchIndexDescription(name: "bySource", elements: [NSFetchIndexElementDescription(property: attributes[2], collationType: .binary)])
        track.indexes = [byID, byPath, bySource]

        let playlist = NSEntityDescription()
        playlist.name = playlistEntityName
        playlist.managedObjectClassName = "NSManagedObject"
        let playlistAttributes: [NSAttributeDescription] = [
            attr("id", .UUIDAttributeType, optional: false),
            attr("name", .stringAttributeType, optional: false, defaultValue: "Playlist"),
            attr("createdAt", .dateAttributeType, optional: false),
            attr("sortIndex", .integer32AttributeType, optional: false, defaultValue: 0),
            attr("trackIDs", .stringAttributeType, optional: false, defaultValue: "[]"),
        ]
        playlist.properties = playlistAttributes
        playlist.uniquenessConstraints = [["id"]]

        model.entities = [track, playlist]
        return model
    }
}
