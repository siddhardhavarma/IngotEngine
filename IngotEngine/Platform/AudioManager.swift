//
//  AudioManager.swift
//  IngotEngine
//
//  Handles sound effect playback using AVAudioPlayer.
//
//  WHY AN ARRAY OF PLAYERS INSTEAD OF ONE?
//
//  AVAudioPlayer is a one-sound-at-a-time object. If you call play() on
//  a player that's already playing, it restarts from the beginning —
//  cutting off the previous sound. In a game, multiple sounds regularly
//  overlap:
//
//    - Two enemies collide on the same frame → two "bump" sounds
//    - A gunshot fires while a footstep is still playing
//    - Three coins are collected in rapid succession
//
//  Each overlapping sound needs its OWN AVAudioPlayer instance so they
//  can play concurrently without interrupting each other. The `players`
//  array holds all currently-playing instances, and we clean up finished
//  ones before each new play to keep it from growing indefinitely.
//

import AVFoundation

class AudioManager {

    /// Currently-active audio players. Each sound effect gets its own
    /// player so overlapping sounds don't cut each other off.
    var players: [AVAudioPlayer] = []

    /// Plays a sound effect from the app bundle.
    ///
    /// - Parameter fileName: The file name including extension (e.g., "bump.wav").
    func playSound(named fileName: String) {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: nil) else {
            print("AudioManager: could not find sound file '\(fileName)' in bundle.")
            return
        }
        playSound(from: url)
    }

    /// Plays a sound effect from an arbitrary file URL.
    /// Used for AI-generated audio files saved to the caches directory.
    ///
    /// - Parameter url: The file URL of the audio file to play.
    func playSound(from url: URL) {
        // Remove players that have finished playing.
        players.removeAll { !$0.isPlaying }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            players.append(player)
        } catch {
            print("AudioManager: could not play '\(url.lastPathComponent)': \(error)")
        }
    }
}
