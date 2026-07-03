//
//  TileSetLibrary.swift
//  IngotEngine
//
//  §4.4 — Named, reusable tile sets (Godot TileSet-style).
//
//  A TileSetDefinition bundles everything a TileMapNode needs to paint
//  from an atlas: the atlas asset, how it subdivides into cells, the
//  world size of one tile, and which tile indices are solid. Sets are
//  authored in the Tile Sets window (visual atlas preview — click
//  cells to mark them solid), stored per project in tilesets.json,
//  and applied to any TileMapNode from the Inspector's Tile Set
//  popup, the Asset Library (double-click), or the AI copilot
//  (configureTileMap with "tileSet").
//
//  Applying a set COPIES its values onto the node, so scene files
//  stay self-contained — exported games never need tilesets.json.
//  The node records tileSetName purely as provenance.
//

import Foundation

/// One named tile set: atlas + grid + tile size + solid indices.
struct TileSetDefinition: Codable, Equatable {

    /// The name shown in the editor and used by AI commands.
    var name: String

    /// The atlas asset (in Assets/) the tile indices refer to.
    var textureName: String?

    /// How the atlas subdivides into tile cells.
    var atlasColumns: Int = 4
    var atlasRows: Int = 4

    /// World size of one painted tile, in pixels.
    var tileWidth: Float = 32
    var tileHeight: Float = 32

    /// Atlas indices that produce static colliders when painted.
    var solidTiles: [Int] = []

    /// Named tile groups ("Ground", "Hazards", "Decor") that organize
    /// a big atlas — the way a character groups its animation clips.
    /// Purely editorial: the editor and palette color-code them; the
    /// engine only cares about solidTiles. Optional so old
    /// tilesets.json files decode cleanly.
    var categories: [String: [Int]]?
}

/// Project-wide tile set storage (mirrors AnimationLibrary's shape).
enum TileSetLibrary {

    /// In-memory cache, keyed by name. Loaded lazily from the project
    /// and refreshed after every save.
    private static var cache: [String: TileSetDefinition]?

    private static var fileURL: URL? {
        ProjectManager.shared.currentProjectURL?
            .appendingPathComponent("tilesets.json")
    }

    /// All tile sets in the project, keyed by name.
    static func all() -> [String: TileSetDefinition] {
        if let cache { return cache }
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([TileSetDefinition].self, from: data) else {
            cache = [:]
            return [:]
        }
        var byName: [String: TileSetDefinition] = [:]
        for tileSet in decoded { byName[tileSet.name] = tileSet }
        cache = byName
        return byName
    }

    /// Tile set names, sorted for stable UI display.
    static func list() -> [String] {
        all().keys.sorted()
    }

    static func tileSet(named name: String) -> TileSetDefinition? {
        all()[name]
    }

    /// Adds or replaces a tile set and persists the library.
    @discardableResult
    static func save(_ tileSet: TileSetDefinition) -> Bool {
        var sets = all()
        sets[tileSet.name] = tileSet
        return persist(sets)
    }

    /// Removes a tile set and persists the library.
    @discardableResult
    static func delete(named name: String) -> Bool {
        var sets = all()
        sets.removeValue(forKey: name)
        return persist(sets)
    }

    /// Drops the cache (called when switching projects).
    static func invalidate() {
        cache = nil
    }

    private static func persist(_ sets: [String: TileSetDefinition]) -> Bool {
        guard let url = fileURL else {
            Log.warning("No project open — cannot save tile sets.")
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sets.values.sorted { $0.name < $1.name }) else {
            return false
        }
        do {
            try data.write(to: url)
            cache = sets
            return true
        } catch {
            Log.error("Could not save tilesets.json: \(error)")
            return false
        }
    }
}
