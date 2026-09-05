import Foundation
import SQLite3

enum LocalMusicDatabaseBuilderError: LocalizedError {
    case openFailed
    case incompatibleSchema(String)
    case sqlFailed(String)
    case integrityFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed:
            return "Could not open the local Music database working copy."
        case .incompatibleSchema(let detail):
            return "The Music database schema is not supported by the single-track builder yet: \(detail)"
        case .sqlFailed(let detail):
            return "Local Music database mutation failed: \(detail)"
        case .integrityFailed(let result):
            return "The modified local Music database failed PRAGMA quick_check: \(result)"
        }
    }
}

struct LocalMusicDatabaseMutationResult {
    let databaseURL: URL
    let itemPID: Int64
    let remoteFilename: String

    var summary: String {
        "Local injection simulation OK. Added item PID \(itemPID) -> \(remoteFilename); modified database passed quick_check. Nothing was written back to the device."
    }
}

/// Minimal, schema-aware subset of ByeTunes' MediaLibraryBuilder flow.
///
/// This class only mutates the protected local working copy created by
/// MusicLibraryStager. Device writes are deliberately kept out of this type.
final class LocalMusicDatabaseBuilder {
    private let requiredTables: Set<String> = [
        "item", "item_extra", "item_playback", "item_stats",
        "item_artist", "album_artist", "album", "genre",
        "base_location", "sort_map"
    ]

    func addSingleTrack(_ song: InjectionSongMetadata, to databaseURL: URL) throws -> LocalMusicDatabaseMutationResult {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            throw LocalMusicDatabaseBuilderError.openFailed
        }
        defer { sqlite3_close(db) }

        let tables = try tableNames(db)
        let missing = requiredTables.subtracting(tables)
        guard missing.isEmpty else {
            throw LocalMusicDatabaseBuilderError.incompatibleSchema("missing tables: \(missing.sorted().joined(separator: ", "))")
        }

        let preflight = try scalarText(db, "PRAGMA quick_check") ?? "unknown"
        guard preflight == "ok" else { throw LocalMusicDatabaseBuilderError.integrityFailed(preflight) }

