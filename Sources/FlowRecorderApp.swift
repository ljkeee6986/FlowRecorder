import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var strongDelegate: AppDelegate?
    private let model = AppModel()
    private var mainWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        strongDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    private func showMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = MainView(model: model)
            .frame(minWidth: 940, minHeight: 660)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "录屏大师Jack"
        window.center()
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.sharingType = .readOnly
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }

    private func configureMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "显示主窗口", action: #selector(showMainWindowFromMenu), keyEquivalent: "0"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "退出 录屏大师Jack", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let recordingMenuItem = NSMenuItem()
        let recordingMenu = NSMenu(title: "录制")
        recordingMenu.addItem(NSMenuItem(title: "开始 / 停止录制", action: #selector(toggleRecordingFromMenu), keyEquivalent: "r"))
        recordingMenuItem.submenu = recordingMenu
        mainMenu.addItem(recordingMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showMainWindowFromMenu() {
        showMainWindow()
    }

    @objc private func toggleRecordingFromMenu() {
        Task { @MainActor in
            self.model.toggleRecording()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isBusy {
            showMainWindow()
            model.status = "正在保存视频，请等“已保存”后再退出，避免生成损坏视频。"
            return .terminateCancel
        }

        if model.isRecording {
            Task { @MainActor in
                await model.stopRecording()
                NSApp.terminate(nil)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var status = "准备就绪" {
        didSet { writeStatus(status) }
    }
    @Published var outputURL: URL?
    @Published var recentRecordings: [RecordingItem] = []
    @Published var includeSystemAudio = true
    @Published var includeMicrophone = false
    @Published var microphoneDevices: [MicrophoneDevice] = []
    @Published var selectedMicrophoneDeviceID = MicrophoneDevice.systemDefaultID
    @Published var selectedCaptureRect: CGRect?
    @Published var selectedWindowID: CGWindowID?
    @Published var windowOptions: [WindowCaptureOption] = []
    @Published var isRefreshingWindows = false
    @Published var teleprompterFontSize = 28.0
    @Published var teleprompterScrollSpeed = 0.0
    @Published var teleprompterText = """
    开场先讲清楚这条视频要解决什么问题。

    录制时可以打开提词器，它会悬浮在屏幕上方便看稿。
    摄像头小窗可以拖到角落，用来做教程、演示、课程、作品讲解。
    """

    private let recorder = ScreenRecorder()

    init() {
        recorder.recoverInterruptedRecordings()
        refreshMicrophoneDevices()
        writeStatus(status)
        refreshRecordings()
    }

    func toggleRecording() {
        guard !isBusy else { return }
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        guard !isRecording, !isBusy else { return }

        if !enabled {
            includeMicrophone = false
            status = "麦克风已关闭。"
            return
        }

        Task { @MainActor in
            await enableMicrophoneAfterPermissionRequest()
        }
    }

    func startRecording() async {
        do {
            isBusy = true
            status = "正在请求屏幕录制权限..."
            if includeMicrophone {
                guard await ensureMicrophonePermissionForRecording() else {
                    isBusy = false
                    return
                }
            }

            status = "正在准备录制..."
            let microphoneDeviceID = includeMicrophone ? selectedMicrophoneDevice?.uniqueID : nil
            let captureTarget: RecorderCaptureTarget = {
                if let selectedWindowID {
                    return .window(selectedWindowID)
                }
                return .display(rect: selectedCaptureRect)
            }()
            let url = try await recorder.start(
                includeSystemAudio: includeSystemAudio,
                includeMicrophone: includeMicrophone,
                microphoneDeviceID: microphoneDeviceID,
                captureTarget: captureTarget
            )
            outputURL = nil
            isRecording = true
            isBusy = false
            status = "录制中：\(url.lastPathComponent)"
        } catch {
            isRecording = false
            isBusy = false
            status = "启动失败：\(humanReadable(error))"
            refreshRecordings()
        }
    }

    func stopRecording() async {
        guard isRecording || recorder.hasActiveRecording else { return }
        isBusy = true
        status = "正在保存视频，请不要关闭软件..."
        do {
            let url = try await recorder.stop()
            outputURL = url
            isRecording = false
            isBusy = false
            if includeSystemAudio && includeMicrophone {
                let splitName = recorder.splitTrackSiblingURL(for: url).lastPathComponent
                status = "已保存：\(url.lastPathComponent)（直接播放版）；已同时生成：\(splitName)（分轨版）"
            } else {
                status = "已保存：\(url.lastPathComponent)"
            }
            refreshRecordings()
        } catch {
            isRecording = false
            isBusy = false
            status = "保存失败：\(humanReadable(error))"
            refreshRecordings()
        }
    }

    var outputFolderURL: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let folder = movies.appendingPathComponent("FlowRecorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func openOutputFolder() {
        NSWorkspace.shared.open(outputFolderURL)
        refreshRecordings()
    }

    var selectedMicrophoneDevice: MicrophoneDevice? {
        microphoneDevices.first { $0.id == selectedMicrophoneDeviceID } ?? microphoneDevices.first
    }

    var captureAreaDescription: String {
        if let selectedWindowID,
           let option = windowOptions.first(where: { $0.id == selectedWindowID }) {
            return "窗口：\(option.shortName)"
        }
        guard let selectedCaptureRect else { return "全屏" }
        return "区域 \(Int(selectedCaptureRect.width))×\(Int(selectedCaptureRect.height))"
    }

    var selectedWindowDescription: String {
        guard let selectedWindowID,
              let option = windowOptions.first(where: { $0.id == selectedWindowID }) else {
            return "未选择窗口"
        }
        return option.displayName
    }

    func refreshMicrophoneDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )

        var devices = [MicrophoneDevice.systemDefault]
        devices.append(contentsOf: discovery.devices.map {
            MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName, uniqueID: $0.uniqueID)
        })

        microphoneDevices = devices
        if !devices.contains(where: { $0.id == selectedMicrophoneDeviceID }) {
            selectedMicrophoneDeviceID = MicrophoneDevice.systemDefaultID
        }
    }

    func selectCaptureRegion() {
        guard !isRecording, !isBusy else { return }
        status = "拖拽选择录制区域，按 Esc 取消。"
        OverlayManager.shared.selectRegion { [weak self] rect in
            Task { @MainActor in
                guard let self else { return }
                if let rect, rect.width >= 80, rect.height >= 80 {
                    self.selectedWindowID = nil
                    self.selectedCaptureRect = rect
                    self.status = "已选择录制区域：\(Int(rect.width))×\(Int(rect.height))。"
                } else {
                    self.status = "已取消区域选择。"
                }
            }
        }
    }

    func clearCaptureRegion() {
        guard !isRecording, !isBusy else { return }
        selectedWindowID = nil
        selectedCaptureRect = nil
        status = "录制范围已恢复为全屏。"
    }

    func applyCapturePreset(_ preset: CaptureAreaPreset) {
        guard !isRecording, !isBusy else { return }
        selectedWindowID = nil

        guard let screenFrame = NSScreen.main?.frame else {
            selectedCaptureRect = nil
            status = "没有找到主屏幕，已恢复为全屏。"
            return
        }

        switch preset {
        case .fullScreen:
            selectedCaptureRect = nil
            status = "录制范围已恢复为全屏。"
        case .landscape16x9, .vertical9x16, .square1x1:
            selectedCaptureRect = preset.centeredRect(in: screenFrame)
            if let selectedCaptureRect {
                status = "已套用\(preset.label)：\(Int(selectedCaptureRect.width))×\(Int(selectedCaptureRect.height))。"
            }
        }
    }

    func refreshWindowOptions() async {
        guard !isRecording, !isBusy else { return }
        isRefreshingWindows = true
        defer { isRefreshingWindows = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let options = content.windows.compactMap { window -> WindowCaptureOption? in
                guard let app = window.owningApplication,
                      app.processID != ownPID,
                      window.frame.width >= 160,
                      window.frame.height >= 100 else {
                    return nil
                }

                let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let safeTitle = title.isEmpty ? "未命名窗口" : title
                return WindowCaptureOption(
                    id: window.windowID,
                    appName: app.applicationName,
                    title: safeTitle,
                    width: Int(window.frame.width),
                    height: Int(window.frame.height)
                )
            }

            var seen = Set<CGWindowID>()
            windowOptions = options.filter { option in
                if seen.contains(option.id) { return false }
                seen.insert(option.id)
                return true
            }
            .prefix(24)
            .map { $0 }

            if let selectedWindowID, !windowOptions.contains(where: { $0.id == selectedWindowID }) {
                self.selectedWindowID = nil
                selectedCaptureRect = nil
                status = "原窗口已关闭，录制范围已恢复为全屏。"
            } else if !windowOptions.isEmpty {
                status = "已刷新窗口列表，可选择 PPT、微信、浏览器或 Codex 窗口录制。"
            } else {
                status = "没有找到可录制窗口，仍可使用全屏或区域录制。"
            }
        } catch {
            status = "刷新窗口列表失败：\(humanReadable(error))"
        }
    }

    func selectWindow(_ option: WindowCaptureOption) {
        guard !isRecording, !isBusy else { return }
        selectedWindowID = option.id
        selectedCaptureRect = nil
        status = "已选择窗口录制：\(option.displayName)。窗口内容会跟随该窗口变化。"
    }

    func reveal(_ item: RecordingItem) {
        NSWorkspace.shared.open(item.url.deletingLastPathComponent())
    }

    func refreshRecordings() {
        let folder = outputFolderURL
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        recentRecordings = urls
            .filter {
                $0.pathExtension.lowercased() == "mp4"
                && !$0.deletingPathExtension().lastPathComponent.hasSuffix("_分轨版")
            }
            .compactMap { RecordingItem(url: $0) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(6)
            .map { $0 }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    private func humanReadable(_ error: Error) -> String {
        if let recorderError = error as? RecorderError {
            return recorderError.localizedDescription
        }

        let message = error.localizedDescription
        if message.contains("TCC") || message.contains("拒绝") || message.contains("denied") {
            return "没有屏幕与系统音频录制权限。请到系统设置里允许录屏大师Jack，然后重新打开应用。"
        }
        return message
    }

    private func enableMicrophoneAfterPermissionRequest() async {
        isBusy = true
        status = "正在请求麦克风权限..."

        let granted = await requestMicrophoneAccessIfNeeded()
        isBusy = false

        if granted {
            refreshMicrophoneDevices()
            includeMicrophone = true
            let deviceName = selectedMicrophoneDevice?.name ?? AVCaptureDevice.default(for: .audio)?.localizedName ?? "默认麦克风"
            status = "麦克风已开启：\(deviceName)。开始录制后会同时收进人声。"
        } else {
            includeMicrophone = false
            status = "麦克风权限未开启，已保持关闭。"
        }
    }

    private func ensureMicrophonePermissionForRecording() async -> Bool {
        let granted = await requestMicrophoneAccessIfNeeded()
        if granted { return true }

        includeMicrophone = false
        status = "麦克风权限未开启，已取消本次录制。你也可以关闭麦克风只录系统声音。"
        return false
    }

    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    private func writeStatus(_ value: String) {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let folder = movies.appendingPathComponent("FlowRecorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("status.txt")
        let text = "[\(Date())] \(value)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

struct MicrophoneDevice: Identifiable, Hashable {
    static let systemDefaultID = "system-default"
    static let systemDefault = MicrophoneDevice(id: systemDefaultID, name: "系统默认麦克风", uniqueID: nil)

    let id: String
    let name: String
    let uniqueID: String?
}

enum CaptureAreaPreset: String, CaseIterable, Identifiable {
    case fullScreen
    case landscape16x9
    case vertical9x16
    case square1x1

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullScreen:
            return "全屏"
        case .landscape16x9:
            return "16:9 横屏"
        case .vertical9x16:
            return "9:16 竖屏"
        case .square1x1:
            return "1:1 方形"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .fullScreen:
            return nil
        case .landscape16x9:
            return 16.0 / 9.0
        case .vertical9x16:
            return 9.0 / 16.0
        case .square1x1:
            return 1.0
        }
    }

    func centeredRect(in screenFrame: CGRect) -> CGRect? {
        guard let ratio else { return nil }

        let margin: CGFloat = 72
        let maxWidth = max(160, screenFrame.width - margin * 2)
        let maxHeight = max(100, screenFrame.height - margin * 2)

        var width = maxWidth
        var height = width / ratio
        if height > maxHeight {
            height = maxHeight
            width = height * ratio
        }

        let evenWidth = CGFloat(max(80, Int(width) - Int(width) % 2))
        let evenHeight = CGFloat(max(80, Int(height) - Int(height) % 2))
        return CGRect(
            x: screenFrame.midX - evenWidth / 2,
            y: screenFrame.midY - evenHeight / 2,
            width: evenWidth,
            height: evenHeight
        ).integral
    }
}

struct WindowCaptureOption: Identifiable, Hashable {
    let id: CGWindowID
    let appName: String
    let title: String
    let width: Int
    let height: Int

    var shortName: String {
        title == "未命名窗口" ? appName : title
    }

    var displayName: String {
        "\(appName) · \(shortName) · \(width)×\(height)"
    }
}

enum RecorderCaptureTarget {
    case display(rect: CGRect?)
    case window(CGWindowID)
}

struct RecordingItem: Identifiable {
    let id = UUID()
    let url: URL
    let modifiedAt: Date
    let size: Int64

    init?(url: URL) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        self.url = url
        self.modifiedAt = values?.contentModificationDate ?? .distantPast
        self.size = Int64(values?.fileSize ?? 0)
    }

    var displayName: String {
        url.lastPathComponent
    }

    var detail: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "\(formatter.string(from: modifiedAt)) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var cameraShown = false
    @State private var teleprompterShown = false

    private let panelRadius: CGFloat = 18
    private let freshBlue = Color(red: 0.16, green: 0.48, blue: 0.95)
    private let freshMint = Color(red: 0.13, green: 0.72, blue: 0.67)
    private let freshIndigo = Color(red: 0.44, green: 0.42, blue: 0.92)
    private let ink = Color(red: 0.13, green: 0.17, blue: 0.23)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.99, blue: 1.00),
                    Color(red: 0.91, green: 0.98, blue: 0.98),
                    Color(red: 0.98, green: 0.97, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    HStack(alignment: .top, spacing: 16) {
                        recordingHero.frame(minWidth: 290, maxWidth: 330)
                        VStack(spacing: 16) {
                            quickTools
                            sourcePanel
                        }
                        .frame(maxWidth: .infinity)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        teleprompterPanel.frame(maxWidth: .infinity)
                        recordingsPanel.frame(width: 380)
                    }
                    statusBox
                }
                .padding(32)
            }
        }
        .onAppear {
            Task { await model.refreshWindowOptions() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(freshBlue.opacity(0.10), lineWidth: 1))
                    .shadow(color: freshBlue.opacity(0.08), radius: 10, x: 0, y: 6)
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.red, freshBlue)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text("录屏大师Jack")
                    .font(.system(size: 29, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                Text("轻量录屏、清晰收声、悬浮摄像头和可滚动提词器。")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                copyrightNotice
                    .padding(.top, 3)
            }
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        let text = model.isRecording ? "REC" : (model.isBusy ? "SAVING" : "READY")
        let tint = model.isRecording ? Color.red : (model.isBusy ? Color.orange : freshMint)
        return HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.74))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.white.opacity(0.88), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.12), lineWidth: 1))
        .shadow(color: tint.opacity(0.10), radius: 12, x: 0, y: 6)
    }

    private var recordingHero: some View {
        freshPanel {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.isRecording ? "正在录制" : "准备开始")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text(model.isRecording ? "录制中请保持窗口状态稳定" : "确认来源后，一键开始录制")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.toggleRecording()
                } label: {
                    ZStack {
                        Circle()
                            .fill(model.isRecording ? Color.red.gradient : freshBlue.gradient)
                            .frame(width: 108, height: 108)
                            .shadow(color: (model.isRecording ? Color.red : freshBlue).opacity(0.22), radius: 20, x: 0, y: 12)
                        Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isBusy)
                HStack {
                    Label("快捷键 ⌘R", systemImage: "keyboard")
                    Spacer()
                    Text(model.isBusy ? "正在处理..." : "状态稳定")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var quickTools: some View {
        HStack(spacing: 12) {
            actionButton(
                title: model.isRecording ? "摄像头锁定" : (cameraShown ? "关闭摄像头" : "摄像头小窗"),
                subtitle: model.isRecording ? "录制前设置" : "圆形悬浮",
                icon: "video.fill",
                tint: freshIndigo
            ) {
                if cameraShown { OverlayManager.shared.hideCamera() } else { OverlayManager.shared.showCamera() }
                cameraShown.toggle()
            }
            .disabled(model.isRecording || model.isBusy)
            .allowsHitTesting(!model.isRecording && !model.isBusy)

            actionButton(
                title: model.isRecording ? "提词器锁定" : (teleprompterShown ? "隐藏提词器" : "打开提词器"),
                subtitle: model.isRecording ? "录制前设置" : "可滚动",
                icon: "text.alignleft",
                tint: freshMint
            ) {
                if teleprompterShown {
                    OverlayManager.shared.hideTeleprompter()
                } else {
                    OverlayManager.shared.showTeleprompter(text: model.teleprompterText, fontSize: model.teleprompterFontSize, scrollSpeed: model.teleprompterScrollSpeed)
                }
                teleprompterShown.toggle()
            }
            .disabled(model.isRecording || model.isBusy)
            .allowsHitTesting(!model.isRecording && !model.isBusy)
        }
    }

    private func actionButton(title: String, subtitle: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(13)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(tint.opacity(0.12), lineWidth: 1))
            .shadow(color: tint.opacity(0.06), radius: 8, x: 0, y: 5)
        }
        .buttonStyle(.plain)
    }

    private var sourcePanel: some View {
        freshPanel {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("录制源", "分清电脑声和人声，方便直接播放和后期处理")
                VStack(spacing: 0) {
                    sourceToggleCard(title: "系统声音", subtitle: model.includeSystemAudio ? "电脑内部声音" : "关闭", icon: "speaker.wave.2.fill", tint: freshBlue, isOn: $model.includeSystemAudio)
                        .disabled(model.isRecording || model.isBusy)
                    Divider().opacity(0.42).padding(.leading, 46)
                    sourceToggleCard(title: "麦克风", subtitle: model.includeMicrophone ? "人声讲解" : "关闭", icon: "mic.fill", tint: Color(red: 0.96, green: 0.45, blue: 0.55), isOn: Binding(get: { model.includeMicrophone }, set: { model.setMicrophoneEnabled($0) }))
                        .disabled(model.isRecording || model.isBusy)
                }
                if model.includeMicrophone {
                    microphonePicker
                }
                captureAreaControl
                Text(model.includeMicrophone ? "会生成直接播放版；同时保留分轨版，方便后期分开调声音。" : "只录系统声时，文件更轻。需要讲解人声时再打开麦克风。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var microphonePicker: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.96, green: 0.45, blue: 0.55))
                .frame(width: 30, height: 30)
                .background(Color(red: 0.96, green: 0.45, blue: 0.55).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("输入")
                .font(.system(size: 13, weight: .semibold))
            Picker("", selection: $model.selectedMicrophoneDeviceID) {
                ForEach(model.microphoneDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(model.isRecording || model.isBusy)
            Button {
                model.refreshMicrophoneDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isRecording || model.isBusy)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var captureAreaControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "crop")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(freshMint)
                    .frame(width: 30, height: 30)
                    .background(freshMint.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("录制范围")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.captureAreaDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("选择区域") {
                    model.selectCaptureRegion()
                }
                .buttonStyle(.bordered)
                .disabled(model.isRecording || model.isBusy)
                Button("全屏") {
                    model.clearCaptureRegion()
                }
                .buttonStyle(.borderless)
                .disabled(model.isRecording || model.isBusy || (model.selectedCaptureRect == nil && model.selectedWindowID == nil))
            }

            HStack(spacing: 10) {
                Text("比例模板")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(CaptureAreaPreset.allCases) { preset in
                    Button(preset.label) {
                        model.applyCapturePreset(preset)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isRecording || model.isBusy)
                }
            }

            HStack(spacing: 10) {
                Text("窗口录制")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Menu {
                    Button("刷新窗口列表") {
                        Task { await model.refreshWindowOptions() }
                    }
                    Divider()
                    if model.windowOptions.isEmpty {
                        Text("暂无可选窗口")
                    } else {
                        ForEach(model.windowOptions) { option in
                            Button(option.displayName) {
                                model.selectWindow(option)
                            }
                        }
                    }
                } label: {
                    Label(model.selectedWindowDescription, systemImage: "macwindow")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .disabled(model.isRecording || model.isBusy || model.isRefreshingWindows)

                Button {
                    Task { await model.refreshWindowOptions() }
                } label: {
                    Image(systemName: model.isRefreshingWindows ? "hourglass" : "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRecording || model.isBusy || model.isRefreshingWindows)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sourceToggleCard(title: String, subtitle: String, icon: String, tint: Color, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(tint)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 4)
    }

    private var teleprompterPanel: some View {
        freshPanel {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("提词器", "拖动窗口位置，拉伸边缘改大小")
                HStack(spacing: 16) {
                    sliderControl(title: "字体", valueText: "\(Int(model.teleprompterFontSize))", value: $model.teleprompterFontSize, range: 18...52, step: 1)
                        .disabled(model.isRecording || model.isBusy)
                    sliderControl(title: "滚动", valueText: model.teleprompterScrollSpeed == 0 ? "手动" : "\(Int(model.teleprompterScrollSpeed))", value: $model.teleprompterScrollSpeed, range: 0...90, step: 5)
                        .disabled(model.isRecording || model.isBusy)
                }
                .onChange(of: model.teleprompterFontSize) { _, _ in syncTeleprompter() }
                .onChange(of: model.teleprompterScrollSpeed) { _, _ in syncTeleprompter() }
                TextEditor(text: $model.teleprompterText)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
                    .padding(12)
                    .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(freshBlue.opacity(0.08), lineWidth: 1))
                    .onChange(of: model.teleprompterText) { _, _ in syncTeleprompter() }
                Text("滚动为 0 时手动滚动；录制期间锁定提词器设置，避免窗口变化导致录制异常。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sliderControl(title: String, valueText: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(valueText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step).tint(freshBlue)
        }
    }

    private var recordingsPanel: some View {
        freshPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    sectionHeader("最近录屏", "普通播放版会显示在这里")
                    Spacer()
                    Button { model.refreshRecordings() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                    Button { model.openOutputFolder() } label: { Label("文件夹", systemImage: "folder") }.buttonStyle(.borderedProminent).tint(freshBlue)
                }
                if model.recentRecordings.isEmpty {
                    Text("还没有保存好的录屏。").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                } else {
                    VStack(spacing: 7) {
                        ForEach(model.recentRecordings) { item in recordingRow(item) }
                    }
                }
            }
        }
    }

    private func recordingRow(_ item: RecordingItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill").foregroundStyle(freshBlue).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { NSWorkspace.shared.open(item.url) } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless)
            Button { model.reveal(item) } label: { Image(systemName: "folder") }.buttonStyle(.borderless)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.70), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(freshBlue.opacity(0.07), lineWidth: 1))
    }

    private var statusBox: some View {
        freshPanel {
            HStack(spacing: 12) {
                Image(systemName: model.status.contains("失败") ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(model.status.contains("失败") ? .orange : freshMint)
                    .font(.system(size: 20, weight: .semibold))
                Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if let url = model.outputURL {
                    Button { NSWorkspace.shared.open(url.deletingLastPathComponent()) } label: { Label("查看文件", systemImage: "folder") }.buttonStyle(.bordered)
                }
                if model.status.contains("麦克风") && model.status.contains("权限") {
                    Button { model.openMicrophoneSettings() } label: { Label("麦克风权限", systemImage: "mic") }.buttonStyle(.borderedProminent).tint(.orange)
                } else if model.status.contains("权限") {
                    Button { model.openPrivacySettings() } label: { Label("权限设置", systemImage: "lock.open") }.buttonStyle(.borderedProminent).tint(.orange)
                }
            }
        }
    }

    private var copyrightNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 13, weight: .semibold))
            Text("免费工具 · 禁止商用 · 侵权必究")
                .font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .foregroundStyle(Color(red: 0.42, green: 0.43, blue: 0.48))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(ink)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func freshPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: panelRadius, style: .continuous).stroke(Color.white.opacity(0.92), lineWidth: 1))
            .shadow(color: Color(red: 0.36, green: 0.57, blue: 0.78).opacity(0.075), radius: 14, x: 0, y: 8)
    }

    private func syncTeleprompter() {
        if teleprompterShown {
            OverlayManager.shared.updateTeleprompter(text: model.teleprompterText, fontSize: model.teleprompterFontSize, scrollSpeed: model.teleprompterScrollSpeed)
        }
    }
}
final class OverlayManager {
    static let shared = OverlayManager()

