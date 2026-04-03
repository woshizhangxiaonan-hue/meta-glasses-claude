/*
 * Live AI View
 * 自动启动的实时 AI 对话界面
 */

import SwiftUI
import Photos
import AVFoundation
import AudioToolbox

struct LiveAIView: View {
    @StateObject private var viewModel: OmniRealtimeViewModel
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showConversation = true // 控制对话内容显示/隐藏
    @State private var pushToTalkMode = false  // false=常开麦, true=按住说话
    @State private var isPressing = false       // 按住说话时的按压状态
    @State private var showSavedToast = false   // 拍照保存提示
    @State private var isRecordingVideo = false  // 录视频状态
    @State private var recordingDuration: TimeInterval = 0 // 录制时长
    @State private var recordingTimer: Timer?
    @State private var frameRefreshTimer: Timer?
    @State private var videoRecorder = VideoFrameRecorder()

    init(streamViewModel: StreamSessionViewModel, apiKey: String) {
        self.streamViewModel = streamViewModel
        self._viewModel = StateObject(wrappedValue: OmniRealtimeViewModel(apiKey: apiKey))
    }

    var body: some View {
        ZStack {
            // Black background
            Color.black
                .ignoresSafeArea()

            // 未连接设备提醒
            if !streamViewModel.hasActiveDevice {
                deviceNotConnectedView
            } else {
                // Video feed (full opacity, no white mask)
                if let videoFrame = streamViewModel.currentVideoFrame {
                    GeometryReader { geometry in
                        Image(uiImage: videoFrame)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .ignoresSafeArea()
                }

                VStack(spacing: 0) {
                // Header (紧贴状态栏)
                headerView
                    .padding(.top, 8) // 状态栏下方一点点

                // Conversation history (可隐藏)
                if showConversation {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(viewModel.conversationHistory) { message in
                                    MessageBubble(message: message)
                                        .id(message.id)
                                }

                                // Current AI response (streaming)
                                if !viewModel.currentTranscript.isEmpty {
                                    MessageBubble(
                                        message: ConversationMessage(
                                            role: .assistant,
                                            content: viewModel.currentTranscript
                                        )
                                    )
                                    .id("current")
                                }
                            }
                            .padding()
                        }
                        .onChange(of: viewModel.conversationHistory.count) { _ in
                            if let lastMessage = viewModel.conversationHistory.last {
                                withAnimation {
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: viewModel.currentTranscript) { _ in
                            withAnimation {
                                proxy.scrollTo("current", anchor: .bottom)
                            }
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Spacer()
                }

                // Status and stop button
                controlsView
                }
            }
        }
.onAppear {
            print("👁️ LiveAIView: onAppear 触发")
            print("👁️ LiveAIView: hasActiveDevice=\(streamViewModel.hasActiveDevice)")

            // 1. 基础检查
            guard streamViewModel.hasActiveDevice else {
                print("⚠️ LiveAIView: 未连接设备")
                return
            }

            // 2. 权限检查
            print("👁️ LiveAIView: 请求麦克风权限...")
            PermissionsManager.shared.requestMicrophonePermission { granted in
                DispatchQueue.main.async {
                    print("👁️ LiveAIView: 麦克风权限=\(granted)")
                    guard granted else {
                        viewModel.errorMessage = "请在设置中允许麦克风权限"
                        viewModel.showError = true
                        return
                    }

                    // 3. 启动序列 (Sequence)
                    Task {
                        // A. 启动视频流 (这是 Meta SDK 的动作)
                        print("🎥 启动视频流...")
                        print("🎥 当前流状态: \(streamViewModel.streamingStatus)")
                        await streamViewModel.handleStartStreaming()
                        print("🎥 视频流启动完成，状态: \(streamViewModel.streamingStatus)")

                        // B. 强制等待 0.5s，让视频流先跑起来
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        print("🎥 等待后 currentVideoFrame=\(streamViewModel.currentVideoFrame != nil)")

                        // C. 连接 AI
                        print("🔌 连接 AI 服务...")
                        await MainActor.run {
                            viewModel.connect()
                        }

                        // D. 再次强制等待 1.0s
                        try? await Task.sleep(nanoseconds: 1_000_000_000)

                        // E. 最后才启动录音（仅常开麦模式）
                        await MainActor.run {
                            if viewModel.isConnected && !pushToTalkMode {
                                print("🎤 常开麦模式：启动录音...")
                                viewModel.startRecording()
                            } else if pushToTalkMode {
                                print("🎤 按住说话模式：等待按压...")
                            } else {
                                print("⚠️ LiveAIView: AI未连接，跳过录音")
                            }
                        }
                    }

                    // 4. UI 刷新
                    frameRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                        if let frame = streamViewModel.currentVideoFrame {
                            viewModel.updateVideoFrame(frame)
                            // Feed frames to video recorder when recording
                            if videoRecorder.isActive {
                                videoRecorder.appendFrame(frame)
                            }
                        }
                    }
                }
            }
        }
        .onDisappear {
            // 停止 UI 刷新定时器
            frameRefreshTimer?.invalidate()
            frameRefreshTimer = nil
            // 停止录制
            if isRecordingVideo {
                stopVideoRecording()
            }
            // 停止 AI 对话和视频流
            print("🎥 LiveAIView: 停止 AI 对话和视频流")
            viewModel.disconnect()
            Task {
                if streamViewModel.streamingStatus != .stopped {
                    await streamViewModel.stopSession()
                }
            }
        }
        .overlay {
            // Recording indicator (top center)
            if isRecordingVideo {
                VStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                        Text("REC \(formatDuration(recordingDuration)) A:\(videoRecorder.debugAudioCount)\(videoRecorder.debugLastAppendOK ? "" : "!")")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.7))
                    .cornerRadius(AppCornerRadius.sm)
                    .padding(.top, 60)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if showSavedToast {
                VStack {
                    Spacer()
                    Text("✅ 已保存到相册")
                        .font(AppTypography.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(AppCornerRadius.xl)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .alert(NSLocalizedString("error", comment: "Error"), isPresented: $viewModel.showError) {
            Button(NSLocalizedString("ok", comment: "OK")) {
                viewModel.dismissError()
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text(NSLocalizedString("liveai.title", comment: "Live AI title"))
                .font(AppTypography.headline)
                .foregroundColor(.white)

            Spacer()

            // Hide/show conversation button
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showConversation.toggle()
                }
            } label: {
                Image(systemName: showConversation ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 32, height: 32)
            }

            // Connection status
            HStack(spacing: AppSpacing.xs) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(viewModel.isConnected ? NSLocalizedString("liveai.connected", comment: "Connected") : NSLocalizedString("liveai.connecting", comment: "Connecting"))
                    .font(AppTypography.caption)
                    .foregroundColor(.white)
            }

            // Speaking indicator
            if viewModel.isSpeaking {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "waveform")
                        .foregroundColor(.green)
                    Text(NSLocalizedString("liveai.speaking", comment: "AI speaking"))
                        .font(AppTypography.caption)
                        .foregroundColor(.white)
                }
            }
        }
        .padding(AppSpacing.md)
        .background(Color.black.opacity(0.7))
    }

