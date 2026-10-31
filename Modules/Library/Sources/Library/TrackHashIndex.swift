import Foundation
import Observability
import Persistence

/// The shared-session track-identity index (contract section 8): Bòcan's
/// `tracks.content_hash` - the persisted lowercase-hex SHA-256 of the audio
/// file's bytes, computed by `ContentHashService` through the track's
/// security-scoped bookmark - is the protocol's `trackHash`. Synced
/// libraries are byte-identical, so two rows with the same digest are the
/// same recording.
///
/// Caching semantics vs the contract's "(path, size, mtime)" prescription:
/// the digest is persisted and never recomputed for an unchanged file; a
/// changed file's re-import resets `content_hash` to NULL (the scanner's
/// conflict path), and the background backfill re-hashes it. Same lazy,
/// incremental, off-the-hot-path behaviour, with the scanner as the
/// staleness signal instead of a stat comparison.
public actor TrackHashIndex {
    private let logger = AppLogger.make(.library)

    private let tracks: TrackRepository
    private let contentHash: ContentHashService

    /// - Parameters:
    ///   - tracks: the track rows (persisted digests + resolver lookups).
    ///   - contentHash: the lazy hasher behind `hash(trackID:)`.
    public init(tracks: TrackRepository, contentHash: ContentHashService) {
        self.tracks = tracks
        self.contentHash = contentHash
    }

    /// The `trackHash` for a track: the persisted digest, hashing the file
    /// lazily on first use (never on the audio playback path - callers invoke
    /// this when playback state is about to be advertised or a handoff is
    /// requested). Returns nil for tracks without a readable file.
    public func hash(trackID: Int64) async -> String? {
        await self.contentHash.hash(trackID: trackID)
    }

    /// The resolver: the local copy of the track a peer's `trackHash` names.
    /// Returns nil when the hash is not in the local index (the contract's
    /// `library_unsynced` case).
    public func track(forHash hash: String) async -> Track? {
        do {
            guard let id = try await self.tracks.fetchTrackID(contentHash: hash) else { return nil }
            return try await self.tracks.fetchIfPresent(id: id)
        } catch {
            self.logger.warning("presence.session.resolve.failed", ["error": String(reflecting: error)])
            return nil
        }
    }
}