        try exec(db, "BEGIN IMMEDIATE")
        do {
            try exec(db, "INSERT OR IGNORE INTO base_location (base_location_id, path) VALUES (3840, 'iTunes_Control/Music/F00')")

            let itemPID = randomPID()
            let artistPID = try existingPID(db, table: "item_artist", idColumn: "item_artist_pid", nameColumn: "item_artist", name: song.artist) ?? randomPID()
            let albumArtistPID = try existingPID(db, table: "album_artist", idColumn: "album_artist_pid", nameColumn: "album_artist", name: song.artist) ?? randomPID()
            let albumPID = try existingPID(db, table: "album", idColumn: "album_pid", nameColumn: "album", name: song.album) ?? randomPID()
            let genreName = "Music"
            let genrePID = try existingPID(db, table: "genre", idColumn: "genre_id", nameColumn: "genre", name: genreName) ?? randomPID()

            let titleSort = try ensureSortMap(db, name: song.title)
            let artistSort = try ensureSortMap(db, name: song.artist)
            let albumSort = try ensureSortMap(db, name: song.album)
            let genreSort = try ensureSortMap(db, name: genreName)

            if try !rowExists(db, table: "item_artist", idColumn: "item_artist_pid", id: artistPID) {
                try insertDynamic(db, table: "item_artist", values: [
                    "item_artist_pid": .int(artistPID),
                    "item_artist": .text(song.artist),
                    "sort_item_artist": .text(song.artist),
                    "series_name": .text(""),
                    "grouping_key": .blob(groupingKey(song.artist)),
                    "sync_id": .int(randomPID()),
                    "keep_local": .int(1),
                    "representative_item_pid": .int(itemPID),
                    "store_id": .int(0)
                ])
            }

            if try !rowExists(db, table: "album_artist", idColumn: "album_artist_pid", id: albumArtistPID) {
                try insertDynamic(db, table: "album_artist", values: [
                    "album_artist_pid": .int(albumArtistPID),
                    "album_artist": .text(song.artist),
                    "sort_album_artist": .text(song.artist),
                    "grouping_key": .blob(groupingKey(song.artist)),
                    "sync_id": .int(randomPID()),
                    "keep_local": .int(1),
                    "representative_item_pid": .int(itemPID),
                    "store_id": .int(0),
                    "sort_order": .int(artistSort.order),
                    "sort_order_section": .int(Int64(artistSort.section)),
                    "name_order": .int(artistSort.order)
                ])
            }

            if try !rowExists(db, table: "album", idColumn: "album_pid", id: albumPID) {
                try insertDynamic(db, table: "album", values: [
                    "album_pid": .int(albumPID),
                    "album": .text(song.album),
                    "sort_album": .text(song.album),
                    "album_artist_pid": .int(albumArtistPID),
                    "representative_item_pid": .int(itemPID),
                    "grouping_key": .blob(groupingKey(song.album)),
                    "album_year": .int(Int64(song.year)),
                    "keep_local": .int(1),
                    "sync_id": .int(randomPID()),
                    "store_id": .int(0)
                ])
            }

            if try !rowExists(db, table: "genre", idColumn: "genre_id", id: genrePID) {
                try insertDynamic(db, table: "genre", values: [
                    "genre_id": .int(genrePID),
                    "genre": .text(genreName),
                    "grouping_key": .blob(groupingKey(genreName)),
                    "representative_item_pid": .int(itemPID)
                ])
            }

            let now = Int64(Date().timeIntervalSince1970)
            try insertDynamic(db, table: "item", values: [
                "item_pid": .int(itemPID),
                "media_type": .int(8),
                "title_order": .int(titleSort.order),
                "title_order_section": .int(Int64(titleSort.section)),
                "item_artist_pid": .int(artistPID),
                "item_artist_order": .int(artistSort.order),
                "item_artist_order_section": .int(Int64(artistSort.section)),
                "series_name_order": .int(0),
                "series_name_order_section": .int(26),
                "album_pid": .int(albumPID),
                "album_order": .int(albumSort.order),
                "album_order_section": .int(Int64(albumSort.section)),
                "album_artist_pid": .int(albumArtistPID),
                "album_artist_order": .int(artistSort.order),
                "album_artist_order_section": .int(Int64(artistSort.section)),
                "composer_pid": .int(0),
                "composer_order": .int(0),
                "composer_order_section": .int(26),
                "genre_id": .int(genrePID),
                "genre_order": .int(genreSort.order),
                "genre_order_section": .int(Int64(genreSort.section)),
                "disc_number": .int(1),
                "track_number": .int(Int64(song.trackNumber ?? 1)),
                "episode_sort_id": .int(1),
                "base_location_id": .int(3840),
                "remote_location_id": .int(0),
                "exclude_from_shuffle": .int(0),
                "keep_local": .int(1),
                "keep_local_status": .int(2),
                "keep_local_status_reason": .int(0),
                "keep_local_constraints": .int(0),
                "in_my_library": .int(1),
                "is_compilation": .int(0),
                "date_added": .int(now),
                "show_composer": .int(0),
                "is_music_show": .int(0),
                "date_downloaded": .int(now),
                "download_source_container_pid": .int(0)
            ])

            try insertDynamic(db, table: "item_extra", values: [
                "item_pid": .int(itemPID),
                "title": .text(song.title),
                "sort_title": .text(song.title),
                "disc_count": .int(1),
                "track_count": .int(1),
                "total_time_ms": .int(Int64(song.durationMs)),
                "year": .int(Int64(song.year)),
                "location": .text(song.remoteFilename),
                "file_size": .int(Int64(song.fileSize)),
                "integrity": .blob(Data()),
                "is_audible_audio_book": .int(0),
                "date_modified": .int(now),
                "media_kind": .int(1),
                "content_rating": .int(0),
                "content_rating_level": .int(0),
                "is_user_disabled": .int(0),
                "bpm": .int(0),
                "genius_id": .int(0),
                "location_kind_id": .int(42),
                "copyright": .text("")
            ])

            try insertDynamic(db, table: "item_playback", values: [
                "item_pid": .int(itemPID),
                "audio_format": .int(Int64(audioFormat(song.fileExtension))),
                "bit_rate": .int(320),
                "codec_type": .int(0),
                "codec_subtype": .int(0),
                "data_kind": .int(0),
                "duration": .int(0),
                "has_video": .int(0),
                "relative_volume": .int(0),
                "sample_rate": .double(44100)
            ])

            try insertDynamic(db, table: "item_stats", values: ["item_pid": .int(itemPID), "date_accessed": .int(now)])
            if tables.contains("item_search") {
                try insertDynamic(db, table: "item_search", replace: true, values: [
                    "item_pid": .int(itemPID), "search_title": .int(titleSort.order), "search_album": .int(albumSort.order),
                    "search_artist": .int(artistSort.order), "search_composer": .int(0), "search_album_artist": .int(artistSort.order)
                ])
            }
            if tables.contains("chapter") {
                try insertDynamic(db, table: "chapter", replace: true, values: ["item_pid": .int(itemPID)])
            }
            if tables.contains("item_store") {
                try insertDynamic(db, table: "item_store", replace: true, values: [
                    "item_pid": .int(itemPID), "sync_id": .int(randomPID()), "sync_in_my_library": .int(1),
                    "is_subscription": .int(0), "store_saga_id": .int(0), "cloud_status": .int(0),
                    "store_item_id": .int(0), "storefront_id": .int(0), "store_composer_id": .int(0),
                    "store_genre_id": .int(0), "store_playlist_id": .int(0), "subscription_store_item_id": .int(0),
                    "cloud_asset_available": .int(0), "cloud_in_my_library": .int(0),
                    "playback_endpoint_type": .int(0), "cloud_playback_endpoint_type": .int(0)
                ])
            }

            try exec(db, "COMMIT")
            _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            _ = sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil)

