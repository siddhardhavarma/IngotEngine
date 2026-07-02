//
//  AssetGenerator.swift
//  IngotEngine
//
//  Generates game assets (textures, audio) by calling external AI APIs.
//  Saves generated files to the current project's Assets/ directory
//  (or caches as a fallback).
//

import Foundation
import MetalKit
import AVFoundation

class AssetGenerator {

    private let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
    }

    /// Returns the directory to save generated assets into.
    /// Uses the project's Assets/ folder if available, otherwise caches.
    private var saveDirectory: URL {
        if let projectAssets = ProjectManager.shared.assetsURL {
            return projectAssets
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }

    // MARK: - Image Generation

    func generateImage(prompt: String, apiKey: String) async throws -> MTLTexture? {
        let url = URL(string: "https://api.openai.com/v1/images/generations")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "dall-e-3",
            "prompt": prompt,
            "n": 1,
            "size": "256x256",
            "response_format": "b64_json"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            print("AssetGenerator: Image API returned status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            return nil
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let b64String = dataArray.first?["b64_json"] as? String,
              let imageData = Data(base64Encoded: b64String) else {
            print("AssetGenerator: Could not parse image response.")
            return nil
        }

        // Save the image to the project Assets/ folder.
        let fileName = "generated_\(UUID().uuidString).png"
        let fileURL = saveDirectory.appendingPathComponent(fileName)
        try? imageData.write(to: fileURL)
        print("AssetGenerator: Saved image to \(fileURL.path)")

        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: any Sendable] = [
            .SRGB: false as NSNumber,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
        ]
        let texture = try await loader.newTexture(data: imageData, options: options)

        return texture
    }

    // MARK: - Sound Generation

    func generateSound(prompt: String, apiKey: String) async throws -> URL? {
        let url = URL(string: "https://api.elevenlabs.io/v1/sound-generation")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": prompt,
            "duration_seconds": 2.0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            print("AssetGenerator: Sound API returned status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            return nil
        }

        // Save to the project Assets/ folder.
        let fileName = "generated_\(UUID().uuidString).mp3"
        let fileURL = saveDirectory.appendingPathComponent(fileName)
        try data.write(to: fileURL)
        print("AssetGenerator: Saved audio to \(fileURL.path)")

        return fileURL
    }
}