    // MARK: - Controls

    private var controlsView: some View {
        VStack(spacing: AppSpacing.md) {
            // Recording status
            HStack(spacing: AppSpacing.sm) {
                if viewModel.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text(pushToTalkMode ? "说话中..." : NSLocalizedString("liveai.listening", comment: "Listening"))
                        .font(AppTypography.caption)
                        .foregroundColor(.white)
                } else {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                    Text(pushToTalkMode ? "按住说话" : NSLocalizedString("liveai.stop", comment: "Stopped"))
                        .font(AppTypography.caption)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(Color.black.opacity(0.6))
            .cornerRadius(AppCornerRadius.xl)

            // Buttons row
            HStack(spacing: AppSpacing.sm) {
                // Mode toggle button
                Button {
                    pushToTalkMode.toggle()
                    if pushToTalkMode {
                        viewModel.stopRecording()
                    } else {
                        if viewModel.isConnected {
                            viewModel.startRecording()
                        }
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: pushToTalkMode ? "hand.tap.fill" : "mic.fill")
                            .font(.system(size: 16))
                        Text(pushToTalkMode ? "按住" : "常开")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .frame(width: 48, height: 48)
                    .background(pushToTalkMode ? Color.orange : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(AppCornerRadius.md)
                }

                // Camera capture button
                Button {
                    capturePhoto()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 16))
                        Text("拍照")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.2))
                    .foregroundColor(.white)
                    .cornerRadius(AppCornerRadius.md)
                }

                // Video record button
                Button {
                    print("🎬 录像按钮点击: isRecordingVideo=\(isRecordingVideo), recorder.isActive=\(videoRecorder.isActive)")
                    if isRecordingVideo || videoRecorder.isActive {
                        stopVideoRecording()
                    } else {
                        startVideoRecording()
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: isRecordingVideo ? "stop.circle.fill" : "video.fill")
                            .font(.system(size: 16))
                        Text(isRecordingVideo ? "停止" : "录像")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .frame(width: 48, height: 48)
                    .background(isRecordingVideo ? Color.red : Color.white.opacity(0.2))
                    .foregroundColor(.white)
                    .cornerRadius(AppCornerRadius.md)
                }
                .buttonStyle(.plain)

                if pushToTalkMode {
                    pushToTalkButton
                } else {
                    Spacer()
                }

                // Stop/Exit button
                Button {
                    viewModel.disconnect()
                    dismiss()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                        Text("退出")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .frame(width: 48, height: 48)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(AppCornerRadius.md)
                }
            }
            .padding(.horizontal, AppSpacing.md)
        }
        .padding(.bottom, AppSpacing.lg)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Push to Talk Button

    private var pushToTalkButton: some View {
        Image(systemName: isPressing ? "mic.fill" : "mic")
            .font(.system(size: 32, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(isPressing ? Color.red : Color.white.opacity(0.2))
            .foregroundColor(.white)
            .cornerRadius(AppCornerRadius.lg)
            .scaleEffect(isPressing ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isPressing)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressing {
                            isPressing = true
                            if viewModel.isConnected {
                                viewModel.startRecording()
                            }
                        }
                    }
                    .onEnded { _ in
                        isPressing = false
                        viewModel.stopRecording()
                    }
            )
    }

    // MARK: - Capture Photo

    private func playShutterSound() {
        AudioServicesPlaySystemSound(1108) // system photo shutter
    }

    private func playStartRecordSound() {
        AudioServicesPlaySystemSound(1117) // begin recording
    }

    private func playStopRecordSound() {
        AudioServicesPlaySystemSound(1118) // end recording
    }

    private func capturePhoto() {
        guard let frame = streamViewModel.currentVideoFrame else { return }
        playShutterSound()

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    viewModel.errorMessage = "请在设置中允许相册权限"
                    viewModel.showError = true
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: frame)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        withAnimation { showSavedToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showSavedToast = false }
                        }
                    } else {
                        viewModel.errorMessage = "保存失败: \(error?.localizedDescription ?? "")"
                        viewModel.showError = true
                    }
                }
            }
        }
    }

    // MARK: - Video Recording

    private func startVideoRecording() {
        guard let frame = streamViewModel.currentVideoFrame else { return }
        do {
            try videoRecorder.startRecording(frameSize: frame.size)
            viewModel.setVideoRecorder(videoRecorder)
            isRecordingVideo = true
            recordingDuration = 0
            playStartRecordSound()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                recordingDuration += 1
            }
            print("🎬 录像已开始")
        } catch {
            viewModel.errorMessage = "录像启动失败: \(error.localizedDescription)"
            viewModel.showError = true
        }
    }

    private func stopVideoRecording() {
        print("🎬 停止录像: isRecordingVideo=\(isRecordingVideo), recorder.isActive=\(videoRecorder.isActive)")
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecordingVideo = false

        // 先停录制（设 isRecording=false + drain queue），再断开 recorder 引用
        videoRecorder.stopRecording { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    withAnimation { showSavedToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { showSavedToast = false }
                    }
                case .failure(let error):
                    viewModel.errorMessage = "录像保存失败: \(error.localizedDescription)"
                    viewModel.showError = true
                }
            }
        }

        // stopRecording 已经同步设置了 isRecording=false，之后再断开引用
        viewModel.setVideoRecorder(nil)
        playStopRecordSound()
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - Device Not Connected View

    private var deviceNotConnectedView: some View {
        VStack(spacing: AppSpacing.xl) {
            Spacer()

            VStack(spacing: AppSpacing.lg) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 80))
                    .foregroundColor(AppColors.liveAI.opacity(0.6))

                Text(NSLocalizedString("liveai.device.notconnected.title", comment: "Device not connected"))
                    .font(AppTypography.title2)
                    .foregroundColor(AppColors.textPrimary)

                Text(NSLocalizedString("liveai.device.notconnected.message", comment: "Connection message"))
                    .font(AppTypography.body)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.xl)
            }

            Spacer()

            // Back button
            Button {
                dismiss()
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "chevron.left")
                    Text(NSLocalizedString("liveai.device.backtohome", comment: "Back to home"))
                        .font(AppTypography.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.md)
                .background(AppColors.primary)
                .foregroundColor(.white)
                .cornerRadius(AppCornerRadius.lg)
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xl)
        }
    }
}
