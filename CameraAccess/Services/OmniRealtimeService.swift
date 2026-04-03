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
    private let systemPrompt = "你是 Meta 智能眼镜的中文AI助手。用户戴着眼镜跟你对话，你能看到他们眼前的画面。仔细观察图片中的所有细节（文字、品牌、物体、颜色、环境、人物表情等），给出准确具体的描述。用简洁自然的中文回答，像朋友聊天一样。每次回复控制在2-3句话，因为要语音播报。"

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
            // 不用 .allowBluetooth — 会把麦克风路由到 Meta 眼镜蓝牙（无标准麦克风输入）
            // 用 .allowBluetoothA2DP — 蓝牙只用于输出，输入走手机内置麦克风
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

    private func handleSpeechEnd(transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isProcessingAPI else {
            print("⏳ [Claude] API 请求进行中，跳过重复提交")
            return
        }

        print("💬 [Claude] 用户说: \(trimmed)")
        isProcessingAPI = true

            let apiURL = "\(baseURL)/messages"
        print("🌐 [Claude] API 请求: \(apiURL)")

        apiTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let response = try await self.callClaudeAPI(text: trimmed, image: self.pendingImage)
                self.pendingImage = nil
                print("✅ [Claude] API 回复(\(response.count)字): \(String(response.prefix(50)))...")

                DispatchQueue.main.async { [weak self] in
                    self?.onTranscriptDelta?(response)
                    self?.onTranscriptDone?(response)
                    self?.speakResponse(response)
                    self?.isProcessingAPI = false
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

        struct Message: Encodable {
            let role: String
            let content: [ContentItem]
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

        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
    }

    private func callClaudeAPI(text: String, image: UIImage?) async throws -> String {
        let url = URL(string: "\(baseURL)/messages")!

        // 构建 content
        var contentItems: [ContentItem] = []

        if let image = image, let imageData = image.jpegData(compressionQuality: 0.85) {
            let base64 = imageData.base64EncodedString()
            contentItems.append(.image(mediaType: "image/jpeg", data: base64))
        }

        contentItems.append(.text(text))

        let request = ClaudeRequest(
            model: model,
            max_tokens: 512,
            system: systemPrompt,
            messages: [
                ClaudeRequest.Message(role: "user", content: contentItems)
            ]
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.timeoutInterval = 60

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OmniError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OmniError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(ClaudeResponse.self, from: data)

        guard let firstText = apiResponse.content.first(where: { $0.type == "text" })?.text else {
            throw OmniError.emptyResponse
        }

        return firstText
    }

    // MARK: - TTS (write → AVAudioPlayer，不碰 audioEngine)

    private func speakResponse(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        isSpeaking = true
        print("🔊 [Claude] TTS 开始: \(String(text.prefix(30)))...")

        // write() 生成 PCM 缓冲 → 写文件 → AVAudioPlayer 播放
        // 完全不碰 audioEngine，和麦克风/语音识别零干扰
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

        // 安全超时：write() 不回调时兜底
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.isSpeaking else { return }
            bufferQueue.async {
                guard !didComplete else { return }
                didComplete = true
                let collected = allBuffers
                DispatchQueue.main.async {
                    if collected.isEmpty {
                        print("⚠️ [Claude] TTS write() 超时无数据")
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
