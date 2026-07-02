//
//  TileMapNode.swift
//  IngotEngine
//
//  §4.4 Scene System — A grid of tiles drawn from a texture atlas.
//
//  Modeled after Godot's TileMap. The map is sparse: tiles are stored in
//  a dictionary keyed by grid coordinate, so levels can extend in any
//  direction without pre-allocating a fixed grid. Each tile references a
//  cell in the atlas texture (a sprite sheet laid out in a grid).
//
//  Tiles listed in `solidTiles` produce static AABB physics bodies so
//  players and enemies collide with the level geometry.
//
//  Rendering: the viewport expands the map into one instance per tile —
//  all tiles share the atlas texture, so the whole map still batches
//  into a single instanced draw call.
//

import MetalKit
import simd

/// A grid coordinate in a tile map. (0, 0) is the map's local origin;
/// +X is right, +Y is up (matching the engine's world axes).
struct TileCoord: Hashable {
    var x: Int
    var y: Int
}

class TileMapNode: Node {

    /// The atlas texture the tile indices refer to.
    /// nil falls back to the editor's default texture at render time.
    var texture: MTLTexture?

    /// The asset file the atlas came from (see SpriteNode.textureName).
    var textureName: String?

    /// How the atlas texture is subdivided into tile cells.
    var atlasColumns: Int = 4 { didSet { atlasColumns = max(atlasColumns, 1) } }
    var atlasRows: Int = 4 { didSet { atlasRows = max(atlasRows, 1) } }

    /// The size of one tile in world pixels.
    var tileWidth: Float = 64
    var tileHeight: Float = 64

    /// Tile indices whose cells should block movement (static colliders).
    var solidTiles: Set<Int> = [] {
        didSet { rebuildCollision() }
    }

    /// The sparse tile grid: coordinate → atlas tile index (0-based,
    /// left-to-right, top-to-bottom).
    private(set) var tiles: [TileCoord: Int] = [:]

    /// Static physics bodies generated from solid tiles. Registered by
    /// Scene.registerPhysicsBodies alongside regular node bodies.
    private(set) var collisionBodies: [PhysicsBody] = []

    override init() {
        super.init()
        name = "TileMap"
    }

    // MARK: - Tile editing

    /// Places a tile at a grid coordinate. A negative index erases.
    func setTile(x: Int, y: Int, tileIndex: Int) {
        if tileIndex < 0 {
            tiles.removeValue(forKey: TileCoord(x: x, y: y))
        } else {
            tiles[TileCoord(x: x, y: y)] = tileIndex
        }
        rebuildCollision()
    }

    /// Fills a rectangular region with one tile index (negative erases).
    func fillRect(x: Int, y: Int, width: Int, height: Int, tileIndex: Int) {
        for ty in y..<(y + max(height, 0)) {
            for tx in x..<(x + max(width, 0)) {
                if tileIndex < 0 {
                    tiles.removeValue(forKey: TileCoord(x: tx, y: ty))
                } else {
                    tiles[TileCoord(x: tx, y: ty)] = tileIndex
                }
            }
        }
        rebuildCollision()
    }

    /// Reads the tile index at a coordinate (nil = empty).
    func tile(x: Int, y: Int) -> Int? {
        tiles[TileCoord(x: x, y: y)]
    }

    /// Removes every tile from the map.
    func clearAllTiles() {
        tiles.removeAll()
        rebuildCollision()
    }

    /// Bulk-replaces the tile dictionary (used by the deserializer).
    func loadTiles(_ newTiles: [TileCoord: Int]) {
        tiles = newTiles
        rebuildCollision()
    }

    // MARK: - Rendering helpers

    /// The UV rect for an atlas tile index.
    func uvRect(forTileIndex index: Int) -> simd_float4 {
        let cellW = 1.0 / Float(atlasColumns)
        let cellH = 1.0 / Float(atlasRows)
        let column = index % atlasColumns
        let row = index / atlasColumns
        return simd_float4(Float(column) * cellW, Float(row) * cellH, cellW, cellH)
    }

    /// The local-space center of a tile cell.
    func tileCenter(_ coord: TileCoord) -> simd_float2 {
        simd_float2((Float(coord.x) + 0.5) * tileWidth,
                    (Float(coord.y) + 0.5) * tileHeight)
    }

    /// World-space model matrix for one tile. The shared quad is 100
    /// units (±50), so scale = tileSize / 100.
    func modelMatrix(for coord: TileCoord) -> simd_float4x4 {
        let center = tileCenter(coord)
        return globalTransform
            * translationMatrix(tx: center.x, ty: center.y)
            * scaleMatrix(sx: tileWidth / 100.0, sy: tileHeight / 100.0)
    }

    // MARK: - Collision

    /// Regenerates one static physics body per solid tile.
    ///
    /// Bodies use the `offset` field to sit at their tile's center while
    /// sharing this node as their owner. Collision assumes the tile map
    /// itself is unrotated and unscaled (rotating a collidable tile map
    /// is not supported — same restriction as AABB physics in general).
    ///
    /// NOTE: bodies are (re-)registered with the PhysicsWorld when play
    /// mode starts, so editing tiles in design mode is always safe.
    func rebuildCollision() {
        collisionBodies.removeAll()
        for (coord, index) in tiles where solidTiles.contains(index) {
            let body = PhysicsBody(size: simd_float2(tileWidth, tileHeight),
                                   isDynamic: false)
            body.owner = self
            body.offset = tileCenter(coord)
            collisionBodies.append(body)
        }
    }
}