            let postflight = try scalarText(db, "PRAGMA quick_check") ?? "unknown"
            guard postflight == "ok" else { throw LocalMusicDatabaseBuilderError.integrityFailed(postflight) }

            return LocalMusicDatabaseMutationResult(databaseURL: databaseURL, itemPID: itemPID, remoteFilename: song.remoteFilename)
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private enum SQLValue {
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
    }

    private func insertDynamic(_ db: OpaquePointer, table: String, replace: Bool = false, values: [String: SQLValue]) throws {
        let columns = try tableColumns(db, table)
        let filtered = values.filter { columns.contains($0.key) }
        guard !filtered.isEmpty else { throw LocalMusicDatabaseBuilderError.incompatibleSchema("no compatible columns for \(table)") }
        let ordered = filtered.keys.sorted()
        let verb = replace ? "INSERT OR REPLACE" : "INSERT"
        let sql = "\(verb) INTO \(table) (\(ordered.joined(separator: ","))) VALUES (\(Array(repeating: "?", count: ordered.count).joined(separator: ",")))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        for (index, key) in ordered.enumerated() {
            let position = Int32(index + 1)
            switch filtered[key]! {
            case .int(let value): sqlite3_bind_int64(statement, position, value)
            case .double(let value): sqlite3_bind_double(statement, position, value)
            case .text(let value): sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case .blob(let value):
                value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
                }
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqlError(db) }
    }

    private func ensureSortMap(_ db: OpaquePointer, name: String) throws -> (order: Int64, section: Int) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name_order, name_section FROM sort_map WHERE name = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        if sqlite3_step(statement) == SQLITE_ROW {
            let result = (sqlite3_column_int64(statement, 0), Int(sqlite3_column_int(statement, 1)))
            sqlite3_finalize(statement)
            return result
        }
        sqlite3_finalize(statement)
        let next = (try scalarInt64(db, "SELECT COALESCE(MAX(name_order),0)+1 FROM sort_map"))
        let section = sectionForName(name)
        try insertDynamic(db, table: "sort_map", values: [
            "name": .text(name), "sort_key": .text(name.uppercased()), "name_order": .int(next), "name_section": .int(Int64(section))
        ])
        return (next, section)
    }

    private func existingPID(_ db: OpaquePointer, table: String, idColumn: String, nameColumn: String, name: String) throws -> Int64? {
        var statement: OpaquePointer?
        let sql = "SELECT \(idColumn) FROM \(table) WHERE \(nameColumn) = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
    }

    private func rowExists(_ db: OpaquePointer, table: String, idColumn: String, id: Int64) throws -> Bool {
        try scalarInt64(db, "SELECT COUNT(*) FROM \(table) WHERE \(idColumn) = \(id)") > 0
    }

    private func tableNames(_ db: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) { names.insert(String(cString: text)) }
        return names
    }

    private func tableColumns(_ db: OpaquePointer, _ table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 1) { names.insert(String(cString: text)) }
        return names
    }

    private func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func scalarInt64(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &message)
        if result != SQLITE_OK {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(message)
            throw LocalMusicDatabaseBuilderError.sqlFailed(detail)
        }
    }

    private func sqlError(_ db: OpaquePointer) -> LocalMusicDatabaseBuilderError {
        .sqlFailed(String(cString: sqlite3_errmsg(db)))
    }

    private func randomPID() -> Int64 { Int64.random(in: 1_000_000_000_000_000_000...Int64.max) }

    private func sectionForName(_ name: String) -> Int {
        guard let first = name.uppercased().unicodeScalars.first else { return 26 }
        let value = Int(first.value)
        return (65...90).contains(value) ? value - 65 : 26
    }

    private func groupingKey(_ text: String) -> Data {
        var result = [UInt8]()
        for char in text.uppercased() {
            if let ascii = char.asciiValue, ascii >= 65 && ascii <= 90 { result.append(ascii - 64) }
            else if char == " " { result.append(0x04) }
            else if char == "/" { result.append(0x0A) }
        }
        return Data(result)
    }

    private func audioFormat(_ ext: String) -> Int {
        switch ext.lowercased() {
        case "mp3": return 301
        case "flac": return fourCC("fLaC")
        case "opus": return fourCC("opus")
        case "m4a", "aac", "m4r": return fourCC("aac ")
        case "alac": return fourCC("alac")
        case "wav", "wave": return fourCC("WAVE")
        default: return 0
        }
    }

    private func fourCC(_ value: String) -> Int {
        let bytes = Array(value.utf8) + Array(repeating: 0x20, count: max(0, 4 - value.utf8.count))
        return bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    }
}
