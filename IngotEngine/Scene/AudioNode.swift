//
//  AudioNode.swift
//  IngotEngine
//
//  §4.4 Scene System — A sound source positioned in the scene.
//
//  AudioNode represents a point in the world that can play sounds.
//  It can be triggered via behaviors, signals, or scripts.
//
//  Future: distance-based volume attenuation relative to the camera
//  for spatial audio effects.
//

import Foundation

class AudioNode: Node {

    /// The sound file to play (from Assets/ or the app bundle).
    var soundFile: String = ""

    /// Whether this sound plays automatically when the scene starts.
    var playOnStart: Bool = false

    /// Whether the sound should loop.
    var loops: Bool = false

    /// Volume (0.0 – 1.0).
    var volume: Float = 1.0

    override init() {
        super.init()
        name = "Audio"
    }

    /// Plays the sound via the global AudioManager.
    func play() {
        guard !soundFile.isEmpty else { return }

        // Try the project assets directory first.
        if let assetsDir = ProjectManager.shared.assetsURL {
            let url = assetsDir.appendingPathComponent(soundFile)
            if FileManager.default.fileExists(atPath: url.path) {
                AudioManager().playSound(from: url)
                return
            }
        }

        // Fall back to the app bundle.
        AudioManager().playSound(named: soundFile)
    }

    override func ready() {
        super.ready()
        if playOnStart {
            play()
        }
    }
}
