import Foundation
import CryptoKit
import SQLite3
import UIKit

struct InjectionArtwork {
    let data: Data
    let token: String
    let relativePath: String

    var remotePath: String {
        "/iTunes_Control/iTunes/Artwork/Originals/\(relativePath)"
    }

    /// ByeTunes' iOS 26.4+ local artwork path is derived from the artwork token:
    /// relative path = SHA1(token) split 2/rest.
    static func make(from rawData: Data, itemPID: Int64) -> InjectionArtwork? {
        make(from: rawData, token: String(itemPID))
    }

    static func make(from rawData: Data, token: String) -> InjectionArtwork? {
        guard let image = UIImage(data: rawData), let jpeg = image.jpegData(compressionQuality: 0.94) else { return nil }
        let digest = Insecure.SHA1.hash(data: Data(token.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return InjectionArtwork(data: jpeg, token: token, relativePath: "\(hex.prefix(2))/\(hex.dropFirst(2))")
    }

    static func stableArtistToken(artistID: String) -> String {
        let digest = SHA256.hash(data: Data(artistID.utf8))
        var value: UInt64 = 0
        for byte in digest.prefix(8) { value = (value << 8) | UInt64(byte) }
        value &= 0x7FFF_FFFF_FFFF_FFFF
        return String(max(value, 1))
    }
}

enum MusicArtworkDatabaseError: LocalizedError {
    case openFailed
    case unsupportedSchema
    case sqlFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed: return "Could not open the Music database for artwork metadata."
        case .unsupportedSchema: return "This Music database does not expose the artwork tables required for local covers."
        case .sqlFailed(let detail): return "Artwork database update failed: \(detail)"
        }
    }
}

