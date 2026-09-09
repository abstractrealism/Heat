import Foundation
import GenKit
import SharedKit

extension Defaults {

    public static let anthropic =
        Service(
            kind: .anthropic,
            name: "Anthropic",
            host: "https://api.anthropic.com/v1"
        )

    public static let deepseek =
        Service(
            kind: .deepseek,
            name: "DeepSeek",
            host: "https://api.deepseek.com/v1"
        )

    public static let elevenlabs =
        Service(
            kind: .elevenLabs,
            name: "ElevenLabs",
            host: "https://api.elevenlabs.io/v1"
        )

    public static let fal =
        Service(
            kind: .fal,
            name: "Fal",
            host: "https://fal.run/fal-ai"
        )

    public static let grok =
        Service(
            kind: .grok,
            name: "Grok",
            host: "https://api.x.ai/v1"
        )

    public static let groq =
        Service(
            kind: .groq,
            name: "Groq",
            host: "https://api.groq.com/openai/v1"
        )

    public static let mistral =
        Service(
            kind: .mistral,
            name: "Mistral",
            host: "https://api.mistral.ai/v1"
        )

    public static let ollama =
        Service(
            kind: .ollama,
            name: "Ollama",
            host: "http://127.0.0.1:11434/api"
        )

    public static let openAI =
        Service(
            kind: .openAI,
            name: "OpenAI",
            host: "https://api.openai.com/v1"
        )
}
