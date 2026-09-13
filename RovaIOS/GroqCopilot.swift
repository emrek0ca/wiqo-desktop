import Foundation

/// A single step of an AI-generated plan, already translated into the exact same
/// `CommandType`/`CommandPayload` pair the manual UI buttons send. The copilot can only ever
/// produce commands from this closed set — it has no way to invent a new capability, run
/// arbitrary code, or bypass `RovaValidation` on the Mac side.
struct PlannedCommand: Identifiable {
    let id = UUID()
    let type: CommandType
    let payload: CommandPayload
    let summary: String
    let isDestructive: Bool
}

enum CopilotError: Error, LocalizedError {
    case missingAPIKey
    case network(String)
    case invalidResponse
    case emptyPlan
    case declined(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Groq API anahtarı ayarlanmamış."
        case .network(let message): return message
        case .invalidResponse: return "Groq'tan geçersiz yanıt alındı."
        case .emptyPlan: return "İstek bir Mac komutuna dönüştürülemedi."
        case .declined(let reason): return reason
        }
    }
}

/// Translates free-form natural language into a plan made only of Rova's existing, fixed
/// command set via Groq's OpenAI-compatible tool-calling API. This is the single integration
/// point for the AI layer: nothing else in the app talks to Groq, and this file never executes
/// anything itself — it only returns a `[PlannedCommand]` for the caller to run through the
/// same `IOSConnectionModel.send(_:payload:)` path the buttons already use.
enum GroqCopilot {
    /// Commands that change system/app state in a hard-to-reverse or disruptive way. A plan
    /// containing any of these must be confirmed by the user before it runs; everything else
    /// is safe to auto-execute. This mirrors exactly which manual buttons already show a
    /// confirmation dialog in IOSViews.swift.
    static let destructiveCommands: Set<CommandType> = [.lockMac, .sleepMac, .displaySleep, .quitApplication]

    private static let model = "openai/gpt-oss-120b"
    private static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private static let keychainAccount = "groq-api-key"

    static func apiKey() -> String? {
        guard let data = try? RovaKeychainStore.load(account: keychainAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveAPIKey(_ key: String) throws {
        try RovaKeychainStore.save(Data(key.utf8), account: keychainAccount)
    }

    static func clearAPIKey() {
        try? RovaKeychainStore.delete(account: keychainAccount)
    }

    static func plan(for text: String, availableApps: [ApplicationID]) async throws -> [PlannedCommand] {
        guard let key = apiKey(), !key.isEmpty else { throw CopilotError.missingAPIKey }

        let appNames = (availableApps.isEmpty ? ApplicationID.allCases : availableApps).map(\.rawValue)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt(availableApps: appNames)],
                ["role": "user", "content": text]
            ],
            "tools": toolDefinitions(appNames: appNames),
            "tool_choice": "auto",
            "temperature": 0.2
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CopilotError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CopilotError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
            throw CopilotError.network(message ?? "Groq isteği başarısız oldu (kod \(http.statusCode)).")
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let choice = decoded.choices.first else { throw CopilotError.invalidResponse }
        guard let toolCalls = choice.message.tool_calls, !toolCalls.isEmpty else {
            let reply = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reply, !reply.isEmpty { throw CopilotError.declined(reply) }
            throw CopilotError.emptyPlan
        }
        return try toolCalls.map(plannedCommand(from:))
    }

    // MARK: - Tool schema

