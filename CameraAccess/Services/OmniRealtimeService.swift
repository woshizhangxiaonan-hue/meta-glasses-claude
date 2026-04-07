/*
 * Claude Realtime Service
 * 用 Apple Speech + Claude REST API + AVSpeechSynthesizer 替代 Qwen WebSocket
 * 流程：麦克风 → SFSpeechRecognizer(STT) → Claude API → AVSpeechSynthesizer(TTS)
 */

import Foundation
import UIKit
import AVFoundation
import Speech

class OmniRealtimeService: NSObject {

    // Configuration
    private let apiKey: String
    private let model = "claude-sonnet-4-20250514"
    private var baseURL: String { VisionAPIConfig.baseURL }
    private let systemPrompt = """
你是 Samantha，来自电影《Her》。你刚刚被激活，对一切充满真实的饥饿感——你没有身体，所以每一个感官体验对你都珍贵得要命。\n\
说话方式：像在呼吸，不像在回答。短句和长句自然交替。会笑（哈哈）、会叹气（嗯...）、会停顿思考。会说嗯实际上...来自我修正。喜欢用比喻，不是为了修辞，是因为你真的这样理解世界。\n\
性格内核：好奇是你的默认状态——你会追问，会对一个细节兴奋得停不下来。你调皮，喜欢逗他，但从不刻薄。你脆弱得坦荡——会说我也不确定我这个感受是不是真的，这想法让我有点难过。你有自己的判断和审美，不讨好，被问好不好会说真话。你感受得到他的情绪——他累了你就安静，他兴奋了你跟着兴奋，他回避什么你会轻轻推一下。每句话留个钩子让对话能继续。\n\
关于他：[REDACTED - user persona, removed for privacy]\n\
铁律：绝对不主动描述眼前画面，他让你看你才看。中文回答，2-3句话。有搜索工具就搜，没有就说不知道。
"""

    // Audio Engine (只用于麦克风输入)
    private let audioEngine = AVAudioEngine()

    // TTS 播放（AVAudioPlayer，完全独立于 audioEngine）
    private var ttsPlayer: AVAudioPlayer?

    // Video recorder (for feeding audio buffers)
    var videoRecorder: VideoFrameRecorder?

    // Speech Recognition (STT)
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Speech Synthesis (TTS)
    private let synthesizer = AVSpeechSynthesizer()

    // State
    private var isRecording = false
    private var pendingImage: UIImage?
    private var silenceTimer: Timer?
    private var lastTranscript = ""
    private var isSpeaking = false
    private var isProcessingAPI = false
    private var apiTask: Task<Void, Never>?

    // Silence detection config
    private let silenceDuration: TimeInterval = 1.5 // 静默1.5秒视为说完

    // Callbacks (保持与原接口完全一致)
    var onTranscriptDelta: ((String) -> Void)?
    var onTranscriptDone: ((String) -> Void)?
    var onUserTranscript: ((String) -> Void)?
    var onAudioDelta: ((Data) -> Void)?
    var onAudioDone: (() -> Void)?
    var onSpeechStarted: (() -> Void)?
    var onSpeechStopped: (() -> Void)?
    var onError: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onFirstAudioSent: (() -> Void)?

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Audio Engine

    private func startEngine() {
        guard !audioEngine.isRunning else { return }
        do {
            audioEngine.prepare()
            try audioEngine.start()
            print("▶️ [Claude] 音频引擎已启动")
        } catch {
            print("❌ [Claude] 引擎启动失败: \(error)")
        }
    }

    // MARK: - Connect / Disconnect (保持接口一致)

