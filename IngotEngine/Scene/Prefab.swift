//
//  Prefab.swift
//  IngotEngine
//
//  §7 Data Model — Reusable scene fragments (prefabs).
//
//  Modeled after Godot's PackedScene. A prefab is a serialized node
//  subtree stored as JSON in the project's Prefabs/ directory. Any node
//  (with its children, behaviors, physics body, and type-specific
//  properties) can be saved as a prefab and instantiated any number of
//  times — by the editor, by AI commands, or at runtime from behavior
//  rules (the spawnPrefab action).
//

import Foundation

enum PrefabLibrary {

    /// Saves a node subtree as a named prefab in the project.
    /// Returns true on success.
    @discardableResult
    static func save(_ node: Node, named name: String) -> Bool {
        guard let dir = ProjectManager.shared.prefabsURL else {
            Log.warning("No project open, cannot save prefab \"\(name)\".")
            return false
        }

        let json = SceneSerializer.serializeSubtree(node)
        let fileURL = dir.appendingPathComponent("\(name).json")
        do {
            try json.write(to: fileURL, atomically: true, encoding: .utf8)
            Log.info("Saved prefab: \(name)")
            return true
        } catch {
            Log.error("Could not save prefab \"\(name)\": \(error)")
            return false
        }
    }

    /// Instantiates a fresh copy of a named prefab.
    /// Each call returns a brand-new node tree (never shared references).
    static func instantiate(named name: String) -> Node? {
        guard let dir = ProjectManager.shared.prefabsURL else {
            Log.warning("No project open, cannot load prefab \"\(name)\".")
            return nil
        }

        let fileURL = dir.appendingPathComponent("\(name).json")
        guard let json = try? String(contentsOf: fileURL, encoding: .utf8) else {
            Log.warning("Prefab not found: \(name)")
            return nil
        }

        return SceneDeserializer.deserialize(jsonString: json)
    }

    /// Lists all prefab names in the project.
    static func list() -> [String] {
        guard let dir = ProjectManager.shared.prefabsURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
              ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}

extension Node {

    /// Returns a deep copy of this node and its whole subtree, made via
    /// a serialize → deserialize round trip (Godot's duplicate()).
    /// Textures are not carried over (they aren't JSON-serializable);
    /// the editor re-assigns its default texture to fresh copies.
    func duplicate() -> Node? {
        let json = SceneSerializer.serializeSubtree(self)
        return SceneDeserializer.deserialize(jsonString: json)
    }
}