final class MusicArtworkDatabaseWriter {
    func attachAlbumArtwork(databaseURL: URL, itemPID: Int64, artwork: InjectionArtwork) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            if handle != nil { sqlite3_close(handle) }
            throw MusicArtworkDatabaseError.openFailed
        }
        defer { sqlite3_close(db) }

        guard try tableExists(db, "artwork"), try tableExists(db, "artwork_token"), try tableExists(db, "best_artwork_token") else {
            throw MusicArtworkDatabaseError.unsupportedSchema
        }
        guard let albumPID = try scalarInt64(db, "SELECT album_pid FROM item WHERE item_pid = \(itemPID) LIMIT 1") else {
            throw MusicArtworkDatabaseError.unsupportedSchema
        }

        let artistPID = try scalarInt64(db, "SELECT item_artist_pid FROM item WHERE item_pid = \(itemPID) LIMIT 1")
        let remoteFilename = try scalarText(db, "SELECT location FROM item_extra WHERE item_pid = \(itemPID) LIMIT 1")

        try exec(db, "BEGIN IMMEDIATE")
        do {
            // iOS 26.4+ local album artwork. This path is validated on-device.
            try writeArtworkLink(
                db,
                entityPID: albumPID,
                entityType: 4,
                artworkType: 6,
                sourceType: 300,
                token: artwork.token,
                relativePath: artwork.relativePath
            )

            // Track rows / Now Playing use ByeTunes' item mapping.
            try insertDynamic(db, table: "best_artwork_token", replace: true, values: [
                "entity_pid": .int(itemPID),
                "entity_type": .int(0),
                "artwork_type": .int(1),
                "available_artwork_token": .text(artwork.token),
                "fetchable_artwork_token": .text(""),
                "fetchable_artwork_source_type": .int(0),
                "artwork_variant_type": .int(0)
            ])

            // Use Navidrome's actual artist artwork when the Subsonic song carries
            // an artistId. ByeTunes maps artist artwork as entity_type=2/type=1,
            // with artwork source 1. Failure is intentionally non-fatal.
            if let artistPID,
               let remoteFilename,
               let artistID = InjectionMetadataRegistry.takeArtistID(for: remoteFilename),
               let rawArtistArtwork = NavidromeArtistArtworkFetcher.fetch(artistID: artistID),
               let artistArtwork = InjectionArtwork.make(
                    from: rawArtistArtwork,
                    token: InjectionArtwork.stableArtistToken(artistID: artistID)
               ) {
                try writeArtworkLink(
                    db,
                    entityPID: artistPID,
                    entityType: 2,
                    artworkType: 1,
                    sourceType: 1,
                    token: artistArtwork.token,
                    relativePath: artistArtwork.relativePath
                )
                InjectionMetadataRegistry.setPendingArtistArtwork(artistArtwork, forAlbumToken: artwork.token)
            }

            try exec(db, "COMMIT")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func writeArtworkLink(
        _ db: OpaquePointer,
        entityPID: Int64,
        entityType: Int64,
        artworkType: Int64,
        sourceType: Int64,
        token: String,
        relativePath: String
    ) throws {
        let tokenColumns = try tableColumns(db, "artwork_token")
        var tokenValues: [String: SQLValue] = [
            "artwork_token": .text(token),
            "artwork_source_type": .int(sourceType),
            "artwork_type": .int(artworkType),
            "entity_pid": .int(entityPID),
            "entity_type": .int(entityType),
            "artwork_variant_type": .int(0)
        ]
        for name in ["primary_text_color", "secondary_text_color", "tertiary_text_color", "quaternary_text_color", "background_color", "gradient_text_color", "gradient_color"] where tokenColumns.contains(name) {
            tokenValues[name] = .text("")
        }
        if tokenColumns.contains("gradient_size_start") { tokenValues["gradient_size_start"] = .double(-1) }
        if tokenColumns.contains("gradient_size_end") { tokenValues["gradient_size_end"] = .double(-1) }
        try insertDynamic(db, table: "artwork_token", replace: true, values: tokenValues)

        let artworkColumns = try tableColumns(db, "artwork")
        var artworkValues: [String: SQLValue] = [
            "artwork_token": .text(token),
            "artwork_source_type": .int(sourceType),
            "relative_path": .text(relativePath),
            "artwork_type": .int(artworkType),
            "artwork_variant_type": .int(0)
        ]
        if artworkColumns.contains("interest_data") { artworkValues["interest_data"] = .text("") }
        try insertDynamic(db, table: "artwork", replace: true, values: artworkValues)

        try insertDynamic(db, table: "best_artwork_token", replace: true, values: [
            "entity_pid": .int(entityPID),
            "entity_type": .int(entityType),
            "artwork_type": .int(artworkType),
            "available_artwork_token": .text(token),
            "fetchable_artwork_token": .text(""),
            "fetchable_artwork_source_type": .int(0),
            "artwork_variant_type": .int(0)
        ])
    }

    private enum SQLValue { case int(Int64), double(Double), text(String) }

    private func insertDynamic(_ db: OpaquePointer, table: String, replace: Bool, values: [String: SQLValue]) throws {
        let columns = try tableColumns(db, table)
        let filtered = values.filter { columns.contains($0.key) }
        let ordered = filtered.keys.sorted()
        guard !ordered.isEmpty else { throw MusicArtworkDatabaseError.unsupportedSchema }
        let verb = replace ? "INSERT OR REPLACE" : "INSERT"
        let sql = "\(verb) INTO \(table) (\(ordered.joined(separator: ","))) VALUES (\(Array(repeating: "?", count: ordered.count).joined(separator: ",")))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        for (index, key) in ordered.enumerated() {
            let pos = Int32(index + 1)
            switch filtered[key]! {
            case .int(let value): sqlite3_bind_int64(statement, pos, value)
            case .double(let value): sqlite3_bind_double(statement, pos, value)
            case .text(let value): sqlite3_bind_text(statement, pos, value, -1, SQLITE_TRANSIENT)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqlError(db) }
    }

    private func tableExists(_ db: OpaquePointer, _ table: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) > 0
    }

    private func tableColumns(_ db: OpaquePointer, _ table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 1) { result.insert(String(cString: text)) }
        return result
    }

    private func scalarInt64(_ db: OpaquePointer, _ sql: String) throws -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let message { sqlite3_free(message) }
            throw MusicArtworkDatabaseError.sqlFailed(detail)
        }
    }

    private func sqlError(_ db: OpaquePointer) -> MusicArtworkDatabaseError {
        .sqlFailed(String(cString: sqlite3_errmsg(db)))
    }
}
