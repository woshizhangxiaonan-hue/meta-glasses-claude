/*
 * Video Frame Recorder
 * Records video frames + audio from Meta glasses into MP4
 *
 * Audio architecture:
 * - Mic audio OWNS the PTS timeline (continuous, monotonic)
 * - TTS audio is queued and MIXED INTO mic buffers (added sample-by-sample)
 * - This avoids PTS conflicts from two sources sharing one counter
 */

import AVFoundation
import UIKit
import Photos

class VideoFrameRecorder {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartTime: Date?
    private var outputURL: URL?

    // Thread-safe state (accessed from multiple threads)
    private let stateLock = NSLock()
    private var _isRecording = false
    private var _frameCount: Int = 0
    private var _audioBufferCount: Int = 0
    private var _lastAppendOK: Bool = true

    var isRecording: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isRecording
    }

    // Serial queue for ALL audio PTS + write operations
    private let audioQueue = DispatchQueue(label: "videorecorder.audio")

    // PTS counter — ONLY accessed on audioQueue
    private var accumulatedAudioSeconds: Double = 0

    // Resampler: 统一所有音频到 48000Hz mono Float32
    private let targetSampleRate: Double = 48000
    private let converterLock = NSLock()
    private var converterCache: [String: AVAudioConverter] = [:]
    private lazy var targetFormat: AVAudioFormat = {
        AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1)!
    }()

    // TTS mixing buffer — protected by ttsMixLock
    private var ttsMixBuffer: [Float] = []
    private let ttsMixLock = NSLock()

    var isActive: Bool { isRecording }
    var debugAudioCount: Int { stateLock.lock(); defer { stateLock.unlock() }; return _audioBufferCount }
    var debugLastAppendOK: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _lastAppendOK }

    func startRecording(frameSize: CGSize) throws {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "glasses_video_\(Int(Date().timeIntervalSince1970)).mp4"
        let url = tempDir.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Video input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(frameSize.width),
            AVVideoHeightKey: Int(frameSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 15
            ]
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        let sourceAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(frameSize.width),
            kCVPixelBufferHeightKey as String: Int(frameSize.height)
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: sourceAttrs
        )

        writer.add(vInput)

        // Audio input — PCM → AAC encoding
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true
        writer.add(aInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.assetWriter = writer
        self.videoInput = vInput
        self.audioInput = aInput
        self.pixelBufferAdaptor = adaptor
        self.outputURL = url
        self.recordingStartTime = Date()

        // 在 audioQueue 上重置 PTS（避免与残留的 async block 竞争）
        audioQueue.sync { self.accumulatedAudioSeconds = 0 }

        converterLock.lock()
        converterCache.removeAll()
        converterLock.unlock()

        ttsMixLock.lock()
        ttsMixBuffer.removeAll()
        ttsMixLock.unlock()

        stateLock.lock()
        _frameCount = 0
        _audioBufferCount = 0
        _lastAppendOK = true
        _isRecording = true
        stateLock.unlock()

        print("🎬 VideoRecorder: started, size=\(Int(frameSize.width))x\(Int(frameSize.height))")
    }

    // MARK: - Mic Audio (owns PTS timeline, mixes in TTS)

    /// Call from mic tap only. This is the PTS owner — monotonic, continuous.
    func appendMicBuffer(_ buffer: AVAudioPCMBuffer, when time: AVAudioTime) {
        guard isRecording else { return }

        // Resample to 48000Hz mono if needed
        let converted: AVAudioPCMBuffer
        if buffer.format.sampleRate == targetSampleRate && buffer.format.channelCount == 1 {
            converted = buffer
        } else if let resampled = resampleBuffer(buffer) {
            converted = resampled
        } else {
            return
        }

        // Mix TTS into mic buffer before writing
        let mixed = mixTTSInto(micBuffer: converted)

        audioQueue.async { [weak self] in
            guard let self = self,
                  self.isRecording,
                  let audioInput = self.audioInput,
                  audioInput.isReadyForMoreMediaData else { return }

            let pts = CMTime(seconds: self.accumulatedAudioSeconds, preferredTimescale: 48000)
            let bufferDuration = Double(mixed.frameLength) / self.targetSampleRate
            self.accumulatedAudioSeconds += bufferDuration

            if let sampleBuffer = self.createAudioSampleBuffer(from: mixed, presentationTime: pts) {
                let ok = audioInput.append(sampleBuffer)
                self.stateLock.lock()
                self._lastAppendOK = ok
                if ok { self._audioBufferCount += 1 }
                self.stateLock.unlock()
                if !ok {
                    print("⚠️ AudioInput.append FAILED, writer.status=\(self.assetWriter?.status.rawValue ?? -1)")
                }
            }
        }
    }

    // MARK: - TTS Audio (queued for mixing)

    /// Queue TTS audio for mixing into the mic timeline.
    /// The TTS samples will be added on top of mic samples in appendMicBuffer().
    func queueTTSBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording else { return }

        // Resample to 48000Hz mono first
        let converted: AVAudioPCMBuffer
        if buffer.format.sampleRate == targetSampleRate && buffer.format.channelCount == 1 {
            converted = buffer
        } else if let resampled = resampleBuffer(buffer) {
            converted = resampled
        } else {
            print("⚠️ [Recorder] TTS resample failed, format=\(buffer.format)")
            return
        }

        guard let data = converted.floatChannelData?[0] else { return }
        let count = Int(converted.frameLength)

        ttsMixLock.lock()
        ttsMixBuffer.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
        ttsMixLock.unlock()
    }

    // MARK: - Mixing

    private func mixTTSInto(micBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let frames = Int(micBuffer.frameLength)
        guard frames > 0 else { return micBuffer }

        // Drain up to frameCount samples from TTS queue
        ttsMixLock.lock()
        let available = min(frames, ttsMixBuffer.count)
        let ttsSamples: [Float]
        if available > 0 {
            ttsSamples = Array(ttsMixBuffer.prefix(available))
            ttsMixBuffer.removeFirst(available)
        } else {
            ttsSamples = []
        }
        ttsMixLock.unlock()

        guard !ttsSamples.isEmpty else { return micBuffer }

        // Create output buffer and mix
        guard let output = AVAudioPCMBuffer(pcmFormat: micBuffer.format, frameCapacity: micBuffer.frameCapacity),
              let micData = micBuffer.floatChannelData?[0],
              let outData = output.floatChannelData?[0] else { return micBuffer }

        output.frameLength = micBuffer.frameLength
        memcpy(outData, micData, frames * MemoryLayout<Float>.size)

        // Additive mix + clamp
        for i in 0..<available {
            let mixed = outData[i] + ttsSamples[i]
            outData[i] = min(max(mixed, -1.0), 1.0)
        }

        return output
    }

    // MARK: - Legacy API (kept for backward compatibility, routes to appendMicBuffer)

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, when time: AVAudioTime) {
        appendMicBuffer(buffer, when: time)
    }

    // MARK: - Audio Resampler

    private func resampleBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sourceFormat = buffer.format
        let cacheKey = "\(sourceFormat.sampleRate)-\(sourceFormat.channelCount)"

        // 复用 converter（每种源格式一个，加锁保护）
        converterLock.lock()
        let converter: AVAudioConverter
        if let cached = converterCache[cacheKey] {
            converter = cached
        } else {
            guard let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                converterLock.unlock()
                print("⚠️ 无法创建 converter: \(sourceFormat) → \(targetFormat)")
                return nil
            }
            converterCache[cacheKey] = newConverter
            print("🔄 [Recorder] 新建 converter: \(sourceFormat.sampleRate)Hz/\(sourceFormat.channelCount)ch → 48000Hz/1ch")
            converter = newConverter
        }
        converterLock.unlock()

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames + 1) else { return nil }

        var error: NSError?
        var gotData = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if gotData {
                outStatus.pointee = .noDataNow
                return nil
            }
            gotData = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            print("⚠️ resample error: \(error)")
            return nil
        }

        return outputBuffer.frameLength > 0 ? outputBuffer : nil
    }

    func appendFrame(_ image: UIImage) {
        guard isRecording,
              let adaptor = pixelBufferAdaptor,
              let input = videoInput,
              input.isReadyForMoreMediaData,
              let startTime = recordingStartTime else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        let presentationTime = CMTime(seconds: elapsed, preferredTimescale: 600)

        guard let pixelBuffer = pixelBufferFromImage(image) else { return }

        adaptor.append(pixelBuffer, withPresentationTime: presentationTime)

        stateLock.lock()
        _frameCount += 1
        let fc = _frameCount
        let ac = _audioBufferCount
        stateLock.unlock()

        if fc % 30 == 0 {
            print("🎬 VideoRecorder: \(fc) frames, \(String(format: "%.1f", elapsed))s, audio=\(ac)")
        }
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard isRecording, let writer = assetWriter else {
            completion(.failure(RecorderError.notRecording))
            return
        }

        stateLock.lock()
        let fc = _frameCount
        let ac = _audioBufferCount
        _isRecording = false
        stateLock.unlock()

        print("🎬 VideoRecorder: stopping, \(fc) frames, \(ac) audio buffers")
        audioQueue.sync {} // drain pending audio

        // 丢弃未播放的 TTS 数据（用户按停止 = 立即停止）
        ttsMixLock.lock()
        let discarded = ttsMixBuffer.count
        ttsMixBuffer.removeAll()
        ttsMixLock.unlock()
        if discarded > 0 {
            print("🎬 VideoRecorder: discarded \(discarded) remaining TTS samples")
        }

        guard fc > 0 else {
            writer.cancelWriting()
            if let url = outputURL { try? FileManager.default.removeItem(at: url) }
            completion(.failure(RecorderError.noFrames))
            return
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        writer.finishWriting { [weak self] in
            if writer.status == .completed, let url = self?.outputURL {
                print("🎬 VideoRecorder: finished OK, saving to Photos...")
                self?.saveToPhotoLibrary(url: url, completion: completion)
            } else {
                let error = writer.error ?? RecorderError.writingFailed
                print("🎬 VideoRecorder: failed - \(error)")
                completion(.failure(error))
            }
        }
    }

    // MARK: - Audio Sample Buffer

    private func createAudioSampleBuffer(from pcmBuffer: AVAudioPCMBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        guard let channelData = pcmBuffer.floatChannelData else { return nil }
        let frameCount = pcmBuffer.frameLength
        let sampleRate = pcmBuffer.format.sampleRate

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard let fmt = formatDescription else { return nil }

        let dataSize = Int(frameCount) * 4
        let dataCopy = UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 4)
        memcpy(dataCopy, channelData[0], dataSize)

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: dataCopy,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard let block = blockBuffer else {
            dataCopy.deallocate()
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: fmt,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }

    // MARK: - Photo Library

    private func saveToPhotoLibrary(url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(.failure(RecorderError.noPhotoPermission))
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                try? FileManager.default.removeItem(at: url)
                if success {
                    print("🎬 VideoRecorder: saved to Photos")
                    completion(.success(url))
                } else {
                    completion(.failure(error ?? RecorderError.saveFailed))
                }
            }
        }
    }

    // MARK: - Pixel Buffer

    private func pixelBufferFromImage(_ image: UIImage) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    enum RecorderError: LocalizedError {
        case notRecording
        case writingFailed
        case noPhotoPermission
        case saveFailed
        case noFrames

        var errorDescription: String? {
            switch self {
            case .notRecording: return "录制未开始"
            case .writingFailed: return "视频写入失败"
            case .noPhotoPermission: return "请在设置中允许相册权限"
            case .saveFailed: return "保存失败"
            case .noFrames: return "未录到任何画面"
            }
        }
    }
}