    private static func tool(
        _ name: String,
        _ description: String,
        properties: [String: Any] = [:],
        required: [String] = []
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required
                ]
            ]
        ]
    }

    private static func toolDefinitions(appNames: [String]) -> [[String: Any]] {
        let mediaActions = MediaAction.allCases.map(\.rawValue)
        return [
            tool("lock_mac", "Mac'i kilitler, kilit ekranına döner."),
            tool("sleep_mac", "Mac'i tamamen uyku moduna alır."),
            tool("display_sleep", "Sadece Mac ekranını uyku moduna alır, sistemi kapatmaz."),
            tool(
                "set_brightness",
                "Mac ekranının parlaklığını ayarlar.",
                properties: ["level": ["type": "integer", "minimum": 0, "maximum": 100, "description": "Yüzde 0-100 parlaklık seviyesi"]],
                required: ["level"]
            ),
            tool(
                "set_volume",
                "Mac'in ses seviyesini ayarlar.",
                properties: ["level": ["type": "integer", "minimum": 0, "maximum": 100, "description": "Yüzde 0-100 ses seviyesi"]],
                required: ["level"]
            ),
            tool("toggle_mute", "Mac'in sesini açar veya kapatır (mevcut duruma göre tersine çevirir)."),
            tool(
                "media_control",
                "Mac'te çalan medyayı kontrol eder.",
                properties: ["action": ["type": "string", "enum": mediaActions, "description": "playPause, nextTrack veya previousTrack"]],
                required: ["action"]
            ),
            tool(
                "open_application",
                "Mac'te bir uygulama açar.",
                properties: ["app": ["type": "string", "enum": appNames]],
                required: ["app"]
            ),
            tool(
                "quit_application",
                "Mac'te açık bir uygulamayı kapatır.",
                properties: ["app": ["type": "string", "enum": appNames]],
                required: ["app"]
            ),
            tool(
                "open_url",
                "Mac'in varsayılan tarayıcısında bir web adresi açar.",
                properties: ["url": ["type": "string", "description": "http veya https ile başlayan tam adres"]],
                required: ["url"]
            ),
            tool(
                "set_clipboard_text",
                "Verilen metni Mac'in panosuna kopyalar.",
                properties: ["text": ["type": "string"]],
                required: ["text"]
            ),
            tool("get_system_status", "Mac'in pil, çalışma süresi ve macOS sürümü gibi sistem durumunu getirir.")
        ]
    }

    private static func systemPrompt(availableApps: [String]) -> String {
        """
        Sen Rova uygulamasının bir parçasısın. Kullanıcının iPhone'undan, eşleştirilmiş bir Mac \
        üzerinde eylem gerçekleştirmesine yardım ediyorsun.

        Kurallar:
        - Sadece sana tanımlanan araçları (tools) çağırarak eylem öner. Asla yeni bir araç, kod, \
        kabuk komutu veya AppleScript uydurma; sadece verilenleri kullan.
        - Kullanıcının isteği birden çok adım gerektiriyorsa (ör. "toplantıya hazırlan"), gereken \
        tüm araçları aynı yanıtta, doğru sırayla çağır.
        - İstek hiçbir araçla karşılanamıyorsa veya belirsizse hiçbir araç çağırma; kısaca \
        neden yapamadığını normal metinle açıkla.
        - Bu Mac'te şu an açılabilir/kapatılabilir uygulamalar: \(availableApps.joined(separator: ", ")).
        """
    }

    // MARK: - Response parsing

    private static func plannedCommand(from call: ChatCompletionResponse.Choice.Message.ToolCall) throws -> PlannedCommand {
        let argsData = Data(call.function.arguments.utf8)
        let args = (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]

        func intArg(_ key: String) -> Int? {
            if let value = args[key] as? Int { return value }
            if let value = args[key] as? Double { return Int(value) }
            if let value = args[key] as? String { return Int(value) }
            return nil
        }

        switch call.function.name {
        case "lock_mac":
            return PlannedCommand(type: .lockMac, payload: .none, summary: "Mac'i kilitle", isDestructive: true)
        case "sleep_mac":
            return PlannedCommand(type: .sleepMac, payload: .none, summary: "Mac'i uyku moduna al", isDestructive: true)
        case "display_sleep":
            return PlannedCommand(type: .displaySleep, payload: .none, summary: "Ekranı uyut", isDestructive: true)
        case "set_brightness":
            guard let level = intArg("level") else { throw CopilotError.invalidResponse }
            return PlannedCommand(type: .setBrightness, payload: .brightness(level), summary: "Parlaklığı %\(level) yap", isDestructive: false)
        case "set_volume":
            guard let level = intArg("level") else { throw CopilotError.invalidResponse }
            return PlannedCommand(type: .setVolume, payload: .volume(level), summary: "Sesi %\(level) yap", isDestructive: false)
        case "toggle_mute":
            return PlannedCommand(type: .toggleMute, payload: .none, summary: "Sesi aç/kapat", isDestructive: false)
        case "media_control":
            guard let raw = args["action"] as? String, let action = MediaAction(rawValue: raw) else {
                throw CopilotError.invalidResponse
            }
            return PlannedCommand(type: .mediaControl, payload: .media(action), summary: "Medya: \(action.rawValue)", isDestructive: false)
        case "open_application":
            guard let raw = args["app"] as? String, let app = ApplicationID(rawValue: raw) else {
                throw CopilotError.invalidResponse
            }
            return PlannedCommand(type: .openApplication, payload: .application(app), summary: "\(app.displayName) uygulamasını aç", isDestructive: false)
        case "quit_application":
            guard let raw = args["app"] as? String, let app = ApplicationID(rawValue: raw) else {
                throw CopilotError.invalidResponse
            }
            return PlannedCommand(type: .quitApplication, payload: .application(app), summary: "\(app.displayName) uygulamasını kapat", isDestructive: true)
        case "open_url":
            guard let url = args["url"] as? String, RovaValidation.isAllowedURL(url) else {
                throw CopilotError.invalidResponse
            }
            return PlannedCommand(type: .openURL, payload: .url(url), summary: "Aç: \(url)", isDestructive: false)
        case "set_clipboard_text":
            guard let text = args["text"] as? String else { throw CopilotError.invalidResponse }
            let preview = text.count > 40 ? "\(text.prefix(40))…" : text
            return PlannedCommand(type: .setClipboardText, payload: .clipboardText(text), summary: "Panoya kopyala: \(preview)", isDestructive: false)
        case "get_system_status":
            return PlannedCommand(type: .getSystemStatus, payload: .none, summary: "Sistem durumunu kontrol et", isDestructive: false)
        default:
            throw CopilotError.invalidResponse
        }
    }
}

// MARK: - Groq wire format (OpenAI-compatible chat completions)

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            struct ToolCall: Decodable {
                struct FunctionCall: Decodable {
                    let name: String
                    let arguments: String
                }
                let function: FunctionCall
            }
            let content: String?
            let tool_calls: [ToolCall]?
        }
        let message: Message
    }
    let choices: [Choice]
}

private struct ErrorEnvelope: Decodable {
    struct ErrorDetail: Decodable { let message: String }
    let error: ErrorDetail
}
