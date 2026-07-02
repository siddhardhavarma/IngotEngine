//
//  AIConfiguration.swift
//  IngotEngine
//
//  Configuration for the AI copilot: which LLM provider to use, which
//  model ID to call, and API keys for each service.
//
//  Persistence follows the standard split:
//    - Secrets (API keys) → the macOS Keychain (KeychainStore)
//    - Preferences (provider, model IDs) → UserDefaults
//
//  Model IDs are user-editable in the AI Settings panel, so new models
//  can be adopted the day they ship without an engine update.
//

import Foundation

/// The LLM providers the engine can talk to.
enum AIProvider: String, CaseIterable {
    case local    // No network — mock/local inference
    case openAI   // OpenAI / Chat Completions API
    case claude   // Anthropic Claude / Messages API
    case gemini   // Google Gemini / GenerateContent API

    var displayName: String {
        switch self {
        case .local:  return "Local (offline)"
        case .openAI: return "OpenAI"
        case .claude: return "Anthropic Claude"
        case .gemini: return "Google Gemini"
        }
    }
}

/// Holds the selected provider, model IDs, and API keys for all services.
struct AISettings {

    var provider: AIProvider = .local

    // --- Model IDs (editable in AI Settings; defaults track the
    //     current recommended model for each provider) ---
    var openAIModel: String = "gpt-4o"
    var claudeModel: String = "claude-sonnet-5"
    var geminiModel: String = "gemini-2.5-flash"

    // --- LLM API keys (Keychain-backed, never written to disk) ---
    var openAIKey: String = ""
    var claudeKey: String = ""
    var geminiKey: String = ""

    // --- Asset generation API keys ---
    var elevenLabsKey: String = ""

    /// The model ID for the currently selected provider.
    var activeModel: String {
        switch provider {
        case .local:  return "local"
        case .openAI: return openAIModel
        case .claude: return claudeModel
        case .gemini: return geminiModel
        }
    }

    /// Whether the selected provider has the key it needs.
    var isConfigured: Bool {
        switch provider {
        case .local:  return true
        case .openAI: return !openAIKey.isEmpty
        case .claude: return !claudeKey.isEmpty
        case .gemini: return !geminiKey.isEmpty
        }
    }

    // MARK: - Persistence

    private enum DefaultsKey {
        static let provider = "AIProvider"
        static let openAIModel = "AIOpenAIModel"
        static let claudeModel = "AIClaudeModel"
        static let geminiModel = "AIGeminiModel"
    }

    private enum SecretKey {
        static let openAI = "openai-api-key"
        static let claude = "claude-api-key"
        static let gemini = "gemini-api-key"
        static let elevenLabs = "elevenlabs-api-key"
    }

    /// Loads settings: preferences from UserDefaults, keys from Keychain.
    static func load() -> AISettings {
        var settings = AISettings()
        let defaults = UserDefaults.standard

        if let raw = defaults.string(forKey: DefaultsKey.provider),
           let provider = AIProvider(rawValue: raw) {
            settings.provider = provider
        }
        if let model = defaults.string(forKey: DefaultsKey.openAIModel) { settings.openAIModel = model }
        if let model = defaults.string(forKey: DefaultsKey.claudeModel) { settings.claudeModel = model }
        if let model = defaults.string(forKey: DefaultsKey.geminiModel) { settings.geminiModel = model }

        settings.openAIKey = KeychainStore.get(SecretKey.openAI) ?? ""
        settings.claudeKey = KeychainStore.get(SecretKey.claude) ?? ""
        settings.geminiKey = KeychainStore.get(SecretKey.gemini) ?? ""
        settings.elevenLabsKey = KeychainStore.get(SecretKey.elevenLabs) ?? ""

        return settings
    }

    /// Persists settings: preferences to UserDefaults, keys to Keychain.
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(provider.rawValue, forKey: DefaultsKey.provider)
        defaults.set(openAIModel, forKey: DefaultsKey.openAIModel)
        defaults.set(claudeModel, forKey: DefaultsKey.claudeModel)
        defaults.set(geminiModel, forKey: DefaultsKey.geminiModel)

        KeychainStore.set(openAIKey, forKey: SecretKey.openAI)
        KeychainStore.set(claudeKey, forKey: SecretKey.claude)
        KeychainStore.set(geminiKey, forKey: SecretKey.gemini)
        KeychainStore.set(elevenLabsKey, forKey: SecretKey.elevenLabs)
    }
}
