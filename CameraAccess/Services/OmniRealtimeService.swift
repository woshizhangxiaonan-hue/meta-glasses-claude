/*
 * Qwen-Omni-Realtime WebSocket Service
 * 修复版：单引擎架构，彻底解决 Release 模式下的闪退
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

// MARK: - Service Class

class OmniRealtimeService: NSObject {

    // WebSocket
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Configuration
    private let apiKey: String
    private let model = "qwen3-omni-flash-realtime"
    private let baseURL = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"

    // ✅ 核心修复：只使用一个引擎
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    // 音频格式 (24kHz PCM16, 单声道)
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)

    // Audio buffer management
    private var audioBuffer = Data()
    private var isCollectingAudio = false
    private var audioChunkCount = 0
    private let minChunksBeforePlay = 2 
    private var hasStartedPlaying = false

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
        setupAudioGraph()
    }

    // MARK: - Audio Engine Setup (Single Graph)

    private func setupAudioGraph() {
        // 1. 将 Player 节点附加到引擎
        audioEngine.attach(playerNode)
        
        // 2. 连接 Player 到主混音器
        if let format = audioFormat {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        }
        
        // 3. 预先准备引擎
        audioEngine.prepare()
        print("✅ [Omni] 音频图构建完成 (单引擎模式)")
    }
    
    // 确保引擎正在运行
    private func ensureEngineRunning() {
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                print("▶️ [Omni] 音频引擎已启动")
            } catch {
                print("❌ [Omni] 引擎启动失败: \(error)")
                onError?("Engine start failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - WebSocket Connection

    func connect() {
        let urlString = "\(baseURL)?model=\(model)"
        print("🔌 [Omni] 准备连接 WebSocket")

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
                "instructions": "你是RayBan Meta智能眼镜AI助手。",
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

        do {
            print("🎤 [Omni] 准备开始录音...")

            // 1. 配置 AudioSession
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            // 2. 获取 InputNode
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            // 3. 移除旧的 Tap
            inputNode.removeTap(onBus: 0)

            // 4. 安装新的 Tap
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
                self?.processAudioBuffer(buffer)
            }

            // 5. 启动引擎
            ensureEngineRunning()

            isRecording = true
            print("✅ [Omni] 录音已启动")

        } catch {
            print("❌ [Omni] 启动录音失败: \(error.localizedDescription)")
            onError?("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        print("🛑 [Omni] 停止录音")
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
        hasAudioBeenSent = false
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatChannelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let channel = floatChannelData.pointee

        var int16Data = [Int16](repeating: 0, count: frameLength)
        for i in 0..<frameLength {
            let sample = channel[i]
            let clampedSample = max(-1.0, min(1.0, sample))
            int16Data[i] = Int16(clampedSample * 32767.0)
        }

        let data = Data(bytes: int16Data, count: frameLength * MemoryLayout<Int16>.size)
        let base64Audio = data.base64EncodedString()

        sendAudioAppend(base64Audio)

        if !hasAudioBeenSent {
            hasAudioBeenSent = true
            print("✅ [Omni] 第一次音频已发送")
            DispatchQueue.main.async { [weak self] in
                self?.onFirstAudioSent?()
            }
        }
    }

    // MARK: - Send Events
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
        guard let imageData = image.jpegData(compressionQuality: 0.5) else { return }
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
                self?.onError?("Connection lost")
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
        guard let pcmBuffer = createPCMBuffer(from: audioData, format: audioFormat) else { return }
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