    private var cameraWindow: NSWindow?
    private var teleprompterWindow: NSWindow?
    private var teleprompterHost: NSHostingView<TeleprompterOverlayView>?
    private var regionSelectionWindow: NSWindow?

    func showCamera() {
        if cameraWindow != nil {
            cameraWindow?.makeKeyAndOrderFront(nil)
            return
        }

        let content = CameraPreviewView()
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 64, y: 120, width: 220, height: 220),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .none
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = true
        window.sharingType = .readOnly
        window.makeKeyAndOrderFront(nil)
        cameraWindow = window
    }

    func hideCamera() {
        // Keep the preview view alive when hiding. Destroying AVCaptureVideoPreviewLayer
        // while AVFoundation is still winding down can crash on macOS.
        cameraWindow?.orderOut(nil)
    }

    func showTeleprompter(text: String, fontSize: Double, scrollSpeed: Double) {
        if teleprompterWindow != nil {
            updateTeleprompter(text: text, fontSize: fontSize, scrollSpeed: scrollSpeed)
            teleprompterWindow?.makeKeyAndOrderFront(nil)
            return
        }

        let host = NSHostingView(rootView: TeleprompterOverlayView(
            text: text,
            fontSize: fontSize,
            scrollSpeed: scrollSpeed
        ))
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 200, y: 200, width: 900, height: 260)
        let rect = NSRect(x: screenFrame.midX - 460, y: screenFrame.maxY - 270, width: 920, height: 220)
        let window = NSWindow(contentRect: rect,
                              styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .none
        window.title = "提词器"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 120)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = true
        window.sharingType = .none
        window.makeKeyAndOrderFront(nil)
        teleprompterHost = host
        teleprompterWindow = window
    }

    func updateTeleprompter(text: String, fontSize: Double, scrollSpeed: Double) {
        teleprompterHost?.rootView = TeleprompterOverlayView(
            text: text,
            fontSize: fontSize,
            scrollSpeed: scrollSpeed
        )
    }

    func hideTeleprompter() {
        teleprompterWindow?.orderOut(nil)
    }

    func selectRegion(completion: @escaping (CGRect?) -> Void) {
        if regionSelectionWindow != nil {
            regionSelectionWindow?.makeKeyAndOrderFront(nil)
            return
        }

        guard let screen = NSScreen.main else {
            completion(nil)
            return
        }

        let screenFrame = screen.frame
        let selectionView = RegionSelectionView(frame: NSRect(origin: .zero, size: screenFrame.size))
        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        selectionView.onComplete = { [weak self, weak window] rect in
            let globalRect: CGRect?
            if let rect {
                globalRect = CGRect(
                    x: screenFrame.minX + rect.minX,
                    y: screenFrame.minY + rect.minY,
                    width: rect.width,
                    height: rect.height
                )
            } else {
                globalRect = nil
            }

            window?.orderOut(nil)
            self?.regionSelectionWindow = nil
            completion(globalRect)
        }

        window.contentView = selectionView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(selectionView)
        regionSelectionWindow = window
    }
}

