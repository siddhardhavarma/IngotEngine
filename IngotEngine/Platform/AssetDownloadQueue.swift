//
//  AssetDownloadQueue.swift
//  IngotEngine
//
//  Manages asynchronous asset generation requests (textures, audio)
//  so they run entirely on background threads and never block the
//  main thread's 60 FPS render loop.
//
//  HOW THE THREAD SWAPPING WORKS:
//
//  The Metal render loop runs on the main thread. Every 16.6ms it must:
//    1. Read node positions → 2. Build instance data → 3. Submit GPU work
//
//  If we awaited a 3-second DALL-E API call on the main thread, the
//  render loop would freeze for 3 seconds — no frames drawn, the app
//  appears hung.
//
//  The solution is a 3-step thread dance:
//
//    Step 1 (MainActor): Assign placeholder texture → instant visual feedback
//                        This takes microseconds. The render loop continues.
//
//    Step 2 (Background): Network request to DALL-E / ElevenLabs
//                         Takes 2-10 seconds. Happens on a background thread.
//                         The main thread is COMPLETELY FREE during this time.
//                         The render loop keeps drawing at 60 FPS — the sprite
//                         just shows the gray placeholder.
//
//    Step 3 (MainActor): Swap placeholder for real texture
//                        The next frame draws the real art. Seamless.
//
//  The user sees: gray box appears instantly → game keeps running →
//  real art pops in when ready. No stutter, no freeze.
//

import Foundation
import MetalKit

class AssetDownloadQueue {

    /// The asset generator that performs the actual API calls.
    private let generator: AssetGenerator

    /// The audio manager for playing generated sounds.
    private let audioManager: AudioManager

    /// The Metal device, used to create placeholder textures.
    private let device: MTLDevice

    init(generator: AssetGenerator, audioManager: AudioManager, device: MTLDevice) {
        self.generator = generator
        self.audioManager = audioManager
        self.device = device
    }

    // MARK: - Texture Generation

    /// Dispatches an asynchronous texture generation request.
    ///
    /// 1. Immediately assigns a placeholder texture (MainActor)
    /// 2. Spawns a background task to call the image API
    /// 3. On completion, swaps in the real texture (MainActor)
    ///
    /// - Parameters:
    ///   - node: The SpriteNode to update.
    ///   - prompt: The image description for the AI.
    ///   - apiKey: The API key for the image service.
    ///   - onLog: Callback for status messages (fed to the chat panel).
    func dispatchTextureGeneration(for node: SpriteNode,
                                   prompt: String,
                                   apiKey: String,
                                   onLog: @escaping @MainActor (String) -> Void) {

        let nodeName = node.name

        // --- Step 1: Assign placeholder on the main thread (instant) ---
        node.texture = SpriteNode.placeholderTexture(device: device)
        node.isLoadingTexture = true

        // Capture what we need for the background task.
        let generator = self.generator

        // --- Step 2: Spawn background work for the network request ---
        Task.detached(priority: .userInitiated) {
            do {
                // This runs on a background thread. The main thread is free
                // to keep rendering at 60 FPS with the placeholder showing.
                let result = try await generator.generateImage(
                    prompt: prompt,
                    apiKey: apiKey
                )

                // --- Step 3: Swap in the real texture on the main thread ---
                await MainActor.run {
                    if let result {
                        node.texture = result.texture
                        // Record the Assets/ file so the texture survives
                        // save/load and rides into exports — same contract
                        // as Asset Library assignments.
                        node.textureName = result.fileName
                        node.isLoadingTexture = false
                        onLog("Texture applied to \"\(nodeName)\" (saved as \(result.fileName)).")
                    } else {
                        // API returned nil — keep the placeholder so the
                        // node stays visible rather than disappearing.
                        node.isLoadingTexture = false
                        onLog("Warning: Image generation for \"\(nodeName)\" returned nil. Placeholder retained.")
                    }
                }
            } catch {
                // Network failure, timeout, invalid response, etc.
                // The placeholder stays intact — the sprite doesn't vanish.
                await MainActor.run {
                    node.isLoadingTexture = false
                    onLog("Error generating texture for \"\(nodeName)\": \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Sound Generation

    /// Dispatches an asynchronous sound generation request.
    ///
    /// Spawns a background task to call the audio API, then plays the
    /// result on the main thread when ready.
    ///
    /// - Parameters:
    ///   - prompt: The sound description for the AI.
    ///   - apiKey: The API key for the audio service.
    ///   - onLog: Callback for status messages.
    func dispatchSoundGeneration(prompt: String,
                                 apiKey: String,
                                 onLog: @escaping @MainActor (String) -> Void) {

        let generator = self.generator
        let audioManager = self.audioManager

        Task.detached(priority: .userInitiated) {
            do {
                let fileURL = try await generator.generateSound(
                    prompt: prompt,
                    apiKey: apiKey
                )

                await MainActor.run {
                    if let url = fileURL {
                        audioManager.playSound(from: url)
                        onLog("Sound generated and playing.")
                    } else {
                        onLog("Warning: Sound generation returned nil.")
                    }
                }
            } catch {
                await MainActor.run {
                    onLog("Error generating sound: \(error.localizedDescription)")
                }
            }
        }
    }
}
