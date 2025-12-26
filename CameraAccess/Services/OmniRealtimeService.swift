/*
 * Qwen-Omni-Realtime WebSocket Service
 * 终极完美版：集成实时重采样 (Resampling)，解决无文字/识别失败问题
 */

import Foundation
import UIKit
import AVFoundation

// MARK: - WebSocket Events
enum OmniClientEvent: String {
    case sessionUpdate = "session.update"
    case inputAudioBufferAppend = "input_audio_buffer.append"
    case inputAudioBufferCommit = "input_audio_buffer.commit"
    case inputImageBufferAppend = "input_image_buffer.append"
    case responseCreate = "response.create"
}

enum OmniServerEvent: String {
    case sessionCreated = "session.created"
    case sessionUpdated = "session.updated"
    case inputAudioBufferSpeechStarted = "input_audio_buffer.speech_started"
    case inputAudioBufferSpeechStopped = "input_audio_buffer.speech_stopped"
    case inputAudioBufferCommitted = "input_audio_buffer.committed"
    case responseCreated = "response.created"
    case responseAudioTranscriptDelta = "response.audio_transcript.delta"
    case responseAudioTranscriptDone = "response.audio_transcript.done"
    case responseAudioDelta = "response.audio.delta"
    case responseAudioDone = "response.audio.done"
    case responseDone = "response.done"
    case conversationItemCreated = "conversation.item.created"
    case conversationItemInputAudioTranscriptionCompleted = "conversation.item.input_audio_transcription.completed"
    case error = "error"
}

class OmniRealtimeService: NSObject {

    // WebSocket
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Configuration
    private let apiKey: String
    private let model = "qwen3-omni-flash-realtime"
    private let baseURL = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"

    // Engine
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    // ✅ 关键：音频转换器 (Resampler)
    private var audioConverter: AVAudioConverter?
    // ✅ 关键：AI 需要的固定格式 (24k PCM16)
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!

    // Audio buffer
    private var audioBuffer = Data()
    private var isCollectingAudio = false
    private var audioChunkCount = 0
    private let minChunksBeforePlay = 3
    private var hasStartedPlaying = false
    private var isAudioGraphSetup = false

    // Callbacks
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

    // State
    private var isRecording = false
    private var hasAudioBeenSent = false
    private var eventIdCounter = 0

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    // MARK: - Audio Engine Setup

    private func setupAudioGraph() {
        guard !isAudioGraphSetup else { return }
        
        print("⚙️ [Omni] 初始化音频图...")
        audioEngine.attach(playerNode)
        
        // 播放链路：连接到 Mixer，让系统处理播放采样率
        let mixer = audioEngine.mainMixerNode
        let mixerFormat = mixer.outputFormat(forBus: 0)
        audioEngine.connect(playerNode, to: mixer, format: mixerFormat)
        
        do {
            audioEngine.prepare()
            isAudioGraphSetup = true
            print("✅ [Omni] 音频引擎准备就绪")
        } catch {
            print("❌ [Omni] 引擎准备失败: \(error)")
        }
    }
    