final class RegionSelectionView: NSView {
    var onComplete: ((CGRect?) -> Void)?
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        window?.acceptsMouseMovedEvents = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.36).setFill()
        bounds.fill()

        if let selection = selectionRect {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            selection.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(roundedRect: selection, xRadius: 8, yRadius: 8)
            path.lineWidth = 3
            path.stroke()

            let label = "\(Int(selection.width)) × \(Int(selection.height))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            label.draw(at: CGPoint(x: selection.minX + 12, y: selection.maxY - 28), withAttributes: attributes)
        } else {
            let text = "拖拽选择录制区域 · Esc 取消"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = event.locationInWindow
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = event.locationInWindow
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = event.locationInWindow
        guard let selection = selectionRect, selection.width >= 80, selection.height >= 80 else {
            onComplete?(nil)
            return
        }
        onComplete?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onComplete?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
    }
}

struct CameraPreviewView: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView()
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {}
}

final class CameraPreviewNSView: NSView {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.jackliu.flowrecorder.camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 110
        layer?.borderWidth = 3
        layer?.borderColor = NSColor.white.withAlphaComponent(0.75).cgColor
        setupCamera()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupCamera()
    }

    deinit {
        stopPreview(removeLayer: false)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        previewLayer?.frame = bounds
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopPreview(removeLayer: false)
        }
    }

    private func setupCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.sessionQueue.async { [weak self] in
                guard let self else { return }
                self.session.beginConfiguration()
                self.session.sessionPreset = .medium
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    return
                }
                self.session.addInput(input)
                self.session.commitConfiguration()

                DispatchQueue.main.async {
                    let layer = AVCaptureVideoPreviewLayer(session: self.session)
                    layer.videoGravity = .resizeAspectFill
                    layer.frame = self.bounds
                    self.layer?.insertSublayer(layer, at: 0)
                    self.previewLayer = layer
                    self.sessionQueue.async { [weak self] in
                        guard let self else { return }
                        self.session.startRunning()
                    }
                }
            }
        }
    }

    private func stopPreview(removeLayer: Bool = true) {
        let session = session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }

        if removeLayer {
            let layer = previewLayer
            previewLayer = nil
            layer?.removeFromSuperlayer()
        }
    }
}

