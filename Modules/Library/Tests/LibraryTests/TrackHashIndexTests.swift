import CryptoKit
import Foundation
import Persistence
import Testing
@testable import Library

// MARK: - Shared-session track-identity index (contract section 8)

@Suite("TrackHashIndex")
struct TrackHashIndexTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("track-hash-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `bytes` to a file and returns the track row (bookmark included)
    /// plus its expected lowercase-hex SHA-256 - the contract's `trackHash`.
    private func makeFileTrack(
        in dir: URL,
        name: String,
        bytes: Data
    ) throws -> (track: Track, expectedHash: String) {
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        let now = Int64(Date().timeIntervalSince1970)
        let track = try Track(
            fileURL: url.absoluteString,
            fileBookmark: LibraryLocation.bookmark(for: url),
            fileSize: Int64(bytes.count),
            fileMtime: now,
            fileFormat: "flac",
            duration: 1,
            title: name,
            addedAt: now,
            updatedAt: now
        )
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (track, expected)
    }

    @Test("hash(trackID:) hashes lazily and persists the digest")
    func lazyHashAndPersist() async throws {
        let db = try await makeDB()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (track, expected) = try makeFileTrack(in: dir, name: "Hallelujah.flac", bytes: Data("audio-bytes".utf8))
        let tracks = TrackRepository(database: db)
        let trackID = try await tracks.upsert(track)
        let index = TrackHashIndex(
            tracks: tracks,
            contentHash: ContentHashService(tracks: tracks)
        )

        let hash = await index.hash(trackID: trackID)
        #expect(hash == expected)

        // The digest is persisted: a second call re-serves it without
        // touching the file (the file is removed; a re-hash would fail).
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Hallelujah.flac"))
        let cached = await index.hash(trackID: trackID)
        #expect(cached == expected)
    }

    @Test("track(forHash:) resolves the local copy; unknown hashes are library_unsynced")
    func resolverRoundTrip() async throws {
        let db = try await makeDB()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (track, expected) = try makeFileTrack(in: dir, name: "Song.flac", bytes: Data("same-bytes".utf8))
        let tracks = TrackRepository(database: db)
        let trackID = try await tracks.upsert(track)
        let index = TrackHashIndex(
            tracks: tracks,
            contentHash: ContentHashService(tracks: tracks)
        )

        // Production order: the peer's provider hashed the track before
        // broadcasting, so the resolver only ever looks up stored digests.
        _ = await index.hash(trackID: trackID)
        let resolved = await index.track(forHash: expected)
        #expect(resolved?.id == trackID)
        #expect(resolved?.title == "Song.flac")

        let unsynced = await index.track(forHash: String(repeating: "0", count: 64))
        #expect(unsynced == nil)
    }
}