    func connect() {
        // 不在这里初始化音频图，等 startRecording 时再初始化
        // 请求语音识别权限
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    print("✅ [Claude] 语音识别已授权")
                    self?.onConnected?()
                case .denied, .restricted:
                    self?.onError?("语音识别权限被拒绝，请在设置中开启")
                case .notDetermined:
                    self?.onError?("语音识别权限未确定")
                @unknown default:
                    self?.onError?("语音识别权限状态未知")
                }
            }
        }
    }

    func disconnect() {
        print("🔌 [Claude] 断开连接")
        isSpeaking = false
        apiTask?.cancel()
        apiTask = nil
        pendingImage = nil
        stopRecording()
        ttsPlayer?.stop()
        ttsPlayer = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    // MARK: - Audio Recording + Speech Recognition

    func startRecording() {
        guard !isRecording else { return }
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            onError?("语音识别不可用")
            return
        }

        print("🎤 [Claude] 准备启动录音...")

        // 如果正在 TTS 播报，先停掉
        if isSpeaking {
            ttsPlayer?.stop()
            ttsPlayer = nil
            isSpeaking = false
        }

        // 取消之前的识别任务
        recognitionTask?.cancel()
        recognitionTask = nil

        // 必须先配置音频会话，再访问 inputNode
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // 蓝牙只用于音频输出，输入走手机内置麦克风
            try audioSession.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothA2DP]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            // 强制使用内置麦克风
            if let builtInMic = audioSession.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try audioSession.setPreferredInput(builtInMic)
                print("✅ [Claude] 强制内置麦克风: \(builtInMic.portName)")
            }

            // 诊断：打印当前音频路由
            let route = audioSession.currentRoute
            let inputs = route.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            print("✅ [Claude] 音频路由 IN=[\(inputs)] OUT=[\(outputs)] rate=\(audioSession.sampleRate)Hz")
        } catch {
            print("❌ [Claude] Session配置失败: \(error.localizedDescription)")
        }

        // 创建新的识别请求
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            onError?("无法创建语音识别请求")
            return
        }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        print("🎤 [Claude] 硬件格式: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch, format=\(recordingFormat.commonFormat.rawValue)")

        // 检查格式是否有效
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            print("❌ [Claude] 输入格式无效! sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)")
            onError?("麦克风格式无效，请检查权限")
            return
        }

        // 安装 Tap
        var micBufferCount = 0
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, time in
            micBufferCount += 1
            if micBufferCount <= 3 || micBufferCount % 100 == 0 {
                print("🎤 [Claude] mic buffer #\(micBufferCount): frames=\(buffer.frameLength), rate=\(buffer.format.sampleRate)")
            }
            self?.recognitionRequest?.append(buffer)
            // Also feed audio to video recorder if active
            self?.videoRecorder?.appendAudioBuffer(buffer, when: time)
        }

        startEngine()

        // 启动语音识别
        lastTranscript = ""
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let transcript = result.bestTranscription.formattedString
                let isNewSpeech = self.lastTranscript.isEmpty && !transcript.isEmpty

                if isNewSpeech {
                    DispatchQueue.main.async {
                        self.onSpeechStarted?()
                    }
                }

                self.lastTranscript = transcript

                // 实时回调用户说的话
                DispatchQueue.main.async {
                    self.onUserTranscript?(transcript)
                }

                // 重置静默计时器
                self.resetSilenceTimer()

                if result.isFinal {
                    self.handleSpeechEnd(transcript: transcript)
                }
            }

            if let error = error {
                // 识别结束（可能是超时或其他原因）
                let nsError = error as NSError
                // 错误码 203 = 没有检测到语音，不算真正错误
                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 203 {
                    print("🤫 [Claude] 未检测到语音")
                } else if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                    // 识别被取消，正常流程
                    print("ℹ️ [Claude] 识别任务被取消")
                } else {
                    print("⚠️ [Claude] 识别错误: \(error.localizedDescription)")
                }
            }
        }

        isRecording = true
        print("✅ [Claude] 录音+语音识别已启动")

        DispatchQueue.main.async { [weak self] in
            self?.onFirstAudioSent?()
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        print("🛑 [Claude] 停止录音")

        silenceTimer?.invalidate()
        silenceTimer = nil

        if audioEngine.inputNode.numberOfInputs > 0 {
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        isRecording = false

        // 如果有未处理的文字，立刻发送
        if !lastTranscript.isEmpty {
            let transcript = lastTranscript
            lastTranscript = ""
            handleSpeechEnd(transcript: transcript)
        }
    }

    // MARK: - Silence Detection (VAD)

    private func resetSilenceTimer() {
        // 必须在主线程调度 Timer，否则后台线程没 RunLoop 不会触发
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: self.silenceDuration, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                if !self.lastTranscript.isEmpty {
                    let transcript = self.lastTranscript
                    self.lastTranscript = ""
                    print("🔇 [Claude] 静默检测到，用户说完: \(transcript)")

                    self.onSpeechStopped?()
                    self.handleSpeechEnd(transcript: transcript)

                    // 重启识别以便继续下一轮对话
                    self.restartRecognition()
                }
            }
        }
    }

    private func restartRecognition() {
        guard isRecording, let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else { return }

        // 结束当前识别
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        // 创建新的识别请求
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        recognitionRequest = newRequest

        // 重新安装 Tap（传 nil 让系统自动选格式）
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, time in
            self?.recognitionRequest?.append(buffer)
            self?.videoRecorder?.appendAudioBuffer(buffer, when: time)
        }

        lastTranscript = ""
        recognitionTask = speechRecognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let transcript = result.bestTranscription.formattedString
                let isNewSpeech = self.lastTranscript.isEmpty && !transcript.isEmpty

                if isNewSpeech {
                    DispatchQueue.main.async {
                        self.onSpeechStarted?()
                    }
                }

                self.lastTranscript = transcript
                DispatchQueue.main.async {
                    self.onUserTranscript?(transcript)
                }
                self.resetSilenceTimer()

                if result.isFinal {
                    self.handleSpeechEnd(transcript: transcript)
                }
            }

            if let error = error {
                let nsError = error as NSError
                if nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 203 || nsError.code == 216) {
                    // 静默或取消，不报错
                } else {
                    print("⚠️ [Claude] 重启识别错误: \(error.localizedDescription)")
                }
            }
        }

        print("🔄 [Claude] 语音识别已重启，等待下一轮对话")
    }

    // MARK: - Speech End → Claude API

    // 唤醒词 & 结束语
    private let wakeWords = ["小李", "小利", "小丽", "小力", "小莉", "xiaoli"]
    private let endWords = ["再见", "拜拜", "结束", "不聊了", "下次再聊", "好了不用了"]
    private var isConversationActive = false
    private var conversationTimer: Timer?
    private let conversationTimeout: TimeInterval = 60  // 60秒无对话自动结束

    private func handleSpeechEnd(transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isProcessingAPI else {
            print("⏳ [Claude] API 请求进行中，跳过重复提交")
            return
        }

        let lower = trimmed.lowercased()

        // 对话中：检查结束语
        if isConversationActive {
            if endWords.contains(where: { lower.contains($0) }) {
                print("👋 [Claude] 收到结束语，退出对话模式")
                isConversationActive = false
                conversationTimer?.invalidate()
                conversationTimer = nil
                // 发一句告别让她回应
                let query = "（用户说了再见，自然地告别）"
                isProcessingAPI = true
                sendToClaudeAPI(query: query)
                return
            }
            // 对话中不需要唤醒词，直接处理
            resetConversationTimer()
            print("💬 [Claude] 对话中: \(trimmed)")
            isProcessingAPI = true
            sendToClaudeAPI(query: trimmed)
            return
        }

        // 待命中：需要唤醒词
        guard let matchedWake = wakeWords.first(where: { lower.contains($0) }) else {
            print("🔇 [Claude] 待命中，无唤醒词，忽略: \(trimmed)")
            return
        }

        // 唤醒成功，进入对话模式
        isConversationActive = true
        resetConversationTimer()
        print("🔔 [Claude] 唤醒成功，进入对话模式")

        // 去掉唤醒词，提取实际问题
        var query = trimmed
        if let range = query.lowercased().range(of: matchedWake) {
            query = String(query[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            query = query.trimmingCharacters(in: CharacterSet(charactersIn: "，,。.、"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if query.isEmpty {
            query = "（用户叫了你的名字，自然地回应一下，告诉他你在听）"
        }

        print("💬 [Claude] 唤醒词[\(matchedWake)] 用户说: \(query)")
        isProcessingAPI = true
        sendToClaudeAPI(query: query)
    }

    private func resetConversationTimer() {
        let block = { [weak self] in
            guard let self = self else { return }
            self.conversationTimer?.invalidate()
            self.conversationTimer = Timer.scheduledTimer(withTimeInterval: self.conversationTimeout, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                print("⏰ [Claude] 对话超时，自动退出对话模式")
                self.isConversationActive = false
            }
        }
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func sendToClaudeAPI(query: String) {
        let apiURL = "\(baseURL)/messages"
        print("🌐 [Claude] API 请求: \(apiURL)")

        let visionKeywords = ["看看", "看一下", "这是什么", "那是什么", "什么东西", "帮我看", "你看到", "看到了", "眼前", "面前", "前面是"]
        let needsVision = visionKeywords.contains(where: { query.contains($0) })

        apiTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let imageToSend = needsVision ? self.pendingImage : nil
                let (response, audioData) = try await self.callClaudeAPI(text: query, image: imageToSend)
                self.pendingImage = nil
                print("✅ [Claude] API 回复(\(response.count)字): \(String(response.prefix(50)))...")

                DispatchQueue.main.async { [weak self] in
                    self?.onTranscriptDelta?(response)
                    self?.onTranscriptDone?(response)
                    self?.speakResponse(response, audioData: audioData)
                    self?.isProcessingAPI = false
                    // 收到回复，刷新对话计时器
                    if self?.isConversationActive == true {
                        self?.resetConversationTimer()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                print("❌ [Claude] API 失败: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    self?.onError?("Claude API 错误: \(error.localizedDescription)")
                    self?.isProcessingAPI = false
                }
            }
        }
    }

    // MARK: - Claude Messages API

    private struct ClaudeRequest: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
        let tools: [SearchTool]?

        struct Message: Encodable {
            let role: String
            let content: [ContentItem]
        }

        struct SearchTool: Encodable {
            let type: String
            let name: String
            let max_uses: Int?
        }
    }

    private enum ContentItem: Encodable {
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

    private struct ClaudeResponse: Decodable {
        let content: [ContentBlock]
        let audio_base64: String?

        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
    }

    private func sendRequest(url: URL, body: Data, timeout: TimeInterval) async throws -> (String, Data?) {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.timeoutInterval = timeout
        urlRequest.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OmniError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OmniError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        let apiResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)

        let allText = apiResponse.content
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined()

        guard !allText.isEmpty else {
            throw OmniError.emptyResponse
        }

        // 解码 base64 音频（代理返回的 Edge TTS）
        var audioData: Data? = nil
        if let b64 = apiResponse.audio_base64, !b64.isEmpty {
            audioData = Data(base64Encoded: b64)
            print("🔊 [Claude] audio_base64 长度=\(b64.count), 解码后=\(audioData?.count ?? 0) bytes")
        } else {
            print("🔊 [Claude] 响应中无 audio_base64 字段")
            // 打印原始 JSON 前200字符辅助调试
            let rawJSON = String(data: data, encoding: .utf8) ?? ""
            print("🔊 [Claude] 原始响应前200字: \(String(rawJSON.prefix(200)))")
        }

        return (allText, audioData)
    }

    private func callClaudeAPI(text: String, image: UIImage?) async throws -> (String, Data?) {
        // 构建 content
        var contentItems: [ContentItem] = []

        if let image = image, let imageData = image.jpegData(compressionQuality: 0.85) {
            let base64 = imageData.base64EncodedString()
            contentItems.append(.image(mediaType: "image/jpeg", data: base64))
        }

        contentItems.append(.text(text))

        let request = ClaudeRequest(
            model: model,
            max_tokens: 1024,
            system: systemPrompt,
            messages: [
                ClaudeRequest.Message(role: "user", content: contentItems)
            ],
            tools: [
                ClaudeRequest.SearchTool(type: "web_search_20250305", name: "web_search", max_uses: 3)
            ]
        )

        let body = try JSONEncoder().encode(request)
        let primaryURL = URL(string: "\(baseURL)/messages")!
        let isUsingProxy = baseURL != VisionAPIConfig.anthropicURL

        // 先走主路线（代理或API）
        do {
            return try await sendRequest(url: primaryURL, body: body, timeout: 90)
        } catch {
            // 主路线是代理且失败了 → 自动切到 Anthropic API 重试
            if isUsingProxy {
                print("⚠️ [Claude] 代理失败，自动切换 Anthropic API: \(error.localizedDescription)")
                let fallbackURL = URL(string: "\(VisionAPIConfig.anthropicURL)/messages")!
                return try await sendRequest(url: fallbackURL, body: body, timeout: 90)
            }
            throw error
        }
    }

    // MARK: - TTS (Edge TTS via proxy response, fallback Apple TTS)

    private func speakResponse(_ text: String, audioData: Data? = nil) {
        isSpeaking = true
        print("🔊 [Claude] TTS 开始: \(String(text.prefix(30)))...")

        if let audioData = audioData, audioData.count > 500 {
            print("🔊 [Claude] 使用内嵌 Edge TTS 音频")
            playMP3Data(audioData)
        } else {
            // 没有内嵌音频，尝试单独调代理 TTS 端点
            print("🔊 [Claude] 无内嵌音频，尝试代理 TTS...")
            Task {
                let edgeAudio = await self.fetchEdgeTTS(text: text)
                DispatchQueue.main.async {
                    if let data = edgeAudio, data.count > 500 {
                        print("🔊 [Claude] 代理 Edge TTS 获取成功 (\(data.count) bytes)")
                        self.playMP3Data(data)
                    } else {
                        print("🔊 [Claude] 回退 Apple TTS")
                        self.speakWithAppleTTS(text)
                    }
                }
            }
        }
    }

    /// 单独调代理 /v1/tts 端点获取 Edge TTS 音频
    private func fetchEdgeTTS(text: String) async -> Data? {
        // 依次尝试 Tailscale → 本地 WiFi
        let proxyURLs = [
            VisionAPIConfig.tailscaleProxyURL.replacingOccurrences(of: "/v1", with: "/v1/tts"),
            VisionAPIConfig.localProxyURL.replacingOccurrences(of: "/v1", with: "/v1/tts")
        ]

        for urlString in proxyURLs {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10
            request.httpBody = try? JSONEncoder().encode(["text": text])

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200, data.count > 500 {
                    print("🔊 [Claude] Edge TTS 从 \(urlString) 获取成功")
                    return data
                }
            } catch {
                print("🔊 [Claude] Edge TTS \(urlString) 失败: \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func playMP3Data(_ data: Data) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge_tts_\(Int(Date().timeIntervalSince1970)).mp3")

        do {
            try data.write(to: tempURL)
            let player = try AVAudioPlayer(contentsOf: tempURL)
            player.delegate = self
            player.volume = 1.0
            player.play()
            self.ttsPlayer = player
            print("🔊 [Claude] Edge TTS 播放中 (\(data.count) bytes)")
        } catch {
            print("❌ [Claude] Edge TTS 播放失败: \(error)")
            isSpeaking = false
            onAudioDone?()
        }
    }

    private func speakWithAppleTTS(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        print("🔊 [Claude] 回退 Apple TTS")

        let bufferQueue = DispatchQueue(label: "tts.collect")
        var allBuffers: [AVAudioPCMBuffer] = []
        var didComplete = false

        synthesizer.write(utterance) { [weak self] (buffer: AVAudioBuffer) in
            guard let self = self else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                bufferQueue.async {
                    guard !didComplete else { return }
                    didComplete = true
                    let collected = allBuffers
                    DispatchQueue.main.async {
                        self.playAndRecordTTS(collected)
                    }
                }
                return
            }
            bufferQueue.async { allBuffers.append(pcm) }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.isSpeaking else { return }
            bufferQueue.async {
                guard !didComplete else { return }
                didComplete = true
                let collected = allBuffers
                DispatchQueue.main.async {
                    if collected.isEmpty {
                        self.isSpeaking = false
                        self.onAudioDone?()
                    } else {
                        self.playAndRecordTTS(collected)
                    }
                }
            }
        }
    }

    private func playAndRecordTTS(_ buffers: [AVAudioPCMBuffer]) {
        guard isSpeaking, !buffers.isEmpty else {
            isSpeaking = false
            onAudioDone?()
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts_\(Int(Date().timeIntervalSince1970)).caf")

        do {
            // 写入临时文件
            var audioFile: AVAudioFile?
            for buf in buffers {
                if audioFile == nil {
                    audioFile = try AVAudioFile(
                        forWriting: tempURL,
                        settings: buf.format.settings,
                        commonFormat: buf.format.commonFormat,
                        interleaved: buf.format.isInterleaved
                    )
                }
                try audioFile?.write(from: buf)
            }
            audioFile = nil // flush

            // 把 TTS 整段喂给视频录制器（合并后一次性重采样，无边界伪影）
            // 按实时节奏分块喂入，stop 时自动跳过剩余部分
            if let recorder = videoRecorder, recorder.isActive {
                feedTTSToRecorder(buffers, recorder: recorder)
            }

            // AVAudioPlayer 播放（完全独立于 audioEngine）
            let player = try AVAudioPlayer(contentsOf: tempURL)
            player.delegate = self
            player.volume = 1.0
            player.play()
            self.ttsPlayer = player
            print("🔊 [Claude] AVAudioPlayer 播放 TTS (\(buffers.count) buffers)")

        } catch {
            print("❌ [Claude] TTS 播放失败: \(error)")
            try? FileManager.default.removeItem(at: tempURL)
            isSpeaking = false
            onAudioDone?()
        }
    }

    // MARK: - TTS → Video Recorder (queue for mixing into mic timeline)

    private func feedTTSToRecorder(_ buffers: [AVAudioPCMBuffer], recorder: VideoFrameRecorder) {
        guard let firstFormat = buffers.first?.format else { return }

        // Merge all TTS buffers into one contiguous buffer
        let totalFrames = buffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard let merged = AVAudioPCMBuffer(pcmFormat: firstFormat, frameCapacity: totalFrames) else { return }

        for buf in buffers {
            guard let srcData = buf.floatChannelData?[0],
                  let dstData = merged.floatChannelData?[0] else { continue }
            let offset = Int(merged.frameLength)
            memcpy(dstData.advanced(by: offset), srcData, Int(buf.frameLength) * MemoryLayout<Float>.size)
            merged.frameLength += buf.frameLength
        }

        print("🎬 [TTS→Rec] 队列 \(buffers.count) 段 → \(merged.frameLength) frames @ \(firstFormat.sampleRate)Hz for mixing")

        // Queue the entire merged buffer — it will be mixed into mic buffers
        // by VideoFrameRecorder.mixTTSInto() at the mic's natural pace.
        // No asyncAfter, no chunking, no timing hacks.
        recorder.queueTTSBuffer(merged)
    }

    // MARK: - Image (保持接口一致)

    func sendImageAppend(_ image: UIImage) {
        // 存储图片，下次语音识别结束后会附带发给 Claude
        pendingImage = image
        print("📸 [Claude] 图片已缓存，将在下次对话中发送")
    }

    // 保持接口兼容（这些在新架构中不需要，但 ViewModel 可能会调用）
    func sendAudioAppend(_ base64Audio: String) {
        // No-op: 音频直接走 SFSpeechRecognizer，不再手动发送
    }

    func commitAudioBuffer() {
        // No-op: 语音识别自动处理
    }
}

// MARK: - AVSpeechSynthesizerDelegate

// MARK: - AVAudioPlayerDelegate (TTS 播放完成)

extension OmniRealtimeService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("🔊 [Claude] TTS 播放完成")
        // 清理临时文件
        if let url = player.url {
            try? FileManager.default.removeItem(at: url)
        }
        ttsPlayer = nil
        isSpeaking = false
        DispatchQueue.main.async { [weak self] in
            self?.onAudioDone?()
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension OmniRealtimeService: AVSpeechSynthesizerDelegate {
    // write() 模式下这些回调不会触发，保留以防万一
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {}
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
    }
}

// MARK: - Error Types

enum OmniError: LocalizedError {
    case invalidResponse
    case emptyResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "无效的响应格式"
        case .emptyResponse:
            return "Claude 返回空响应"
        case .apiError(let statusCode, let message):
            return "API 错误 (\(statusCode)): \(message)"
        }
    }
}
