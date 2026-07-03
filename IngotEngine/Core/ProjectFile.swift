//
//  ProjectFile.swift
//  IngotEngine
//
//  §7 Data Model — The project file format.
//
//  A project file (project.json) is the top-level manifest that
//  describes a game. It lives at the root of the project directory
//  alongside the Assets/, Scenes/, and Scripts/ folders.
//
//  The editor writes this on save; the runtime reads it on load.
//  This is the contract between editor and runtime (§7 design rule).
//

import Foundation

/// The root structure of a project file.
struct ProjectFile: Codable {

    /// The human-readable game name (shown in title bar, export).
    var gameName: String = "Untitled Game"

    /// The scene file loaded when the game starts (e.g., "MainScene").
    var entryScene: String = "MainScene"

    /// The scene that was open in the editor last session — the editor
    /// reopens it on launch (Godot-style session restore). Optional so
    /// project.json files written before this field decode cleanly.
    var lastOpenedScene: String?

    /// Target screen resolution (the "design size" for the game).
    var designWidth: Int = 800
    var designHeight: Int = 600

    /// Registry of all assets in the project, keyed by ID.
    var assets: [AssetEntry] = []

    /// Registry of all scenes in the project.
    var scenes: [String] = []
}

/// An entry in the asset registry.
struct AssetEntry: Codable {

    /// Unique identifier for this asset (used in node references).
    let id: String

    /// File path relative to the project directory (e.g., "Assets/player.png").
    let path: String

    /// The type of asset.
    let type: AssetType

    enum AssetType: String, Codable {
        case texture
        case sound
        case music
        case script
    }
}
