//
//  MusicPlayer.swift
//  IngotEngine
//
//  §4.9 Audio System — Background music streaming with looping.
//
//  Separate from AudioManager (which handles one-shot SFX) because
//  music has different lifecycle needs: only one track plays at a time,
//  it loops, it cross-fades, and it can be paused/resumed independently.
//

import AVFoundation

class MusicPlayer {

    private var player: AVAudioPlayer?

    /// The volume for music playback (0.0 – 1.0).
    var volume: Float = 0.7 {
        didSet { player?.volume = volume }
    }

    /// Whether music is currently playing.
    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Plays a music track from the app bundle or project assets.
    /// Stops any currently playing track first.
    ///
    /// - Parameters:
    ///   - fileName: The file name with extension (e.g., "theme.mp3").
    ///   - loops: Whether to loop indefinitely (-1 = infinite loop).
    func play(named fileName: String, loops: Bool = true) {
        stop()

        // Try project assets first, then app bundle.
        var url: URL?
        if let projectAssets = ProjectManager.shared.assetsURL {
            let projectFile = projectAssets.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: projectFile.path) {
                url = projectFile
            }
        }
        if url == nil {
            url = Bundle.main.url(forResource: fileName, withExtension: nil)
        }

        guard let fileURL = url else {
            Log.warning("MusicPlayer: could not find '\(fileName)'")
            return
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: fileURL)
            newPlayer.numberOfLoops = loops ? -1 : 0
            newPlayer.volume = volume
            newPlayer.play()
            player = newPlayer
        } catch {
            Log.error("MusicPlayer: could not play '\(fileName)': \(error)")
        }
    }

    /// Plays a music track from a file URL.
    func play(from url: URL, loops: Bool = true) {
        stop()

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.numberOfLoops = loops ? -1 : 0
            newPlayer.volume = volume
            newPlayer.play()
            player = newPlayer
        } catch {
            Log.error("MusicPlayer: could not play '\(url.lastPathComponent)': \(error)")
        }
    }

    /// Stops the current track.
    func stop() {
        player?.stop()
        player = nil
    }

    /// Pauses the current track (can be resumed).
    func pause() {
        player?.pause()
    }

    /// Resumes a paused track.
    func resume() {
        player?.play()
    }
}
