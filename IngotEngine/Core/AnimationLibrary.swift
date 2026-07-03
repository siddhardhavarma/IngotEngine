//
//  AnimationLibrary.swift
//  IngotEngine
//
//  §4.10 Animation System — Named, reusable sprite animations.
//
//  An AnimationClip describes a frame sequence within a sprite sheet
//  (grid layout, frame range, speed, looping) under a name like "walk"
//  or "explode". Clips are stored per project in animations.json and
//  are playable from:
//
//    - the Animation Editor window (authoring + preview)
//    - JavaScript:      node.playAnimation("walk")
//    - behavior rules:  the playAnimation action
//    - the AI copilot:  defineAnimation / setDefaultAnimation commands
//    - autoplay:        SpriteNode.defaultAnimationName on scene start
//
//  Foundation-only, so clips work identically in exported games (the
//  exporter bundles animations.json alongside scenes and prefabs).
//

import Foundation

/// One named sprite-sheet animation.
struct AnimationClip: Codable, Equatable {

    /// The name scripts and rules use to play this clip.
    var name: String

    /// Sprite sheet grid layout.
    var gridWidth: Int = 2
    var gridHeight: Int = 2

    /// Frame range (0-based, left-to-right then top-to-bottom, inclusive).
    var startFrame: Int = 0
    var endFrame: Int = 3

    /// Playback speed in frames per second.
    var fps: Float = 8

    /// Whether playback loops back to startFrame after endFrame.
    var loops: Bool = true

    /// Number of frames in the clip.
    var frameCount: Int { max(endFrame - startFrame + 1, 1) }

    /// The (column, row) of the n-th frame of this clip.
    func gridPosition(frame: Int) -> (column: Int, row: Int) {
        let index = startFrame + min(max(frame, 0), frameCount - 1)
        let columns = max(gridWidth, 1)
        return (index % columns, index / columns)
    }
}

/// Project-wide clip storage (mirrors PrefabLibrary's shape).
enum AnimationLibrary {

    /// In-memory clip cache, keyed by name. Loaded lazily from the
    /// project and refreshed after every save.
    private static var cache: [String: AnimationClip]?

    private static var fileURL: URL? {
        ProjectManager.shared.currentProjectURL?
            .appendingPathComponent("animations.json")
    }

    /// All clips in the project, keyed by name.
    static func clips() -> [String: AnimationClip] {
        if let cache { return cache }
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([AnimationClip].self, from: data) else {
            cache = [:]
            return [:]
        }
        let byName = Dictionary(uniqueKeysWithValues: decoded.map { ($0.name, $0) })
        cache = byName
        return byName
    }

    /// Clip names, sorted for stable UI display.
    static func list() -> [String] {
        clips().keys.sorted()
    }

    static func clip(named name: String) -> AnimationClip? {
        clips()[name]
    }

    /// Adds or replaces a clip and persists the library.
    @discardableResult
    static func save(_ clip: AnimationClip) -> Bool {
        var all = clips()
        all[clip.name] = clip
        return persist(all)
    }

    /// Removes a clip and persists the library.
    @discardableResult
    static func delete(named name: String) -> Bool {
        var all = clips()
        all.removeValue(forKey: name)
        return persist(all)
    }

    /// Drops the cache (called when switching projects).
    static func invalidate() {
        cache = nil
    }

    private static func persist(_ all: [String: AnimationClip]) -> Bool {
        guard let url = fileURL else {
            Log.warning("No project open — cannot save animations.")
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all.values.sorted { $0.name < $1.name }) else {
            return false
        }
        do {
            try data.write(to: url)
            cache = all
            return true
        } catch {
            Log.error("Could not save animations.json: \(error)")
            return false
        }
    }
}