struct TeleprompterOverlayView: View {
    let text: String
    let fontSize: Double
    let scrollSpeed: Double

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black.opacity(0.62))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                )

            AutoScrollingTeleprompterView(
                text: text,
                fontSize: fontSize,
                scrollSpeed: scrollSpeed
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .padding(10)
        }
        .padding(2)
    }
}

struct AutoScrollingTeleprompterView: NSViewRepresentable {
    let text: String
    let fontSize: Double
    let scrollSpeed: Double

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textColor = .white
        textView.insertionPointColor = .clear
        textView.textContainerInset = NSSize(width: 22, height: 20)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.apply(text: text, fontSize: fontSize, scrollSpeed: scrollSpeed)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.scrollView = scrollView
        context.coordinator.apply(text: text, fontSize: fontSize, scrollSpeed: scrollSpeed)
    }

    final class Coordinator {
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        private var timer: Timer?
        private var lastText = ""
        private var lastFontSize = 0.0
        private var lastScrollSpeed = -1.0

        deinit {
            timer?.invalidate()
        }

        func apply(text: String, fontSize: Double, scrollSpeed: Double) {
            if text != lastText || abs(fontSize - lastFontSize) > 0.1 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = max(6, fontSize * 0.25)
                let attributed = NSAttributedString(
                    string: text.isEmpty ? " " : text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                        .foregroundColor: NSColor.white,
                        .paragraphStyle: paragraph
                    ]
                )
                textView?.textStorage?.setAttributedString(attributed)
                textView?.layoutManager?.ensureLayout(for: textView?.textContainer ?? NSTextContainer())
                lastText = text
                lastFontSize = fontSize
            }

            if abs(scrollSpeed - lastScrollSpeed) > 0.1 {
                lastScrollSpeed = scrollSpeed
                restartTimer(scrollSpeed: scrollSpeed)
            }
        }

        private func restartTimer(scrollSpeed: Double) {
            timer?.invalidate()
            timer = nil
            guard scrollSpeed > 0 else { return }

            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.tick(scrollSpeed: scrollSpeed)
            }
            if let timer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        private func tick(scrollSpeed: Double) {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let clipView = scrollView.contentView
            var origin = clipView.bounds.origin
            let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
            guard maxY > 0 else { return }

            origin.y = min(maxY, origin.y + scrollSpeed / 30.0)
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}

