//
//  AssetHandle.swift
//  IngotEngine
//
//  §4.2 Core/Foundation — Typed asset references.
//
//  An AssetHandle is a lightweight, type-safe reference to a loaded
//  asset. Instead of passing MTLTexture or AVAudioPlayer directly,
//  systems pass handles that the asset manager resolves. This allows:
//
//    - Deferred loading (load on first use)
//    - Hot-reloading (change the underlying resource, handles still work)
//    - Serialization (handles are just string IDs, fully Codable)
//

import Foundation

/// A typed reference to an asset. The generic parameter indicates what
/// kind of asset this handle points to (texture, sound, etc.).
struct AssetHandle<T>: Hashable, Codable {

    /// The unique identifier for this asset (e.g., "player_sprite",
    /// "bump.wav", or a UUID string for generated assets).
    let id: String

    init(_ id: String) {
        self.id = id
    }
}

/// Convenience type aliases for common asset types.
typealias TextureHandle = AssetHandle<TextureAsset>
typealias SoundHandle = AssetHandle<SoundAsset>

/// Marker types for the generic parameter — they carry no data,
/// they just make the type system distinguish texture handles from
/// sound handles so you can't accidentally pass one where the other
/// is expected.
enum TextureAsset {}
enum SoundAsset {}
