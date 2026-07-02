//
//  AIConfiguration.swift
//  IngotEngine
//
//  Configuration for the AI copilot: which LLM provider to use and
//  API keys for each service.
//

import Foundation

/// The LLM providers the engine can talk to.
enum AIProvider: String, CaseIterable {
    case local    // No network — mock/local inference
    case openAI   // OpenAI GPT-4o / ChatCompletions API
    case claude   // Anthropic Claude / Messages API
    case gemini   // Google Gemini / GenerateContent API
}

/// Holds the selected provider and API keys for all services.
/// In a real app, keys would come from a settings UI or keychain.
struct AISettings {
    var provider: AIProvider = .local

    // --- LLM API keys ---
    var openAIKey: String = ""
    var claudeKey: String = ""
    var geminiKey: String = ""

    // --- Asset generation API keys ---
    var elevenLabsKey: String = ""
}
