//
//  TileMapAndAnimationTests.swift
//  EngineTests
//
//  Tile grids (UV math, collision generation) and the named-animation
//  pipeline (library persistence, sprite playback frame stepping).
//

import XCTest
import simd
@testable import IngotEngineCore

final class TileMapAndAnimationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestSupport.openTempProject()
    }

    // MARK: - Tile maps

    func testUVRectForAtlasIndex() {
        let map = TileMapNode()
        map.atlasColumns = 4
        map.atlasRows = 2

        // Index 5 = column 1, row 1 in a 4-wide atlas.
        let uv = map.uvRect(forTileIndex: 5)
        XCTAssertEqual(uv.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(uv.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(uv.z, 0.25, accuracy: 0.0001)
        XCTAssertEqual(uv.w, 0.5, accuracy: 0.0001)
    }

    func testSolidTilesGenerateOffsetColliders() {
        let map = TileMapNode()
        map.tileWidth = 64
        map.tileHeight = 64
        map.solidTiles = [1]

        map.setTile(x: 0, y: 0, tileIndex: 1)   // solid
        map.setTile(x: 3, y: 0, tileIndex: 2)   // decorative
        map.setTile(x: 0, y: 2, tileIndex: 1)   // solid

        XCTAssertEqual(map.collisionBodies.count, 2)

        let offsets = Set(map.collisionBodies.map { "\($0.offset.x),\($0.offset.y)" })
        XCTAssertTrue(offsets.contains("32.0,32.0"), "Tile (0,0) center")
        XCTAssertTrue(offsets.contains("32.0,160.0"), "Tile (0,2) center")
    }

    func testEraseTileRemovesItAndItsCollider() {
        let map = TileMapNode()
        map.solidTiles = [0]
        map.setTile(x: 1, y: 1, tileIndex: 0)
        XCTAssertEqual(map.collisionBodies.count, 1)

        map.setTile(x: 1, y: 1, tileIndex: -1)
        XCTAssertNil(map.tile(x: 1, y: 1))
        XCTAssertEqual(map.collisionBodies.count, 0)
    }

    // MARK: - Animation library

    func testAnimationLibrarySaveLoadRoundTrip() {
        let clip = AnimationClip(name: "walk", gridWidth: 4, gridHeight: 2,
                                 startFrame: 4, endFrame: 7, fps: 10, loops: true)
        XCTAssertTrue(AnimationLibrary.save(clip))

        // Force a re-read from disk to prove persistence.
        AnimationLibrary.invalidate()

        let loaded = AnimationLibrary.clip(named: "walk")
        XCTAssertEqual(loaded, clip)
        XCTAssertEqual(AnimationLibrary.list(), ["walk"])
    }

    func testClipGridPositionRespectsStartFrame() {
        let clip = AnimationClip(name: "run", gridWidth: 4, gridHeight: 2,
                                 startFrame: 5, endFrame: 7, fps: 8, loops: true)
        // Frame 0 of the clip = atlas index 5 = column 1, row 1.
        let first = clip.gridPosition(frame: 0)
        XCTAssertEqual(first.column, 1)
        XCTAssertEqual(first.row, 1)
        // Frame 2 = atlas index 7 = column 3, row 1.
        let last = clip.gridPosition(frame: 2)
        XCTAssertEqual(last.column, 3)
        XCTAssertEqual(last.row, 1)
    }

    func testSpritePlaybackAdvancesFrames() {
        AnimationLibrary.save(AnimationClip(name: "spin", gridWidth: 2, gridHeight: 2,
                                            startFrame: 0, endFrame: 3, fps: 2, loops: true))

        let sprite = SpriteNode()
        sprite.playAnimation("spin")

        // After 0.6s at 2 fps → frame 1 = column 1, row 0 of a 2×2 grid
        // → uvRect (0.5, 0, 0.5, 0.5).
        sprite.update(deltaTime: 0.6, input: .shared)
        XCTAssertEqual(sprite.uvRect.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(sprite.uvRect.y, 0.0, accuracy: 0.0001)

        // After 0.6 more seconds (1.2 total) → frame 2 = column 0, row 1.
        sprite.update(deltaTime: 0.6, input: .shared)
        XCTAssertEqual(sprite.uvRect.x, 0.0, accuracy: 0.0001)
        XCTAssertEqual(sprite.uvRect.y, 0.5, accuracy: 0.0001)
    }

    func testNonLoopingClipStopsOnLastFrame() {
        AnimationLibrary.save(AnimationClip(name: "pop", gridWidth: 2, gridHeight: 1,
                                            startFrame: 0, endFrame: 1, fps: 10, loops: false))

        let sprite = SpriteNode()
        sprite.playAnimation("pop")
        XCTAssertNotNil(sprite.activeAnimation)

        sprite.update(deltaTime: 5.0, input: .shared)   // Way past the end.
        XCTAssertNil(sprite.activeAnimation, "One-shot clip finished and stopped")

        // Frozen on the last frame (column 1 of a 2×1 grid).
        XCTAssertEqual(sprite.uvRect.x, 0.5, accuracy: 0.0001)
    }

    func testDefaultAnimationAutoplaysOnReady() {
        AnimationLibrary.save(AnimationClip(name: "idle", gridWidth: 2, gridHeight: 2,
                                            startFrame: 0, endFrame: 3, fps: 4, loops: true))

        let sprite = SpriteNode()
        sprite.defaultAnimationName = "idle"

        // First update fires ready(), which starts the default clip.
        sprite.update(deltaTime: 0.016, input: .shared)
        XCTAssertEqual(sprite.activeAnimation?.name, "idle")
    }
}