enum RecorderError: LocalizedError {
    case noDisplay
    case windowNotFound
    case writerNotReady
    case screenRecordingPermission
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "没有找到可录制的显示器。"
        case .windowNotFound:
            return "选择的窗口已经关闭或不可录制，请重新刷新窗口列表后再选。"
        case .writerNotReady:
            return "录制文件还没有准备好。"
        case .screenRecordingPermission:
            return "没有屏幕与系统音频录制权限。请到系统设置里允许录屏大师Jack，然后重新打开应用。"
        case .saveFailed(let message):
            return "视频保存失败：\(message)"
        }
    }
}

final class ScreenRecorder: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var startTime: CMTime?
    private var finalOutputURL: URL?
    private var temporaryOutputURL: URL?
    private var expectedAudioTrackCount = 0
    private var videoSampleCount = 0
    private var audioSampleCount = 0
    private var microphoneSampleCount = 0
    private var firstVideoFrameContinuation: CheckedContinuation<Void, Error>?
    private var isFinishing = false
    private let queue = DispatchQueue(label: "com.jackliu.flowrecorder.writer")

    var hasActiveRecording: Bool {
        stream != nil || writer != nil
    }

    func start(includeSystemAudio: Bool, includeMicrophone: Bool, microphoneDeviceID: String?, captureTarget: RecorderCaptureTarget) async throws -> URL {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let destination = makeOutputDestination()
        let writer = try AVAssetWriter(outputURL: destination.temporaryURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let captureSetup = try makeCaptureSetup(
            target: captureTarget,
            content: content,
            display: display
        )
        let width = captureSetup.width
        let height = captureSetup.height
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecorderError.saveFailed("视频输入初始化失败")
        }
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000
        ]

        var audioInput: AVAssetWriterInput?
        if includeSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecorderError.saveFailed("系统声音输入初始化失败")
            }
            writer.add(input)
            audioInput = input
        }

        var microphoneInput: AVAssetWriterInput?
        if includeMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecorderError.saveFailed("麦克风输入初始化失败")
            }
            writer.add(input)
            microphoneInput = input
        }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let sourceRect = captureSetup.sourceRect {
            config.sourceRect = sourceRect
            config.destinationRect = CGRect(x: 0, y: 0, width: width, height: height)
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6
        config.showsCursor = true
        config.capturesAudio = includeSystemAudio
        config.captureMicrophone = includeMicrophone
        if includeMicrophone, let microphoneDeviceID {
            config.microphoneCaptureDeviceID = microphoneDeviceID
        }
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: captureSetup.filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if includeSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if includeMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }

        self.stream = stream
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.microphoneInput = microphoneInput
        self.finalOutputURL = destination.finalURL
        self.temporaryOutputURL = destination.temporaryURL
        self.expectedAudioTrackCount = (includeSystemAudio ? 1 : 0) + (includeMicrophone ? 1 : 0)
        self.videoSampleCount = 0
        self.audioSampleCount = 0
        self.microphoneSampleCount = 0
        self.startTime = nil
        self.isFinishing = false

        do {
            try await stream.startCapture()
            try await waitForFirstVideoFrame(timeout: 4)
            return destination.finalURL
        } catch {
            try? await stream.stopCapture()
            try? FileManager.default.removeItem(at: destination.temporaryURL)
            resetAfterStop()
            throw error
        }
    }

    func stop() async throws -> URL {
        guard let stream, let writer, let finalOutputURL, let temporaryOutputURL else {
            throw RecorderError.writerNotReady
        }

        do {
            var stopCaptureError: Error?
            do {
                try await stream.stopCapture()
            } catch {
                stopCaptureError = error
            }

            let actualAudioTrackCount = currentExpectedWrittenAudioTrackCount()
            try await finishWriter(writer)
            try await validatePlayableMovie(at: temporaryOutputURL, expectedAudioTracks: actualAudioTrackCount)
            let savedURL: URL
            if actualAudioTrackCount > 1 {
                savedURL = try await saveMixedPlaybackAndSplitTrackVersions(from: temporaryOutputURL, to: finalOutputURL)
            } else {
                savedURL = try commitTemporaryRecording(from: temporaryOutputURL, to: finalOutputURL)
            }
            if let stopCaptureError {
                appendRecorderNote("stopCapture 抛错但文件已成功封装：\(saveFailureText(from: stopCaptureError))")
            }
            resetAfterStop()
            return savedURL
        } catch {
            cancelWriterIfNeeded(writer)
            let moved = quarantineBrokenFile(temporaryOutputURL)
            resetAfterStop()
            throw RecorderError.saveFailed(failureMessage(saveFailureText(from: error), moved: moved))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        guard !isFinishing, let writer = self.writer else { return }

        if startTime == nil, type == .screen {
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            startTime = time
            writer.startWriting()
            writer.startSession(atSourceTime: time)
        }

        guard startTime != nil, writer.status == .writing else { return }

        switch type {
        case .screen:
            if let videoInput, videoInput.isReadyForMoreMediaData {
                if videoInput.append(sampleBuffer) {
                    videoSampleCount += 1
                    resumeFirstVideoFrameWaiterIfNeeded()
                }
            }
        case .audio:
            if let audioInput, audioInput.isReadyForMoreMediaData {
                if audioInput.append(sampleBuffer) {
                    audioSampleCount += 1
                }
            }
        case .microphone:
            if let microphoneInput, microphoneInput.isReadyForMoreMediaData {
                if microphoneInput.append(sampleBuffer) {
                    microphoneSampleCount += 1
                }
            }
        @unknown default:
            break
        }
    }

    func recoverInterruptedRecordings() {
        let tempFolder = inProgressFolderURL()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: tempFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in urls where url.pathExtension.lowercased() == "mp4" {
            _ = quarantineBrokenFile(url)
        }
    }

    private func makeOutputDestination() -> (finalURL: URL, temporaryURL: URL) {
        let folder = recordingsFolderURL()
        let tempFolder = inProgressFolderURL()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let baseName = "录屏大师Jack-\(formatter.string(from: Date()))"

        var finalURL = folder.appendingPathComponent("\(baseName).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: finalURL.path) {
            finalURL = folder.appendingPathComponent("\(baseName)-\(counter).mp4")
            counter += 1
        }

        let tempName = "\(finalURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).recording.mp4"
        let temporaryURL = tempFolder.appendingPathComponent(tempName)
        try? FileManager.default.removeItem(at: temporaryURL)
        return (finalURL, temporaryURL)
    }

    private func finishWriter(_ writer: AVAssetWriter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.isFinishing = true

                guard self.videoSampleCount > 0 else {
                    writer.cancelWriting()
                    continuation.resume(throwing: RecorderError.saveFailed("没有收到屏幕画面，录制没有真正开始。\(self.writerDiagnostics())"))
                    return
                }

                if writer.status == .failed {
                    let message = writer.error?.localizedDescription ?? "写入器已经进入失败状态"
                    continuation.resume(throwing: RecorderError.saveFailed(message))
                    return
                }

                if writer.status == .unknown {
                    writer.cancelWriting()
                    continuation.resume(throwing: RecorderError.saveFailed("没有收到有效画面，录制时间可能太短。\(self.writerDiagnostics())"))
                    return
                }

                guard writer.status == .writing else {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: RecorderError.saveFailed("写入器状态异常：\(writer.status.rawValue)。\(self.writerDiagnostics())"))
                    }
                    return
                }

                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.microphoneInput?.markAsFinished()

                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                        return
                    }

                    let message = writer.error?.localizedDescription ?? "文件没有完成封装"
                    continuation.resume(throwing: RecorderError.saveFailed("\(message)。\(self.writerDiagnostics())"))
                }
            }
        }
    }

    private func currentExpectedWrittenAudioTrackCount() -> Int {
        queue.sync {
            (audioSampleCount > 0 ? 1 : 0) + (microphoneSampleCount > 0 ? 1 : 0)
        }
    }

    private func writerDiagnostics() -> String {
        "样本统计：画面 \(videoSampleCount)，系统声 \(audioSampleCount)，麦克风 \(microphoneSampleCount)"
    }

    private func makeCaptureSetup(
        target: RecorderCaptureTarget,
        content: SCShareableContent,
        display: SCDisplay
    ) throws -> (filter: SCContentFilter, sourceRect: CGRect?, width: Int, height: Int) {
        switch target {
        case .display(let captureRect):
            let displayFrame = display.frame
            let sourceRect = normalizedSourceRect(captureRect, displayFrame: displayFrame)
            let size = normalizedVideoSize(from: sourceRect.size)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            return (
                filter: filter,
                sourceRect: captureRect == nil ? nil : sourceRect,
                width: size.width,
                height: size.height
            )

        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecorderError.windowNotFound
            }

            let size = normalizedVideoSize(from: window.frame.size)
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return (
                filter: filter,
                sourceRect: nil,
                width: size.width,
                height: size.height
            )
        }
    }

    private func normalizedVideoSize(from size: CGSize) -> (width: Int, height: Int) {
        let rawWidth = max(80, Int(size.width.rounded(.down)))
        let rawHeight = max(80, Int(size.height.rounded(.down)))
        let width = max(80, rawWidth - rawWidth % 2)
        let height = max(80, rawHeight - rawHeight % 2)
        return (width, height)
    }

    private func normalizedSourceRect(_ captureRect: CGRect?, displayFrame: CGRect) -> CGRect {
        let fallback = CGRect(x: 0, y: 0, width: max(1, displayFrame.width), height: max(1, displayFrame.height))
        guard let captureRect else { return fallback }

        let clipped = captureRect.intersection(displayFrame)
        guard clipped.width >= 80, clipped.height >= 80 else { return fallback }

        var localRect = CGRect(
            x: max(0, clipped.minX - displayFrame.minX),
            y: max(0, clipped.minY - displayFrame.minY),
            width: min(clipped.width, displayFrame.width),
            height: min(clipped.height, displayFrame.height)
        ).integral

        localRect.size.width = CGFloat(max(80, Int(localRect.width) - Int(localRect.width) % 2))
        localRect.size.height = CGFloat(max(80, Int(localRect.height) - Int(localRect.height) % 2))

        guard localRect.width >= 80, localRect.height >= 80 else { return fallback }
        return localRect
    }

    private func validatePlayableMovie(at url: URL, expectedAudioTracks: Int) async throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize > 64_000 else {
            throw RecorderError.saveFailed("文件过小，可能没有完整写入")
        }

        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        let hasVideo = tracks.contains { $0.mediaType == .video }
        let audioTrackCount = tracks.filter { $0.mediaType == .audio }.count

        guard isPlayable, duration.seconds.isFinite, duration.seconds > 0.1, hasVideo else {
            throw RecorderError.saveFailed("文件封装不完整，播放器无法打开")
        }

        guard audioTrackCount >= expectedAudioTracks else {
            throw RecorderError.saveFailed("音频没有完整写入，预计 \(expectedAudioTracks) 条音轨，实际 \(audioTrackCount) 条")
        }
    }

    private func waitForFirstVideoFrame(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.videoSampleCount > 0 {
                    continuation.resume()
                    return
                }

                self.firstVideoFrameContinuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard let continuation = self.firstVideoFrameContinuation else { return }
                    self.firstVideoFrameContinuation = nil
                    continuation.resume(throwing: RecorderError.saveFailed("启动后没有收到屏幕画面，请重新开始录制"))
                }
            }
        }
    }

    private func resumeFirstVideoFrameWaiterIfNeeded() {
        guard let continuation = firstVideoFrameContinuation else { return }
        firstVideoFrameContinuation = nil
        continuation.resume()
    }

    func splitTrackSiblingURL(for url: URL) -> URL {
        let baseName = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(baseName)_分轨版.mp4")
    }

    private func saveMixedPlaybackAndSplitTrackVersions(from temporaryURL: URL, to finalURL: URL) async throws -> URL {
        let splitURL = splitTrackSiblingURL(for: finalURL)
        let mixedURL = temporaryURL.deletingLastPathComponent()
            .appendingPathComponent("\(temporaryURL.deletingPathExtension().lastPathComponent)-mixed.mp4")

        try? FileManager.default.removeItem(at: splitURL)
        try? FileManager.default.removeItem(at: mixedURL)

        do {
            let actualAudioTrackCount = currentExpectedWrittenAudioTrackCount()
            try FileManager.default.copyItem(at: temporaryURL, to: splitURL)
            try await validatePlayableMovie(at: splitURL, expectedAudioTracks: actualAudioTrackCount)

            try await exportMixedAudioMovie(from: splitURL, to: mixedURL)
            try await validatePlayableMovie(at: mixedURL, expectedAudioTracks: 1)

            try? FileManager.default.removeItem(at: temporaryURL)
            return try commitTemporaryRecording(from: mixedURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: mixedURL)
            throw error
        }
    }

    private func exportMixedAudioMovie(from sourceURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard let videoTrack = videoTracks.first else {
            throw RecorderError.saveFailed("混音前没有找到视频轨")
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecorderError.saveFailed("混音视频轨初始化失败")
        }

        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: videoTrack,
            at: .zero
        )
        compositionVideoTrack.preferredTransform = try await videoTrack.load(.preferredTransform)

        var audioParameters: [AVMutableAudioMixInputParameters] = []
        for (index, audioTrack) in audioTracks.enumerated() {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw RecorderError.saveFailed("混音音频轨初始化失败")
            }

            try compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: audioTrack,
                at: .zero
            )

            let parameters = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
            // Track 0 is usually ScreenCaptureKit system audio, track 1 is microphone.
            // Keep system audio full and put the mic slightly under it for a usable preview mix.
            parameters.setVolume(index == 0 ? 1.0 : 0.85, at: .zero)
            audioParameters.append(parameters)
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioParameters

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecorderError.saveFailed("混音导出器初始化失败")
        }

        exporter.audioMix = audioMix
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: outputURL, as: .mp4)
    }

    private func commitTemporaryRecording(from temporaryURL: URL, to finalURL: URL) throws -> URL {
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        return finalURL
    }

    private func recordingsFolderURL() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let folder = movies.appendingPathComponent("FlowRecorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func inProgressFolderURL() -> URL {
        let folder = recordingsFolderURL().appendingPathComponent(".in-progress", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func reset() {
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        microphoneInput = nil
        startTime = nil
        finalOutputURL = nil
        temporaryOutputURL = nil
        expectedAudioTrackCount = 0
        videoSampleCount = 0
        audioSampleCount = 0
        microphoneSampleCount = 0
        firstVideoFrameContinuation = nil
        isFinishing = false
    }

    private func resetAfterStop() {
        queue.sync {
            self.reset()
        }
    }

    private func cancelWriterIfNeeded(_ writer: AVAssetWriter) {
        queue.sync {
            if writer.status == .unknown || writer.status == .writing {
                writer.cancelWriting()
            }
        }
    }

    private func quarantineBrokenFile(_ url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let folder = recordingsFolderURL().appendingPathComponent("损坏录屏", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let targetName = url.lastPathComponent.replacingOccurrences(of: ".recording", with: "")
        let target = folder.appendingPathComponent(targetName)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }

    private func saveFailureText(from error: Error) -> String {
        if let recorderError = error as? RecorderError {
            switch recorderError {
            case .saveFailed(let message):
                return message
            default:
                return recorderError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func failureMessage(_ message: String, moved: URL?) -> String {
        if let moved {
            return "\(message)。未完成文件已移到：\(moved.path)"
        }
        return message
    }

    private func appendRecorderNote(_ message: String) {
        let file = recordingsFolderURL().appendingPathComponent("status.txt")
        let text = "[\(Date())] 调试：\(message)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
