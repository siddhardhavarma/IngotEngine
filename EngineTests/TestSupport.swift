//
//  TestSupport.swift
//  EngineTests
//
//  Shared helpers: every test that touches disk (prefabs, animations,
//  scenes) runs against a throwaway project in the temp directory so
//  tests never interfere with each other or with a real project.
//

import Foundation
@testable import IngotEngineCore

enum TestSupport {

    /// Points ProjectManager at a fresh temp project and clears
    /// cross-test singleton state. Returns the project directory.
    @discardableResult
    static func openTempProject() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IngotEngineTests-\(UUID().uuidString)")
        ProjectManager.shared.createOrOpenProject(at: dir)
        AnimationLibrary.invalidate()
        TileSetLibrary.invalidate()
        InputManager.shared.clearAllActions()
        return dir
    }

    /// A unique signal name per call, since EventBus listeners are
    /// global and never disconnect.
    static func uniqueSignal(_ base: String) -> String {
        "\(base)-\(UUID().uuidString.prefix(8))"
    }
}