    private func ensureEngineRunning() {
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                print("▶️ [Omni] 音频引擎已启动")
            } catch {
                print("❌ [Omni] 引擎启动失败: \(error)")
            }
        }
    }

    // MARK: - WebSocket Connection

    func connect() {
        setupAudioGraph()
        
        let urlString = "\(baseURL)?model=\(model)"
        print("🔌 [Omni] 连接 WebSocket: \(urlString)")

        guard let url = URL(string: urlString) else {
            onError?("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.default
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())

        webSocket = urlSession?.webSocketTask(with: request)
        webSocket?.resume()

        receiveMessage()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.configureSession()
        }
    }

    func disconnect() {
        print("🔌 [Omni] 断开连接")
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        stopRecording()
        
        playerNode.stop()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    private func configureSession() {
        let sessionConfig: [String: Any] = [
            "event_id": generateEventId(),
            "type": OmniClientEvent.sessionUpdate.rawValue,
            "session": [
                "modalities": ["text", "audio"],
                "voice": "Cherry",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm24",
                "smooth_output": true,
                "instructions": "你是RayBan Meta智能眼镜AI助手。请简练回答。",
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "silence_duration_ms": 800
                ]
            ]
        ]
        sendEvent(sessionConfig)
    }

    // MARK: - Audio Recording

    func startRecording() {
        guard !isRecording else { return }

        print("🎤 [Omni] 准备启动录音...")

        let audioSession = AVAudioSession.sharedInstance()
        do {
            // 保持兼容模式
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers, .defaultToSpeaker]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("⚠️ [Omni] Session配置受限: \(error.localizedDescription)")
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0) // 获取硬件真实格式
        print("🎤 [Omni] 硬件采样率: \(inputFormat.sampleRate)Hz, 通道: \(inputFormat.channelCount)")

        if inputFormat.sampleRate < 8000 {
            print("❌ [Omni] 采样率异常，无法录音")
            return
        }
        
        // ✅ 关键：初始化转换器 (Hardware Format -> 24k PCM16)
        // 这样无论眼镜是 16k 还是 48k，发给 AI 的永远是标准的 24k
        audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
        if audioConverter == nil {
            print("❌ [Omni] 无法创建音频转换器！")
            return
        }
        
        inputNode.removeTap(onBus: 0)
        
        // 使用硬件格式安装 Tap
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }

        ensureEngineRunning()

        isRecording = true
        print("✅ [Omni] 录音已启动 (重采样已激活)")
    }

    func stopRecording() {
        guard isRecording else { return }
        print("🛑 [Omni] 停止录音")
        if audioEngine.inputNode.numberOfInputs > 0 {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        isRecording = false
        hasAudioBeenSent = false
        audioConverter = nil // 释放转换器
    }

    // ✅ 核心修复：带重采样的处理函数
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter else { return }
        
        // 1. 计算输出需要的帧数
        // 比例 = 目标采样率 / 输入采样率
        let inputCallback: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else { return }
        
        // 2. 执行转换 (Resample + Format Convert)
        var error: NSError? = nil
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputCallback)
        
        if status == .error || error != nil {
            print("❌ [Omni] 转换失败: \(String(describing: error))")
            return
        }
        
        // 3. 提取 PCM16 数据并发送
        if outputBuffer.frameLength > 0, let channelData = outputBuffer.int16ChannelData {
            let dataLength = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
            let data = Data(bytes: channelData[0], count: dataLength)
            
            let base64Audio = data.base64EncodedString()
            sendAudioAppend(base64Audio)

            if !hasAudioBeenSent {
                hasAudioBeenSent = true
                print("✅ [Omni] 首帧重采样音频已发送")
                DispatchQueue.main.async { [weak self] in
                    self?.onFirstAudioSent?()
                }
            }
        }
    }

    // MARK: - Send Events (保持不变)
    private func sendEvent(_ event: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocket?.send(message) { error in
            if let error = error { print("❌ Send error: \(error)") }
        }
    }

    func sendAudioAppend(_ base64Audio: String) {
        let event: [String: Any] = [
            "event_id": generateEventId(),
            "type": OmniClientEvent.inputAudioBufferAppend.rawValue,
            "audio": base64Audio
        ]
        sendEvent(event)
    }

    func sendImageAppend(_ image: UIImage) {
        guard let imageData = image.jpegData(compressionQuality: 0.4) else { return }
        let base64Image = imageData.base64EncodedString()
        let event: [String: Any] = [
            "event_id": generateEventId(),
            "type": OmniClientEvent.inputImageBufferAppend.rawValue,
            "image": base64Image
        ]
        sendEvent(event)
    }

    func commitAudioBuffer() {
        let event: [String: Any] = [
            "event_id": generateEventId(),
            "type": OmniClientEvent.inputAudioBufferCommit.rawValue
        ]
        sendEvent(event)
    }

    // MARK: - Receive Messages
    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage()
            case .failure(let error):
                print("❌ Receive error: \(error)")
                self?.onError?("连接断开")
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text): handleServerEvent(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) { handleServerEvent(text) }
        @unknown default: break
        }
    }

    private func handleServerEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        DispatchQueue.main.async {
            switch type {
            case OmniServerEvent.sessionCreated.rawValue, OmniServerEvent.sessionUpdated.rawValue:
                self.onConnected?()
            case OmniServerEvent.inputAudioBufferSpeechStarted.rawValue:
                self.onSpeechStarted?()
            case OmniServerEvent.inputAudioBufferSpeechStopped.rawValue:
                self.onSpeechStopped?()
            case OmniServerEvent.responseAudioTranscriptDelta.rawValue:
                if let delta = json["delta"] as? String { self.onTranscriptDelta?(delta) }
            case OmniServerEvent.responseAudioTranscriptDone.rawValue:
                let text = json["text"] as? String ?? ""
                self.onTranscriptDone?(text)
            case OmniServerEvent.responseAudioDelta.rawValue:
                if let base64Audio = json["delta"] as? String,
                   let audioData = Data(base64Encoded: base64Audio) {
                    self.onAudioDelta?(audioData)
                    self.handleAudioResponse(audioData)
                }
            case OmniServerEvent.responseAudioDone.rawValue:
                self.finishAudioResponse()
                self.onAudioDone?()
            case OmniServerEvent.conversationItemInputAudioTranscriptionCompleted.rawValue:
                if let transcript = json["transcript"] as? String { self.onUserTranscript?(transcript) }
            case OmniServerEvent.error.rawValue:
                if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                    self.onError?(message)
                }
            default: break
            }
        }
    }

    // MARK: - Audio Playback

    private func handleAudioResponse(_ audioData: Data) {
        if !isCollectingAudio {
            isCollectingAudio = true
            audioBuffer = Data()
            audioChunkCount = 0
            hasStartedPlaying = false
            ensureEngineRunning()
            if !playerNode.isPlaying { playerNode.play() }
        }

        audioChunkCount += 1

        if !hasStartedPlaying {
            audioBuffer.append(audioData)
            if audioChunkCount >= minChunksBeforePlay {
                hasStartedPlaying = true
                playAudioBuffer(audioBuffer)
                audioBuffer = Data()
            }
        } else {
            playAudioBuffer(audioData)
        }
    }

    private func finishAudioResponse() {
        isCollectingAudio = false
        if !audioBuffer.isEmpty {
            playAudioBuffer(audioBuffer)
            audioBuffer = Data()
        }
        audioChunkCount = 0
        hasStartedPlaying = false
    }

    private func playAudioBuffer(_ audioData: Data) {
        // AI 返回的音频也是 24k PCM16，直接播放
        guard let pcmBuffer = createPCMBuffer(from: audioData, format: targetFormat) else { return }
        playerNode.scheduleBuffer(pcmBuffer)
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard let format = format else { return nil }
        let frameCount = data.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.int16ChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
            channelData[0].update(from: int16Pointer, count: frameCount)
        }
        return buffer
    }

    private func generateEventId() -> String {
        eventIdCounter += 1
        return "event_\(eventIdCounter)_\(UUID().uuidString.prefix(8))"
    }
}

// MARK: - URLSessionWebSocketDelegate
extension OmniRealtimeService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ WebSocket Connected")
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("🔌 WebSocket Closed")
    }
}
