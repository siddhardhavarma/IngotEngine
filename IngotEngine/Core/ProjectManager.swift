//
//  ProjectManager.swift
//  IngotEngine
//
//  §5.2 / §7 — Project & asset management.
//
//  Manages the on-disk project workspace:
//
//    MyGame/
//    ├── project.json    ← game settings, entry scene, asset registry
//    ├── Assets/         ← textures, audio (imported and AI-generated)
//    ├── Scenes/         ← serialized scene JSON files
//    └── Scripts/        ← JavaScript lifecycle component files
//

import Foundation

class ProjectManager {

    static let shared = ProjectManager()

    /// The root directory of the currently open project.
    var currentProjectURL: URL?

    /// The in-memory project file (settings, asset registry, scene list).
    var projectFile = ProjectFile()

    /// Whether the project has unsaved changes.
    var isDirty: Bool = false

    // MARK: - Directory accessors

    var assetsURL: URL? { currentProjectURL?.appendingPathComponent("Assets") }
    var scenesURL: URL? { currentProjectURL?.appendingPathComponent("Scenes") }
    var scriptsURL: URL? { currentProjectURL?.appendingPathComponent("Scripts") }
    var prefabsURL: URL? { currentProjectURL?.appendingPathComponent("Prefabs") }

    private init() {}

    // MARK: - Project lifecycle

    /// Opens (or creates) a project at the given directory.
    func createOrOpenProject(at url: URL) {
        let fm = FileManager.default

        // Create subdirectories if missing.
        for subdir in ["Assets", "Scenes", "Scripts", "Prefabs"] {
            let dir = url.appendingPathComponent(subdir)
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }

        currentProjectURL = url

        // Per-project caches must not leak across projects.
        AnimationLibrary.invalidate()
        TileSetLibrary.invalidate()

        // Load existing project.json, or create a default one.
        let projectFileURL = url.appendingPathComponent("project.json")
        if fm.fileExists(atPath: projectFileURL.path),
           let data = try? Data(contentsOf: projectFileURL),
           let loaded = try? JSONDecoder().decode(ProjectFile.self, from: data) {
            projectFile = loaded
            Log.info("Opened project: \(loaded.gameName)")
        } else {
            projectFile = ProjectFile()
            projectFile.gameName = url.lastPathComponent
            saveProjectFile()
            Log.info("Created new project: \(projectFile.gameName)")
        }

        isDirty = false
    }

    /// Saves the project.json manifest to disk.
    func saveProjectFile() {
        guard let url = currentProjectURL else { return }

        let fileURL = url.appendingPathComponent("project.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(projectFile)
            try data.write(to: fileURL)
        } catch {
            Log.error("Could not save project.json: \(error)")
        }
    }

    // MARK: - Scene persistence

    /// Saves a scene to the Scenes/ directory as a JSON file.
    func saveScene(_ scene: Scene, named name: String) {
        guard let scenesDir = scenesURL else {
            Log.warning("No project open, cannot save scene.")
            return
        }

        let json = SceneSerializer.serialize(scene)
        let fileURL = scenesDir.appendingPathComponent("\(name).json")

        do {
            try json.write(to: fileURL, atomically: true, encoding: .utf8)
            Log.info("Saved scene: \(name)")

            // Add to the project's scene list if not already there.
            if !projectFile.scenes.contains(name) {
                projectFile.scenes.append(name)
                saveProjectFile()
            }

            isDirty = false
        } catch {
            Log.error("Could not save scene '\(name)': \(error)")
        }
    }

    /// Loads a scene from the Scenes/ directory.
    /// Returns the deserialized root node, or nil on failure.
    func loadScene(named name: String) -> (rootNode: Node, json: String)? {
        guard let scenesDir = scenesURL else {
            Log.warning("No project open, cannot load scene.")
            return nil
        }

        let fileURL = scenesDir.appendingPathComponent("\(name).json")
        guard let json = try? String(contentsOf: fileURL, encoding: .utf8) else {
            Log.warning("Could not read scene file: \(name).json")
            return nil
        }

        guard let rootNode = SceneDeserializer.deserialize(jsonString: json) else {
            Log.error("Could not deserialize scene: \(name)")
            return nil
        }

        Log.info("Loaded scene: \(name)")
        return (rootNode, json)
    }

    /// Lists all scene names in the Scenes/ directory.
    func listScenes() -> [String] {
        guard let scenesDir = scenesURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: scenesDir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
              ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    // MARK: - Script management

    /// Creates a boilerplate JS lifecycle script in the Scripts/ folder.
    @discardableResult
    func createScriptFile(named name: String, code: String? = nil) -> URL? {
        guard let scriptsDir = scriptsURL else { return nil }

        let fileName = name.hasSuffix(".js") ? name : "\(name).js"
        let fileURL = scriptsDir.appendingPathComponent(fileName)

        // Don't overwrite existing files.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        let content = code ?? """
        var Script = {
            start: function(node) {
                // Called once when the behavior starts.
            },
            update: function(node, dt, time) {
                // Called every frame.
            }
        };
        """

        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        Log.info("Created script: \(fileName)")
        return fileURL
    }

    /// Lists all script files in the Scripts/ directory.
    func listScripts() -> [String] {
        guard let scriptsDir = scriptsURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: scriptsDir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
              ) else { return [] }

        return files
            .filter { $0.pathExtension == "js" }
            .map { $0.lastPathComponent }
            .sorted()
    }

    // MARK: - Asset management

    /// Registers an asset in the project's asset registry.
    func registerAsset(id: String, path: String, type: AssetEntry.AssetType) {
        // Don't duplicate.
        if projectFile.assets.contains(where: { $0.id == id }) { return }

        projectFile.assets.append(AssetEntry(id: id, path: path, type: type))
        saveProjectFile()
        isDirty = true
    }

    /// Lists all assets of a given type.
    func assets(ofType type: AssetEntry.AssetType) -> [AssetEntry] {
        return projectFile.assets.filter { $0.type == type }
    }

    /// Marks the project as having unsaved changes.
    func markDirty() {
        isDirty = true
    }
}
