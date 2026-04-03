/*
 * Vision API Service for Anthropic Claude
 * Provides image recognition using Claude Sonnet model
 */

import Foundation
import UIKit

struct VisionAPIService {
    // API Configuration
    private let apiKey: String
    private var baseURL: String { VisionAPIConfig.baseURL }
    private let model = "claude-sonnet-4-20250514"

    private let systemPrompt = "你是 Meta 智能眼镜的中文AI助手。用简洁的中文回答，像跟朋友说话一样自然。控制在3句话以内，因为回复会被语音朗读。"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - API Request/Response Models

    struct ClaudeRequest: Encodable {
        let model: String
        let max_tokens: Int
        let system: String?
        let messages: [Message]

        struct Message: Encodable {
            let role: String
            let content: [Content]
        }
    }

    // Content uses enum to handle different types cleanly
    enum Content: Encodable {
        case text(String)
        case image(mediaType: String, data: String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let mediaType, let data):
                try container.encode("image", forKey: .type)
                var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                try source.encode("base64", forKey: .type)
                try source.encode(mediaType, forKey: .mediaType)
                try source.encode(data, forKey: .data)
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, text, source
        }
        enum SourceKeys: String, CodingKey {
            case type
            case mediaType = "media_type"
            case data
        }
    }

    struct ClaudeResponse: Decodable {
        let content: [ContentBlock]

        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
    }

    // MARK: - Public Methods

    /// Analyze image and get description
    func analyzeImage(_ image: UIImage, prompt: String = "图中描绘的是什么景象?") async throws -> String {
        // Convert image to base64
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw VisionAPIError.invalidImage
        }

        let base64String = imageData.base64EncodedString()

        // Create request
        let request = ClaudeRequest(
            model: model,
            max_tokens: 1024,
            system: systemPrompt,
            messages: [
                ClaudeRequest.Message(
                    role: "user",
                    content: [
                        .image(mediaType: "image/jpeg", data: base64String),
                        .text(prompt)
                    ]
                )
            ]
        )

        // Make API call
        let response = try await makeRequest(request)

        guard let firstText = response.content.first(where: { $0.type == "text" })?.text else {
            throw VisionAPIError.emptyResponse
        }

        return firstText
    }

    // MARK: - Private Methods

    private func makeRequest(_ request: ClaudeRequest) async throws -> ClaudeResponse {
        let url = URL(string: "\(baseURL)/messages")!

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VisionAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw VisionAPIError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(ClaudeResponse.self, from: data)
    }
}

// MARK: - Error Types

enum VisionAPIError: LocalizedError {
    case invalidImage
    case emptyResponse
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无法处理图片"
        case .emptyResponse:
            return "API 返回空响应"
        case .invalidResponse:
            return "无效的响应格式"
        case .apiError(let statusCode, let message):
            return "API 错误 (\(statusCode)): \(message)"
        }
    }
}
