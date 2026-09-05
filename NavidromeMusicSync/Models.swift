import Foundation

struct SubsonicEnvelope<T: Decodable>: Decodable {
    let response: T

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

struct PingResponse: Decodable {
    let status: String
    let version: String?
}

struct AlbumListResponse: Decodable {
    let status: String
    let albumList2: AlbumContainer?
}

struct AlbumContainer: Decodable {
    let album: [Album]
}

struct Album: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let artist: String?
    let coverArt: String?
    let songCount: Int?
}

struct StarredResponse: Decodable {
    let status: String
    let starred2: StarredContainer?
}

struct StarredContainer: Decodable {
    let song: [Song]?
}

struct AlbumResponse: Decodable {
    let status: String
    let album: AlbumDetail?
}

struct AlbumDetail: Decodable {
    let id: String
    let name: String
    let artist: String?
    let song: [Song]?
}

struct Song: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let album: String?
    let artist: String?
    let artistId: String?
    let genre: String?
    let suffix: String?
    let coverArt: String?
    let track: Int?
    let year: Int?
}
