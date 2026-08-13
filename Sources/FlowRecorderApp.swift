import AppKit
import AVFoundation
import CoreImage
@preconcurrency import ScreenCaptureKit
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
        if model.isCountingDown {
            model.cancelCountdown()
            return .terminateNow
        }

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
    @Published private(set) var countdownSeconds: Int?
    @Published private(set) var recordingElapsed = 0
    @Published var status = "准备就绪" {
        didSet { writeStatus(status) }
    }
    @Published var outputURL: URL?
    @Published var recentRecordings: [RecordingItem] = []
    @Published private(set) var recoveredInterruptedRecordingURLs: [URL] = []
    @Published private(set) var recordingHealthItems = RecordingHealthItem.initialItems
    @Published private(set) var isCheckingRecordingHealth = false
    @Published var includeSystemAudio = true {
        didSet { persist(includeSystemAudio, forKey: DefaultsKey.includeSystemAudio) }
    }
    @Published var includeMicrophone = false {
        didSet { persist(includeMicrophone, forKey: DefaultsKey.includeMicrophone) }
    }
    @Published var highlightMouseClicks = true {
        didSet { persist(highlightMouseClicks, forKey: DefaultsKey.highlightMouseClicks) }
    }
    @Published var outputResolution = OutputResolutionPreset.native {
        didSet { persist(outputResolution.rawValue, forKey: DefaultsKey.outputResolution) }
    }
    @Published var microphoneDevices: [MicrophoneDevice] = []
    @Published var selectedMicrophoneDeviceID = MicrophoneDevice.systemDefaultID {
        didSet { persist(selectedMicrophoneDeviceID, forKey: DefaultsKey.selectedMicrophoneDeviceID) }
    }
    @Published var selectedCaptureRect: CGRect?
    @Published var selectedWindowID: CGWindowID?
    @Published var selectedWindowFrame: CGRect?
    @Published var windowOptions: [WindowCaptureOption] = []
    @Published var isRefreshingWindows = false
    @Published var teleprompterFontSize = 28.0 {
        didSet { persist(teleprompterFontSize, forKey: DefaultsKey.teleprompterFontSize) }
    }
    @Published var teleprompterScrollSpeed = 0.0 {
        didSet { persist(teleprompterScrollSpeed, forKey: DefaultsKey.teleprompterScrollSpeed) }
    }
    @Published var teleprompterText = AppModel.defaultTeleprompterText {
        didSet { persist(teleprompterText, forKey: DefaultsKey.teleprompterText) }
    }

    private let recorder = ScreenRecorder()
    private var countdownTask: Task<Void, Never>?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private var isLoadingPersistentSettings = false

    private enum DefaultsKey {
        static let includeSystemAudio = "FlowRecorder.includeSystemAudio"
        static let includeMicrophone = "FlowRecorder.includeMicrophone"
        static let highlightMouseClicks = "FlowRecorder.highlightMouseClicks"
        static let outputResolution = "FlowRecorder.outputResolution"
        static let selectedMicrophoneDeviceID = "FlowRecorder.selectedMicrophoneDeviceID"
        static let teleprompterFontSize = "FlowRecorder.teleprompterFontSize"
        static let teleprompterScrollSpeed = "FlowRecorder.teleprompterScrollSpeed"
        static let teleprompterText = "FlowRecorder.teleprompterText"
    }

    private static let defaultTeleprompterText = """
    开场先讲清楚这条视频要解决什么问题。

    录制时可以打开提词器，它会悬浮在屏幕上方便看稿。
    摄像头小窗可以拖到角落，用来做教程、演示、课程、作品讲解。
    """

    private static let minimumFreeDiskSpaceBytes: Int64 = 500 * 1_024 * 1_024

    var isCountingDown: Bool {
        countdownSeconds != nil
    }

    init() {
        loadPersistentSettings()
        recoveredInterruptedRecordingURLs = recorder.recoverInterruptedRecordings()
        refreshMicrophoneDevices()
        refreshRecordings()
        if recoveredInterruptedRecordingURLs.isEmpty {
            writeStatus(status)
        } else {
            status = "已处理上次未完成录屏：\(recoveredInterruptedRecordingURLs.count) 个临时文件已移到隔离目录，不影响新录制。"
        }
    }

    private func persist(_ value: Any, forKey key: String) {
        guard !isLoadingPersistentSettings else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func loadPersistentSettings() {
        isLoadingPersistentSettings = true
        defer { isLoadingPersistentSettings = false }

        let defaults = UserDefaults.standard

        if defaults.object(forKey: DefaultsKey.includeSystemAudio) != nil {
            includeSystemAudio = defaults.bool(forKey: DefaultsKey.includeSystemAudio)
        }
        if defaults.object(forKey: DefaultsKey.includeMicrophone) != nil {
            includeMicrophone = defaults.bool(forKey: DefaultsKey.includeMicrophone)
                && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
        if defaults.object(forKey: DefaultsKey.highlightMouseClicks) != nil {
            highlightMouseClicks = defaults.bool(forKey: DefaultsKey.highlightMouseClicks)
        }
        if let rawValue = defaults.string(forKey: DefaultsKey.outputResolution),
           let preset = OutputResolutionPreset(rawValue: rawValue) {
            outputResolution = preset
        }
        if let deviceID = defaults.string(forKey: DefaultsKey.selectedMicrophoneDeviceID),
           !deviceID.isEmpty {
            selectedMicrophoneDeviceID = deviceID
        }

        let fontSize = defaults.double(forKey: DefaultsKey.teleprompterFontSize)
        if fontSize.isFinite, fontSize > 0 {
            teleprompterFontSize = min(max(fontSize, 18), 52)
        }

        let scrollSpeed = defaults.double(forKey: DefaultsKey.teleprompterScrollSpeed)
        if scrollSpeed.isFinite, scrollSpeed >= 0 {
            teleprompterScrollSpeed = min(max(scrollSpeed, 0), 90)
        }

        if let savedText = defaults.string(forKey: DefaultsKey.teleprompterText),
           !savedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            teleprompterText = savedText
        }
    }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else if isCountingDown {
            cancelCountdown()
        } else {
            guard !isBusy else { return }
            countdownTask = Task { @MainActor [weak self] in
                await self?.startRecording()
            }
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
            status = "正在做录制前检查..."
            let captureTarget = currentCaptureTarget
            try ensureOutputFolderReadyForRecording()
            try ensureEnoughDiskSpaceForRecording()

            status = "正在检查屏幕录制权限和录制范围..."
            try await recorder.preflightCaptureAvailability(target: captureTarget)

            if includeMicrophone {
                status = "正在检查麦克风权限..."
                guard await ensureMicrophonePermissionForRecording() else {
                    isBusy = false
                    return
                }
            }

            try await runCountdown()

            status = "正在准备录制..."
            let microphoneDeviceID = includeMicrophone ? selectedMicrophoneDevice?.uniqueID : nil
            let url = try await recorder.start(
                includeSystemAudio: includeSystemAudio,
                includeMicrophone: includeMicrophone,
                microphoneDeviceID: microphoneDeviceID,
                captureTarget: captureTarget,
                outputResolution: outputResolution,
                highlightMouseClicks: highlightMouseClicks
            )
            outputURL = nil
            isRecording = true
            isBusy = false
            countdownTask = nil
            beginRecordingTimer()
            OverlayManager.shared.showRecordingControls(model: self)
            status = "录制中：\(url.lastPathComponent)"
        } catch {
            isRecording = false
            isBusy = false
            countdownTask = nil
            status = error is CancellationError ? "已取消倒计时。" : "启动失败：\(humanReadable(error))"
            refreshRecordings()
        }
    }

    private var currentCaptureTarget: RecorderCaptureTarget {
        if let selectedWindowID {
            return .window(id: selectedWindowID, fallbackFrame: selectedWindowFrame)
        }
        return .display(rect: selectedCaptureRect)
    }

    private func ensureOutputFolderReadyForRecording() throws {
        let folder = outputFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw RecorderError.saveFailed("输出目录不可写：\(folder.path)")
        }

        let testURL = folder.appendingPathComponent(".flowrecorder-write-test-\(UUID().uuidString).tmp")
        do {
            try Data("write-test".utf8).write(to: testURL, options: .atomic)
            try? FileManager.default.removeItem(at: testURL)
        } catch {
            try? FileManager.default.removeItem(at: testURL)
            throw RecorderError.saveFailed("输出目录写入失败：\(error.localizedDescription)")
        }
    }

    private func ensureEnoughDiskSpaceForRecording() throws {
        guard let freeBytes = freeDiskSpaceBytes() else { return }
        guard freeBytes >= Self.minimumFreeDiskSpaceBytes else {
            let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
            let minimum = ByteCountFormatter.string(fromByteCount: Self.minimumFreeDiskSpaceBytes, countStyle: .file)
            throw RecorderError.saveFailed("磁盘剩余空间不足：当前 \(free)，建议至少保留 \(minimum) 后再录制")
        }
    }

    func refreshRecordingHealth() async {
        guard !isRecording, !isBusy else { return }
        isCheckingRecordingHealth = true
        defer { isCheckingRecordingHealth = false }

        var items = [RecordingHealthItem]()

        do {
            try ensureOutputFolderReadyForRecording()
            items.append(RecordingHealthItem(
                id: "output",
                title: "输出目录",
                detail: "可写入",
                systemImage: "folder.fill",
                tone: .ok,
                action: .openOutputFolder
            ))
        } catch {
            items.append(RecordingHealthItem(
                id: "output",
                title: "输出目录",
                detail: conciseHealthText(humanReadable(error)),
                systemImage: "folder.fill",
                tone: .error,
                action: .openOutputFolder
            ))
        }

        items.append(diskSpaceHealthItem())

        do {
            try await recorder.preflightCaptureAvailability(target: currentCaptureTarget)
            items.append(RecordingHealthItem(
                id: "screen",
                title: "屏幕录制",
                detail: captureAreaDescription,
                systemImage: "display",
                tone: .ok,
                action: .none
            ))
        } catch {
            items.append(RecordingHealthItem(
                id: "screen",
                title: "屏幕录制",
                detail: conciseHealthText(humanReadable(error)),
                systemImage: "display",
                tone: .error,
                action: .openScreenRecordingSettings
            ))
        }

        items.append(microphoneHealthItem())
        recordingHealthItems = items
    }

    private func diskSpaceHealthItem() -> RecordingHealthItem {
        guard let freeBytes = freeDiskSpaceBytes() else {
            return RecordingHealthItem(
                id: "disk",
                title: "磁盘空间",
                detail: "无法读取",
                systemImage: "internaldrive",
                tone: .warning,
                action: .openOutputFolder
            )
        }

        let detail = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return RecordingHealthItem(
            id: "disk",
            title: "磁盘空间",
            detail: detail,
            systemImage: "internaldrive.fill",
            tone: freeBytes >= Self.minimumFreeDiskSpaceBytes ? .ok : .error,
            action: freeBytes >= Self.minimumFreeDiskSpaceBytes ? .none : .openOutputFolder
        )
    }

    private func microphoneHealthItem() -> RecordingHealthItem {
        guard includeMicrophone else {
            return RecordingHealthItem(
                id: "microphone",
                title: "麦克风",
                detail: "关闭",
                systemImage: "mic.slash.fill",
                tone: .neutral,
                action: .none
            )
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return RecordingHealthItem(
                id: "microphone",
                title: "麦克风",
                detail: selectedMicrophoneDevice?.name ?? "可录入",
                systemImage: "mic.fill",
                tone: .ok,
                action: .none
            )
        case .notDetermined:
            return RecordingHealthItem(
                id: "microphone",
                title: "麦克风",
                detail: "开始时请求",
                systemImage: "mic.fill",
                tone: .warning,
                action: .none
            )
        default:
            return RecordingHealthItem(
                id: "microphone",
                title: "麦克风",
                detail: "未授权",
                systemImage: "mic.slash.fill",
                tone: .error,
                action: .openMicrophoneSettings
            )
        }
    }

    private func conciseHealthText(_ text: String) -> String {
        let trimmed = text.replacingOccurrences(of: "视频保存失败：", with: "")
        guard trimmed.count > 20 else { return trimmed }
        return "\(trimmed.prefix(20))..."
    }

    private func runCountdown() async throws {
        isBusy = true
        for seconds in stride(from: 3, through: 1, by: -1) {
            try Task.checkCancellation()
            countdownSeconds = seconds
            status = "\(seconds) 秒后开始录制，点击录制按钮可取消。"
            try await Task.sleep(for: .seconds(1))
        }
        countdownSeconds = nil
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownSeconds = nil
        isBusy = false
        status = "已取消倒计时。"
    }

    func stopRecording() async {
        guard !isBusy, (isRecording || recorder.hasActiveRecording) else { return }
        isBusy = true
        status = "正在保存视频，请不要关闭软件..."
        do {
            let result = try await recorder.stop { [weak self] message in
                guard let self, self.isBusy else { return }
                self.status = message
            }
            outputURL = result.url
            isRecording = false
            isBusy = false
            endRecordingTimer()
            OverlayManager.shared.hideRecordingControls()
            if result.renderedClickCount > 0 {
                status = "已保存：\(result.url.lastPathComponent)（已叠加 \(result.renderedClickCount) 次点击）"
            } else if result.clickOverlayFailed {
                status = "已保存：\(result.url.lastPathComponent)（点击提示未叠加，已保留原始视频）"
            } else {
                status = "已保存：\(result.url.lastPathComponent)"
            }
            refreshRecordings()
        } catch {
            isRecording = false
            isBusy = false
            endRecordingTimer()
            OverlayManager.shared.hideRecordingControls()
            status = "保存失败：\(humanReadable(error))"
            refreshRecordings()
        }
    }

    private func beginRecordingTimer() {
        recordingTimer?.invalidate()
        recordingStartedAt = Date()
        recordingElapsed = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recordingStartedAt = self.recordingStartedAt else { return }
                self.recordingElapsed = max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    private func endRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
        recordingElapsed = 0
    }

    var outputFolderURL: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let folder = movies.appendingPathComponent("FlowRecorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    var diagnosticsLogURL: URL {
        let file = outputFolderURL.appendingPathComponent("status.txt")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        return file
    }

    var recoveryFolderURL: URL {
        let folder = outputFolderURL.appendingPathComponent("损坏录屏", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    var hasRecoveredInterruptedRecordings: Bool {
        !recoveredInterruptedRecordingURLs.isEmpty
    }

    func openOutputFolder() {
        NSWorkspace.shared.open(outputFolderURL)
        refreshRecordings()
    }

    func openRecoveryFolder() {
        NSWorkspace.shared.open(recoveryFolderURL)
    }

    func openDiagnosticsLog() {
        NSWorkspace.shared.open(diagnosticsLogURL)
    }

    func copyDiagnosticsToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(buildDiagnosticsSnapshot(), forType: .string)
        status = "诊断信息已复制到剪贴板。"
    }

    func performRecordingHealthAction(_ action: RecordingHealthAction) {
        switch action {
        case .none:
            return
        case .openOutputFolder:
            openOutputFolder()
        case .openScreenRecordingSettings:
            openPrivacySettings()
        case .openMicrophoneSettings:
            openMicrophoneSettings()
        }
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

    var captureModeHelp: String {
        if selectedWindowID != nil {
            return "按窗口当前位置录制真实画面，页面跳转和视频播放会录进去。"
        }
        if selectedCaptureRect != nil {
            return "只录固定区域，适合短视频画幅或局部演示。"
        }
        return "录制主屏幕全屏，最稳妥。"
    }

    private func buildDiagnosticsSnapshot() -> String {
        let inProgressFolder = outputFolderURL.appendingPathComponent(".in-progress", isDirectory: true)
        let inProgressFiles = ((try? FileManager.default.contentsOfDirectory(
            at: inProgressFolder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).map { diagnosticFileLine($0) }

        var lines = [
            "FlowRecorder Diagnostic",
            "Generated: \(Date())",
            "Status: \(status)",
            "Recording State: isRecording=\(isRecording), isBusy=\(isBusy), isCountingDown=\(isCountingDown)",
            "Sources: systemAudio=\(includeSystemAudio), microphone=\(includeMicrophone), clickHighlights=\(highlightMouseClicks)",
            "Capture: \(captureAreaDescription)",
            "Output Resolution: \(outputResolution.label)",
            "Output URL: \(outputURL?.path ?? "none")",
            "Output Folder: \(outputFolderURL.path)",
            "Recovery Folder: \(recoveryFolderURL.path)",
            "Free Disk Space: \(freeDiskSpaceDescription())",
            "",
            "Recent Recordings:"
        ]

        if recentRecordings.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: recentRecordings.map { "- \(diagnosticFileLine($0.url))" })
        }

        lines.append("")
        lines.append("In-progress Files:")
        lines.append(contentsOf: inProgressFiles.isEmpty ? ["- none"] : inProgressFiles.map { "- \($0)" })
        lines.append("")
        lines.append("Recovered Interrupted Recordings This Launch:")
        if recoveredInterruptedRecordingURLs.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: recoveredInterruptedRecordingURLs.map { "- \(diagnosticFileLine($0))" })
        }
        lines.append("")
        lines.append("Status Log Tail:")
        lines.append(diagnosticsLogTail(maxLines: 80))
        return lines.joined(separator: "\n")
    }

    private func diagnosticFileLine(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        let modified = values?.contentModificationDate.map { "\($0)" } ?? "unknown date"
        return "\(url.lastPathComponent) · \(size) · \(modified)"
    }

    private func freeDiskSpaceDescription() -> String {
        guard let freeBytes = freeDiskSpaceBytes() else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
    }

    private func freeDiskSpaceBytes() -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: outputFolderURL.path),
              let freeSize = attributes[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return freeSize.int64Value
    }

    private func diagnosticsLogTail(maxLines: Int) -> String {
        guard let text = try? String(contentsOf: diagnosticsLogURL, encoding: .utf8) else {
            return "- status.txt unreadable"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines).joined(separator: "\n")
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
        selectedWindowFrame = nil
        selectedCaptureRect = nil
        status = "录制范围已恢复为全屏。"
    }

    func applyCapturePreset(_ preset: CaptureAreaPreset) {
        guard !isRecording, !isBusy else { return }
        selectedWindowID = nil
        selectedWindowFrame = nil

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
                      !WindowCaptureOption.isSystemUtility(appName: app.applicationName),
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
                    frame: window.frame
                )
            }

            var seen = Set<CGWindowID>()
            windowOptions = options.filter { option in
                if seen.contains(option.id) { return false }
                seen.insert(option.id)
                return true
            }
            .sorted { lhs, rhs in
                if lhs.appName != rhs.appName { return lhs.appName.localizedStandardCompare(rhs.appName) == .orderedAscending }
                return lhs.frame.width * lhs.frame.height > rhs.frame.width * rhs.frame.height
            }
            .prefix(24)
            .map { $0 }

            if let selectedWindowID, !windowOptions.contains(where: { $0.id == selectedWindowID }) {
                self.selectedWindowID = nil
                selectedWindowFrame = nil
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
        selectedWindowFrame = option.frame
        selectedCaptureRect = nil
        status = "已选择窗口区域：\(option.displayName)。页面播放会录进去；移动窗口后请重新选择。"
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
            _ = try? handle.seekToEnd()
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

enum OutputResolutionPreset: String, CaseIterable, Identifiable {
    case native
    case p1080
    case p720
    case p540

    var id: String { rawValue }

    var label: String {
        switch self {
        case .native:
            return "原画"
        case .p1080:
            return "最高 1080P"
        case .p720:
            return "最高 720P"
        case .p540:
            return "最高 540P"
        }
    }

    var maximumLongEdge: CGFloat? {
        switch self {
        case .native:
            return nil
        case .p1080:
            return 1_920
        case .p720:
            return 1_280
        case .p540:
            return 960
        }
    }

    var detail: String {
        switch self {
        case .native:
            return "保持录制范围的原始尺寸"
        case .p1080:
            return "最长边不超过 1920，适合课程和演示"
        case .p720:
            return "最长边不超过 1280，文件更小"
        case .p540:
            return "最长边不超过 960，适合快速分享"
        }
    }
}

struct WindowCaptureOption: Identifiable, Hashable {
    let id: CGWindowID
    let appName: String
    let title: String
    let frame: CGRect

    var width: Int { Int(frame.width) }
    var height: Int { Int(frame.height) }

    var shortName: String {
        title == "未命名窗口" ? appName : title
    }

    var displayName: String {
        "\(appName) · \(shortName) · \(width)×\(height)"
    }

    static func isSystemUtility(appName: String) -> Bool {
        let blockedNames: Set<String> = [
            "程序坞",
            "Dock",
            "控制中心",
            "Control Center",
            "通知中心",
            "Notification Center",
            "universalAccessAuthWarn",
            "Window Server",
            "SystemUIServer"
        ]
        return blockedNames.contains(appName)
    }
}

enum RecorderCaptureTarget {
    case display(rect: CGRect?)
    case window(id: CGWindowID, fallbackFrame: CGRect?)
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

enum RecordingHealthTone {
    case ok
    case warning
    case error
    case neutral
}

enum RecordingHealthAction: Equatable {
    case none
    case openOutputFolder
    case openScreenRecordingSettings
    case openMicrophoneSettings
}

struct RecordingHealthItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let tone: RecordingHealthTone
    let action: RecordingHealthAction

    static let initialItems = [
        RecordingHealthItem(
            id: "output",
            title: "输出目录",
            detail: "待检查",
            systemImage: "folder.fill",
            tone: .neutral,
            action: .none
        ),
        RecordingHealthItem(
            id: "disk",
            title: "磁盘空间",
            detail: "待检查",
            systemImage: "internaldrive",
            tone: .neutral,
            action: .none
        ),
        RecordingHealthItem(
            id: "screen",
            title: "屏幕录制",
            detail: "待检查",
            systemImage: "display",
            tone: .neutral,
            action: .none
        ),
        RecordingHealthItem(
            id: "microphone",
            title: "麦克风",
            detail: "待检查",
            systemImage: "mic.fill",
            tone: .neutral,
            action: .none
        )
    ]
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var cameraShown = false
    @State private var teleprompterShown = false
    @State private var windowPickerShown = false
    @State private var windowSearchText = ""

    private let panelRadius: CGFloat = 18
    private let freshBlue = Color(red: 0.08, green: 0.40, blue: 0.76)
    private let freshMint = Color(red: 0.06, green: 0.56, blue: 0.48)
    private let freshIndigo = Color(red: 0.34, green: 0.31, blue: 0.62)
    private let ink = Color(red: 0.10, green: 0.12, blue: 0.16)
    private let canvas = Color(red: 0.94, green: 0.95, blue: 0.96)
    private let surface = Color(red: 0.99, green: 0.99, blue: 0.985)
    private let panelBorder = Color.black.opacity(0.09)
    private let console = Color(red: 0.075, green: 0.085, blue: 0.105)

    var body: some View {
        ZStack {
            canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if model.hasRecoveredInterruptedRecordings {
                        recoveryBanner
                    }
                    HStack(alignment: .top, spacing: 14) {
                        recordingHero.frame(minWidth: 312, maxWidth: 348)
                        VStack(spacing: 14) {
                            quickTools
                            sourcePanel
                        }
                        .frame(maxWidth: .infinity)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        teleprompterPanel.frame(maxWidth: .infinity)
                        recordingsPanel.frame(width: 400)
                    }
                    statusBox
                }
                .padding(24)
            }
        }
        .onAppear {
            Task {
                await model.refreshWindowOptions()
                await model.refreshRecordingHealth()
            }
        }
        .onChange(of: model.includeMicrophone) { _, _ in
            Task { await model.refreshRecordingHealth() }
        }
        .onChange(of: model.selectedMicrophoneDeviceID) { _, _ in
            Task { await model.refreshRecordingHealth() }
        }
        .onChange(of: model.selectedWindowID) { _, _ in
            Task { await model.refreshRecordingHealth() }
        }
        .onChange(of: model.selectedCaptureRect) { _, _ in
            Task { await model.refreshRecordingHealth() }
        }
        .sheet(isPresented: $windowPickerShown) {
            WindowPickerSheet(
                model: model,
                searchText: $windowSearchText,
                isPresented: $windowPickerShown
            )
            .frame(width: 720, height: 560)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(console)
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.30, blue: 0.31))
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 5) {
                Text("录屏大师Jack")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                Text("录制、收声、提词和窗口捕捉。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                copyrightNotice
                    .padding(.top, 3)
            }
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        let text = model.isCountingDown ? "COUNTDOWN" : (model.isBusy ? "SAVING" : (model.isRecording ? "REC" : "READY"))
        let tint = model.isCountingDown ? Color.orange : (model.isBusy ? Color.orange : (model.isRecording ? Color.red : freshMint))
        return HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.74))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.opacity(0.22), lineWidth: 1))
    }

    private var recordingHero: some View {
        VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("录制控制")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                    Text(model.isRecording ? "正在录制" : (model.isCountingDown ? "即将开始" : "准备开始"))
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(model.isRecording ? "录制中请保持窗口状态稳定" : (model.isCountingDown ? "倒计时期间点击按钮即可取消" : "确认来源后，3 秒倒计时开始录制"))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.64))
                }
                Button {
                    model.toggleRecording()
                } label: {
                    ZStack {
                        Circle()
                            .fill(model.isRecording ? Color(red: 1.0, green: 0.29, blue: 0.31) : (model.isCountingDown ? Color.orange : Color.white))
                            .frame(width: 118, height: 118)
                            .overlay(Circle().stroke(.white.opacity(model.isRecording ? 0.30 : 0.0), lineWidth: 8))
                            .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 10)
                        if let seconds = model.countdownSeconds {
                            Text("\(seconds)")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundStyle(model.isCountingDown ? .white : console)
                        } else {
                            Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(model.isRecording ? .white : console)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isBusy && !model.isCountingDown)
                HStack {
                    Label(model.isCountingDown ? "点击取消" : "快捷键 ⌘R", systemImage: model.isCountingDown ? "xmark.circle" : "keyboard")
                    Spacer()
                    Text(model.isCountingDown ? "即将录制" : (model.isBusy ? "正在处理..." : "状态稳定"))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(22)
        .background(console, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private var quickTools: some View {
        HStack(spacing: 10) {
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
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(11)
            .frame(maxWidth: .infinity)
            .background(surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(panelBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var sourcePanel: some View {
        freshPanel {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("录制源", "分清电脑声和人声，方便直接播放和后期处理")
                recordingHealthPanel
                VStack(spacing: 0) {
                    sourceToggleCard(title: "系统声音", subtitle: model.includeSystemAudio ? "电脑内部声音" : "关闭", icon: "speaker.wave.2.fill", tint: freshBlue, isOn: $model.includeSystemAudio)
                        .disabled(model.isRecording || model.isBusy)
                    Divider().opacity(0.42).padding(.leading, 46)
                    sourceToggleCard(title: "麦克风", subtitle: model.includeMicrophone ? "人声讲解" : "关闭", icon: "mic.fill", tint: Color(red: 0.96, green: 0.45, blue: 0.55), isOn: Binding(get: { model.includeMicrophone }, set: { model.setMicrophoneEnabled($0) }))
                        .disabled(model.isRecording || model.isBusy)
                    Divider().opacity(0.42).padding(.leading, 46)
                    sourceToggleCard(title: "鼠标点击", subtitle: model.highlightMouseClicks ? "视频内显示点击光圈" : "关闭", icon: "cursorarrow.rays", tint: freshMint, isOn: $model.highlightMouseClicks)
                        .disabled(model.isRecording || model.isBusy)
                }
                if model.includeMicrophone {
                    microphonePicker
                }
                captureAreaControl
                Text(model.includeMicrophone ? "系统声音和麦克风会一并写入同一个 MP4，适合直接播放和分享。" : "只录系统声时，文件更轻。需要讲解人声时再打开麦克风。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordingHealthPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label("录制前检查", systemImage: "checklist.checked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ink.opacity(0.82))
                Spacer()
                if model.isCheckingRecordingHealth {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.74)
                }
                Button {
                    Task { await model.refreshRecordingHealth() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .disabled(model.isRecording || model.isBusy || model.isCheckingRecordingHealth)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                ForEach(model.recordingHealthItems) { item in
                    recordingHealthChip(item)
                }
            }
        }
        .padding(11)
        .background(canvas.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(panelBorder.opacity(0.72), lineWidth: 1))
    }

    private func recordingHealthChip(_ item: RecordingHealthItem) -> some View {
        let tint = recordingHealthColor(item.tone)
        return HStack(spacing: 8) {
            Image(systemName: item.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ink.opacity(0.76))
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if item.action != .none && item.tone != .ok {
                Button(recordingHealthActionTitle(item.action)) {
                    model.performRecordingHealthAction(item.action)
                }
                .buttonStyle(.borderless)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .disabled(model.isRecording || model.isBusy)
            }
            Image(systemName: recordingHealthStatusSymbol(item.tone))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint.opacity(item.tone == .neutral ? 0.50 : 0.95))
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(tint.opacity(0.14), lineWidth: 1))
    }

    private func recordingHealthColor(_ tone: RecordingHealthTone) -> Color {
        switch tone {
        case .ok:
            return freshMint
        case .warning:
            return .orange
        case .error:
            return .red
        case .neutral:
            return .secondary
        }
    }

    private func recordingHealthStatusSymbol(_ tone: RecordingHealthTone) -> String {
        switch tone {
        case .ok:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.circle.fill"
        case .neutral:
            return "circle"
        }
    }

    private func recordingHealthActionTitle(_ action: RecordingHealthAction) -> String {
        switch action {
        case .none:
            return ""
        case .openOutputFolder:
            return "打开"
        case .openScreenRecordingSettings, .openMicrophoneSettings:
            return "设置"
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
        .background(canvas.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(panelBorder.opacity(0.75), lineWidth: 1))
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
                    Text(model.captureModeHelp)
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.86))
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
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(freshBlue)
                    .frame(width: 30, height: 30)
                    .background(freshBlue.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("导出清晰度")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.outputResolution.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Picker("", selection: $model.outputResolution) {
                    ForEach(OutputResolutionPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .disabled(model.isRecording || model.isBusy)
            }

            HStack(spacing: 10) {
                Text("窗口录制")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button {
                    windowPickerShown = true
                    Task { await model.refreshWindowOptions() }
                } label: {
                    Label(model.selectedWindowDescription, systemImage: "macwindow")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
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
        .background(canvas.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(panelBorder.opacity(0.75), lineWidth: 1))
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

    private var windowPickerTint: Color { freshIndigo }

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
                    .background(canvas.opacity(0.62), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(panelBorder, lineWidth: 1))
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
        .background(canvas.opacity(0.68), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(panelBorder, lineWidth: 1))
    }

    private var recoveryBanner: some View {
        HStack(spacing: 13) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 38, height: 38)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("已处理上次未完成录屏")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ink)
                Text("\(model.recoveredInterruptedRecordingURLs.count) 个临时文件已移到隔离目录；新录制不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Button { model.openRecoveryFolder() } label: { Label("隔离目录", systemImage: "folder.badge.questionmark") }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            Button { model.copyDiagnosticsToClipboard() } label: { Label("复制诊断", systemImage: "doc.on.doc") }
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.22), lineWidth: 1))
    }

    private var statusBox: some View {
        freshPanel {
            let needsAttention = model.status.contains("失败") || model.hasRecoveredInterruptedRecordings
            HStack(spacing: 12) {
                Image(systemName: needsAttention ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(needsAttention ? .orange : freshMint)
                    .font(.system(size: 20, weight: .semibold))
                Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                if let url = model.outputURL {
                    Button { NSWorkspace.shared.open(url.deletingLastPathComponent()) } label: { Label("查看文件", systemImage: "folder") }.buttonStyle(.bordered)
                }
                if model.hasRecoveredInterruptedRecordings {
                    Button { model.openRecoveryFolder() } label: { Label("隔离目录", systemImage: "exclamationmark.triangle") }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
                Button { model.copyDiagnosticsToClipboard() } label: { Label("复制诊断", systemImage: "doc.on.doc") }.buttonStyle(.bordered)
                Button { model.openDiagnosticsLog() } label: { Label("日志", systemImage: "doc.text.magnifyingglass") }.buttonStyle(.bordered)
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
            .padding(16)
            .background(surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(panelBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.045), radius: 6, x: 0, y: 3)
    }

    private func syncTeleprompter() {
        if teleprompterShown {
            OverlayManager.shared.updateTeleprompter(text: model.teleprompterText, fontSize: model.teleprompterFontSize, scrollSpeed: model.teleprompterScrollSpeed)
        }
    }
}

struct WindowPickerSheet: View {
    @ObservedObject var model: AppModel
    @Binding var searchText: String
    @Binding var isPresented: Bool

    private let tint = Color(red: 0.44, green: 0.42, blue: 0.92)
    private let ink = Color(red: 0.13, green: 0.17, blue: 0.23)

    private var filteredOptions: [WindowCaptureOption] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return model.windowOptions }
        return model.windowOptions.filter {
            $0.appName.lowercased().contains(keyword)
            || $0.title.lowercased().contains(keyword)
            || $0.displayName.lowercased().contains(keyword)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("选择要录制的窗口")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink)
                    Text("适合录 PPT、微信、浏览器、Codex。按窗口当前区域录真实画面，播放/跳转能录进去。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refreshWindowOptions() }
                } label: {
                    Label(model.isRefreshingWindows ? "刷新中" : "刷新", systemImage: model.isRefreshingWindows ? "hourglass" : "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.isRefreshingWindows || model.isRecording || model.isBusy)
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.75))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索 App 或窗口标题，比如 PPT、微信、Chrome、Codex", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint.opacity(0.12), lineWidth: 1))

            if filteredOptions.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredOptions) { option in
                            windowOptionRow(option)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider().opacity(0.45)
            HStack(spacing: 10) {
                Label("提示：选窗口后请不要遮挡它；如果移动窗口，录制前重新选择一次。", systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复全屏录制") {
                    model.clearCaptureRegion()
                    isPresented = false
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.99, blue: 1.00),
                    Color(red: 0.97, green: 0.96, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(tint.opacity(0.85))
            Text(searchText.isEmpty ? "暂无可选窗口" : "没有匹配的窗口")
                .font(.headline)
            Text("打开或切到你要录制的 PPT、微信、浏览器、Codex 窗口后，再点刷新。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func windowOptionRow(_ option: WindowCaptureOption) -> some View {
        let isSelected = model.selectedWindowID == option.id
        return Button {
            model.selectWindow(option)
            isPresented = false
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? tint.opacity(0.18) : Color.white.opacity(0.78))
                    Image(systemName: "macwindow")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(option.appName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ink)
                        Text("\(option.width)×\(option.height)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(option.shortName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isSelected {
                    Label("当前", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary.opacity(0.65))
                }
            }
            .padding(12)
            .background(isSelected ? tint.opacity(0.10) : Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(isSelected ? tint.opacity(0.24) : tint.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
struct RecordingControlsView: View {
    @ObservedObject var model: AppModel

    private var elapsedText: String {
        String(format: "%02d:%02d", model.recordingElapsed / 60, model.recordingElapsed % 60)
    }

    private var stateLabel: String {
        model.isBusy ? "SAVING" : "REC"
    }

    private var stateTint: Color {
        model.isBusy ? Color.orange : Color(red: 1.0, green: 0.27, blue: 0.30)
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(stateTint)
                .frame(width: 10, height: 10)
                .shadow(color: stateTint.opacity(0.55), radius: 5)

            Text(stateLabel)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.70))

            Text(model.isBusy ? "封装中" : elapsedText)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 68, alignment: .leading)

            Divider()
                .frame(height: 20)
                .overlay(.white.opacity(0.18))

            Image(systemName: model.includeSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundStyle(model.includeSystemAudio ? Color(red: 0.25, green: 0.72, blue: 1.0) : .white.opacity(0.35))
                .accessibilityLabel(model.includeSystemAudio ? "系统声音开启" : "系统声音关闭")

            Image(systemName: model.includeMicrophone ? "mic.fill" : "mic.slash.fill")
                .foregroundStyle(model.includeMicrophone ? Color(red: 1.0, green: 0.48, blue: 0.59) : .white.opacity(0.35))
                .accessibilityLabel(model.includeMicrophone ? "麦克风开启" : "麦克风关闭")

            Spacer(minLength: 2)

            Button {
                Task { await model.stopRecording() }
            } label: {
                Image(systemName: model.isBusy ? "hourglass" : "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(red: 0.12, green: 0.13, blue: 0.16))
                    .frame(width: 30, height: 30)
                    .background(.white, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || !model.isRecording)
            .help("停止录制")
        }
        .padding(.horizontal, 13)
        .frame(width: 374, height: 52)
        .background(Color(red: 0.07, green: 0.08, blue: 0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
    }
}

final class OverlayManager {
    static let shared = OverlayManager()

    private var cameraWindow: NSWindow?
    private var teleprompterWindow: NSWindow?
    private var teleprompterHost: NSHostingView<TeleprompterOverlayView>?
    private var regionSelectionWindow: NSWindow?
    private var recordingControlsWindow: NSPanel?

    func showRecordingControls(model: AppModel) {
        if let recordingControlsWindow {
            recordingControlsWindow.contentView = NSHostingView(rootView: RecordingControlsView(model: model))
            recordingControlsWindow.orderFrontRegardless()
            return
        }

        let content = NSHostingView(rootView: RecordingControlsView(model: model))
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 200, y: 700, width: 1000, height: 200)
        let panel = NSPanel(
            contentRect: NSRect(x: screenFrame.midX - 180, y: screenFrame.maxY - 74, width: 360, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.sharingType = .none
        panel.orderFrontRegardless()
        recordingControlsWindow = panel
    }

    func hideRecordingControls() {
        recordingControlsWindow?.orderOut(nil)
    }

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

struct RecordingStopResult {
    let url: URL
    let capturedClickCount: Int
    let renderedClickCount: Int
    let clickOverlayFailed: Bool
}

private enum MouseClickButton: Sendable {
    case left
    case right
}

private struct MouseClickMarker: Sendable {
    let timestamp: TimeInterval
    let location: CGPoint
    let button: MouseClickButton
}

private struct RenderedMouseClickMarker: Sendable {
    let timestamp: TimeInterval
    let point: CGPoint
    let button: MouseClickButton
}

final class ScreenRecorder: NSObject, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var finalOutputURL: URL?
    private var temporaryOutputURL: URL?
    private var postCropRect: CGRect?
    private var captureDisplayFrame: CGRect?
    private var outputResolution = OutputResolutionPreset.native
    private var shouldHighlightMouseClicks = false
    private var mouseClickMonitors: [Any] = []
    private var clickMarkers: [MouseClickMarker] = []
    private var recordingStartContinuation: CheckedContinuation<Void, Error>?
    private var recordingFinishContinuation: CheckedContinuation<Void, Error>?
    private var recordingOutputError: Error?
    private var recordingDidStart = false
    private var recordingDidFinish = false
    private let queue = DispatchQueue(label: "com.jackliu.flowrecorder.writer")

    var hasActiveRecording: Bool {
        stream != nil || recordingOutput != nil
    }

    func preflightCaptureAvailability(target: RecorderCaptureTarget) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        _ = try makeCaptureSetup(target: target, content: content)
    }

    func start(
        includeSystemAudio: Bool,
        includeMicrophone: Bool,
        microphoneDeviceID: String?,
        captureTarget: RecorderCaptureTarget,
        outputResolution: OutputResolutionPreset,
        highlightMouseClicks: Bool
    ) async throws -> URL {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let destination = makeOutputDestination()

        let captureSetup = try makeCaptureSetup(
            target: captureTarget,
            content: content
        )
        let width = captureSetup.width
        let height = captureSetup.height
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
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = destination.temporaryURL
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(recordingOutput)

        self.stream = stream
        self.recordingOutput = recordingOutput
        self.finalOutputURL = destination.finalURL
        self.temporaryOutputURL = destination.temporaryURL
        self.postCropRect = captureSetup.postCropRect
        self.captureDisplayFrame = captureSetup.displayFrame
        self.outputResolution = outputResolution
        self.shouldHighlightMouseClicks = highlightMouseClicks
        self.clickMarkers = []
        self.recordingOutputError = nil
        self.recordingDidStart = false
        self.recordingDidFinish = false

        do {
            try await stream.startCapture()
            try await waitForRecordingStart(timeout: 4)
            return destination.finalURL
        } catch {
            await MainActor.run {
                self.stopMouseClickMonitoring()
            }
            try? await stream.stopCapture()
            try? FileManager.default.removeItem(at: destination.temporaryURL)
            resetAfterStop()
            throw error
        }
    }

    func stop(progress: @escaping @MainActor (String) -> Void = { _ in }) async throws -> RecordingStopResult {
        guard let stream, let finalOutputURL, let temporaryOutputURL else {
            throw RecorderError.writerNotReady
        }

        let capturedClickMarkers = await stopMouseClickCaptureAndSnapshot()
        let requiresProcessing = postCropRect != nil || outputResolution.maximumLongEdge != nil
        var renderedClickCount = 0
        var clickOverlayFailed = false
        var filesToQuarantine = [temporaryOutputURL]
        appendRecorderNote(
            "stop begin temp=\(temporaryOutputURL.lastPathComponent) final=\(finalOutputURL.lastPathComponent) crop=\(rectDescription(postCropRect)) resolution=\(outputResolution.label) capturedClicks=\(capturedClickMarkers.count) requiresProcessing=\(requiresProcessing)"
        )
        do {
            await progress("正在结束录制并封装原始 MP4...")
            try await finishNativeRecording(stream)
            await progress("正在验证原始 MP4 是否可播放...")
            try await validatePlayableMovie(at: temporaryOutputURL, expectedAudioTracks: 0)
            appendRecorderNote("native mp4 ready \(fileSummary(temporaryOutputURL))")

            var workingURL = temporaryOutputURL
            if requiresProcessing || !capturedClickMarkers.isEmpty {
                let processedURL = temporaryOutputURL.deletingLastPathComponent()
                    .appendingPathComponent("\(temporaryOutputURL.deletingPathExtension().lastPathComponent)-processed.mp4")
                filesToQuarantine.append(processedURL)
                appendRecorderNote(
                    "postprocess begin output=\(processedURL.lastPathComponent) crop=\(rectDescription(postCropRect)) maxLongEdge=\(outputResolution.maximumLongEdge.map { String(Int($0)) } ?? "native") clicks=\(capturedClickMarkers.count)"
                )
                await progress(processingStatus(requiresProcessing: requiresProcessing, clickCount: capturedClickMarkers.count))
                do {
                    renderedClickCount = try await exportProcessedMovie(
                        from: temporaryOutputURL,
                        to: processedURL,
                        cropRect: postCropRect,
                        maximumLongEdge: outputResolution.maximumLongEdge,
                        clickMarkers: capturedClickMarkers
                    )
                } catch {
                    guard !capturedClickMarkers.isEmpty else { throw error }
                    appendRecorderNote("click overlay failed, preserving playable base path: \(saveFailureText(from: error))")
                    await progress("点击提示处理失败，正在保留可播放视频...")
                    clickOverlayFailed = true
                    try? FileManager.default.removeItem(at: processedURL)
                    if requiresProcessing {
                        await progress("正在保留清晰度/区域处理，不叠加点击提示...")
                        renderedClickCount = try await exportProcessedMovie(
                            from: temporaryOutputURL,
                            to: processedURL,
                            cropRect: postCropRect,
                            maximumLongEdge: outputResolution.maximumLongEdge,
                            clickMarkers: []
                        )
                    } else {
                        renderedClickCount = 0
                        workingURL = temporaryOutputURL
                        try? FileManager.default.removeItem(at: processedURL)
                    }
                }
                if FileManager.default.fileExists(atPath: processedURL.path) {
                    await progress("正在验证处理后 MP4 是否可播放...")
                    try await validatePlayableMovie(at: processedURL, expectedAudioTracks: 0)
                    appendRecorderNote("postprocess ready \(fileSummary(processedURL)) renderedClicks=\(renderedClickCount) overlayFailed=\(clickOverlayFailed)")
                    workingURL = processedURL
                }
            }

            await progress("正在写入最终 MP4 文件...")
            let savedURL = try commitTemporaryRecording(from: workingURL, to: finalOutputURL)
            appendRecorderNote("commit complete \(fileSummary(savedURL))")
            await progress("最终文件已写入，正在清理临时文件...")
            for url in filesToQuarantine where url != savedURL {
                try? FileManager.default.removeItem(at: url)
            }
            resetAfterStop()
            return RecordingStopResult(
                url: savedURL,
                capturedClickCount: capturedClickMarkers.count,
                renderedClickCount: renderedClickCount,
                clickOverlayFailed: clickOverlayFailed
            )
        } catch {
            await MainActor.run {
                self.stopMouseClickMonitoring()
            }
            var moved: URL?
            for url in filesToQuarantine {
                moved = quarantineBrokenFile(url) ?? moved
            }
            appendRecorderNote("stop failed message=\(saveFailureText(from: error)) quarantined=\(moved?.path ?? "none")")
            resetAfterStop()
            throw RecorderError.saveFailed(failureMessage(saveFailureText(from: error), moved: moved))
        }
    }

    private func processingStatus(requiresProcessing: Bool, clickCount: Int) -> String {
        var parts = [String]()
        if requiresProcessing {
            parts.append("清晰度/区域")
        }
        if clickCount > 0 {
            parts.append("点击提示")
        }
        let detail = parts.isEmpty ? "视频" : parts.joined(separator: "、")
        return "正在处理\(detail)，请不要关闭软件..."
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        queue.async {
            self.recordingDidStart = true
            let startedAt = ProcessInfo.processInfo.systemUptime
            if self.shouldHighlightMouseClicks, let displayFrame = self.captureDisplayFrame {
                Task { @MainActor [weak self] in
                    self?.startMouseClickMonitoring(
                        recordingStartTimestamp: startedAt,
                        displayFrame: displayFrame
                    )
                }
            }
            guard let continuation = self.recordingStartContinuation else { return }
            self.recordingStartContinuation = nil
            continuation.resume()
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        queue.async {
            self.recordingDidFinish = true
            guard let continuation = self.recordingFinishContinuation else { return }
            self.recordingFinishContinuation = nil
            continuation.resume()
        }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        queue.async {
            self.recordingOutputError = error
            if let continuation = self.recordingStartContinuation {
                self.recordingStartContinuation = nil
                continuation.resume(throwing: RecorderError.saveFailed(error.localizedDescription))
            }
            if let continuation = self.recordingFinishContinuation {
                self.recordingFinishContinuation = nil
                continuation.resume(throwing: RecorderError.saveFailed(error.localizedDescription))
            }
        }
    }

    func recoverInterruptedRecordings() -> [URL] {
        let tempFolder = inProgressFolderURL()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: tempFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var recoveredURLs = [URL]()
        for url in urls where url.pathExtension.lowercased() == "mp4" {
            if let recoveredURL = quarantineBrokenFile(url) {
                recoveredURLs.append(recoveredURL)
            } else {
                appendRecorderNote("startup recovery failed file=\(url.path)")
            }
        }

        if !recoveredURLs.isEmpty {
            appendRecorderNote("startup recovered interrupted recordings count=\(recoveredURLs.count) files=\(recoveredURLs.map { $0.lastPathComponent }.joined(separator: ","))")
        }
        return recoveredURLs
    }

    @MainActor
    private func startMouseClickMonitoring(recordingStartTimestamp: TimeInterval, displayFrame: CGRect) {
        stopMouseClickMonitoring()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.captureMouseClick(
                eventType: event.type,
                eventTimestamp: event.timestamp,
                screenLocation: NSEvent.mouseLocation,
                recordingStartTimestamp: recordingStartTimestamp,
                displayFrame: displayFrame
            )
        }) {
            mouseClickMonitors.append(globalMonitor)
        }

        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            if event.window?.sharingType != NSWindow.SharingType.none {
                self?.captureMouseClick(
                    eventType: event.type,
                    eventTimestamp: event.timestamp,
                    screenLocation: NSEvent.mouseLocation,
                    recordingStartTimestamp: recordingStartTimestamp,
                    displayFrame: displayFrame
                )
            }
            return event
        }) {
            mouseClickMonitors.append(localMonitor)
        }
    }

    @MainActor
    private func stopMouseClickMonitoring() {
        for monitor in mouseClickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        mouseClickMonitors.removeAll()
    }

    private func stopMouseClickCaptureAndSnapshot() async -> [MouseClickMarker] {
        await MainActor.run {
            self.stopMouseClickMonitoring()
        }
        return queue.sync {
            self.clickMarkers.sorted { $0.timestamp < $1.timestamp }
        }
    }

    private func captureMouseClick(
        eventType: NSEvent.EventType,
        eventTimestamp: TimeInterval,
        screenLocation: CGPoint,
        recordingStartTimestamp: TimeInterval,
        displayFrame: CGRect
    ) {
        guard displayFrame.contains(screenLocation) else { return }
        let elapsed = eventTimestamp - recordingStartTimestamp
        guard elapsed >= 0 else { return }

        let marker = MouseClickMarker(
            timestamp: elapsed,
            location: CGPoint(
                x: screenLocation.x - displayFrame.minX,
                y: screenLocation.y - displayFrame.minY
            ),
            button: eventType == .rightMouseDown ? .right : .left
        )

        queue.async {
            if let last = self.clickMarkers.last,
               marker.timestamp - last.timestamp < 0.03,
               hypot(marker.location.x - last.location.x, marker.location.y - last.location.y) < 3 {
                return
            }
            self.clickMarkers.append(marker)
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

    private func makeCaptureSetup(
        target: RecorderCaptureTarget,
        content: SCShareableContent
    ) throws -> (filter: SCContentFilter, sourceRect: CGRect?, width: Int, height: Int, postCropRect: CGRect?, displayFrame: CGRect) {
        switch target {
        case .display(let captureRect):
            guard let display = displayForCaptureRect(captureRect, displays: content.displays) else {
                throw RecorderError.noDisplay
            }
            let displayFrame = display.frame
            let fullSize = normalizedVideoSize(from: displayFrame.size)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let postCropRect = captureRect.map { normalizedSourceRect($0, displayFrame: displayFrame) }
            return (
                filter: filter,
                sourceRect: nil,
                width: fullSize.width,
                height: fullSize.height,
                postCropRect: postCropRect,
                displayFrame: displayFrame
            )

        case .window(let windowID, let fallbackFrame):
            let liveFrame = content.windows.first(where: { $0.windowID == windowID })?.frame
            guard let windowFrame = liveFrame ?? fallbackFrame else {
                throw RecorderError.windowNotFound
            }

            guard let display = displayForCaptureRect(windowFrame, displays: content.displays) else {
                throw RecorderError.noDisplay
            }
            let displayFrame = display.frame
            let fullSize = normalizedVideoSize(from: displayFrame.size)
            let filter = SCContentFilter(display: display, excludingWindows: [])

            let sourceRect = normalizedSourceRect(windowFrame, displayFrame: displayFrame)
            // Window selection is intentionally implemented as stable full-screen capture
            // followed by a crop. Some apps (notably video/web apps) swap rendering layers
            // after navigation. Keeping the live capture path identical to full-screen
            // recording avoids random writer failures and records the visible screen region.
            return (
                filter: filter,
                sourceRect: nil,
                width: fullSize.width,
                height: fullSize.height,
                postCropRect: sourceRect,
                displayFrame: displayFrame
            )
        }
    }

    private func displayForCaptureRect(_ captureRect: CGRect?, displays: [SCDisplay]) -> SCDisplay? {
        guard !displays.isEmpty else { return nil }
        guard let captureRect else { return displays.first }
        return displays.max { lhs, rhs in
            let lhsIntersection = lhs.frame.intersection(captureRect)
            let rhsIntersection = rhs.frame.intersection(captureRect)
            return lhsIntersection.width * lhsIntersection.height < rhsIntersection.width * rhsIntersection.height
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
        guard let fileSize = values.fileSize, fileSize > 1_024 else {
            throw RecorderError.saveFailed("文件为空或过小，可能没有完整写入")
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

    private func waitForRecordingStart(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if let recordingOutputError = self.recordingOutputError {
                    continuation.resume(throwing: RecorderError.saveFailed(recordingOutputError.localizedDescription))
                    return
                }
                if self.recordingDidStart {
                    continuation.resume()
                    return
                }
                self.recordingStartContinuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard let continuation = self.recordingStartContinuation else { return }
                    self.recordingStartContinuation = nil
                    continuation.resume(throwing: RecorderError.saveFailed("原生录制器没有启动，请重新开始录制"))
                }
            }
        }
    }

    private func finishNativeRecording(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if let recordingOutputError = self.recordingOutputError {
                    continuation.resume(throwing: RecorderError.saveFailed(recordingOutputError.localizedDescription))
                    return
                }
                if self.recordingDidFinish {
                    continuation.resume()
                    return
                }
                self.recordingFinishContinuation = continuation
                Task {
                    do {
                        try await stream.stopCapture()
                    } catch {
                        self.queue.async {
                            guard let continuation = self.recordingFinishContinuation else { return }
                            self.recordingFinishContinuation = nil
                            continuation.resume(throwing: error)
                        }
                    }
                }
                self.queue.asyncAfter(deadline: .now() + 12) {
                    guard let continuation = self.recordingFinishContinuation else { return }
                    self.recordingFinishContinuation = nil
                    continuation.resume(throwing: RecorderError.saveFailed("原生录制器没有完成文件封装"))
                }
            }
        }
    }

    private func exportProcessedMovie(
        from sourceURL: URL,
        to outputURL: URL,
        cropRect: CGRect?,
        maximumLongEdge: CGFloat?,
        clickMarkers: [MouseClickMarker]
    ) async throws -> Int {
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard let videoTrack = videoTracks.first else {
            throw RecorderError.saveFailed("裁剪前没有找到视频轨")
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let fullRect = CGRect(origin: .zero, size: naturalSize)
        var crop = (cropRect ?? fullRect).integral.intersection(fullRect)
        guard crop.width >= 80, crop.height >= 80 else {
            throw RecorderError.saveFailed("裁剪区域无效")
        }

        crop.size.width = CGFloat(max(80, Int(crop.width) - Int(crop.width) % 2))
        crop.size.height = CGFloat(max(80, Int(crop.height) - Int(crop.height) % 2))
        let renderSize = scaledRenderSize(for: crop.size, maximumLongEdge: maximumLongEdge)
        let scale = renderSize.width / crop.width

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecorderError.saveFailed("裁剪视频轨初始化失败")
        }

        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: videoTrack,
            at: .zero
        )

        for audioTrack in audioTracks {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw RecorderError.saveFailed("裁剪音频轨初始化失败")
            }
            try await insertAvailableAudioRange(from: audioTrack, into: compositionAudioTrack, videoDuration: duration)
        }

        let mappedClickMarkers = mappedClickMarkers(
            from: clickMarkers,
            crop: crop,
            scale: scale,
            renderSize: renderSize,
            duration: duration
        )
        let videoComposition: AVMutableVideoComposition
        if mappedClickMarkers.isEmpty {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
            layerInstruction.setTransform(
                CGAffineTransform(
                    a: scale,
                    b: 0,
                    c: 0,
                    d: scale,
                    tx: -crop.minX * scale,
                    ty: -crop.minY * scale
                ),
                at: .zero
            )
            instruction.layerInstructions = [layerInstruction]

            videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = renderSize
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            videoComposition.instructions = [instruction]
        } else {
            videoComposition = makeClickOverlayVideoComposition(
                asset: composition,
                renderSize: renderSize,
                crop: crop,
                scale: scale,
                clickMarkers: mappedClickMarkers
            )
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecorderError.saveFailed("裁剪导出器初始化失败")
        }

        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: outputURL, as: .mp4)
        return mappedClickMarkers.count
    }

    private func mappedClickMarkers(
        from clickMarkers: [MouseClickMarker],
        crop: CGRect,
        scale: CGFloat,
        renderSize: CGSize,
        duration: CMTime
    ) -> [RenderedMouseClickMarker] {
        guard !clickMarkers.isEmpty, duration.seconds.isFinite, duration.seconds > 0 else { return [] }
        let renderRect = CGRect(origin: .zero, size: renderSize)

        return clickMarkers.compactMap { marker in
            guard marker.timestamp <= duration.seconds else { return nil }
            let point = CGPoint(
                x: (marker.location.x - crop.minX) * scale,
                y: (marker.location.y - crop.minY) * scale
            )
            guard renderRect.contains(point) else { return nil }
            return RenderedMouseClickMarker(
                timestamp: max(0, marker.timestamp),
                point: point,
                button: marker.button
            )
        }
    }

    private func makeClickOverlayVideoComposition(
        asset: AVAsset,
        renderSize: CGSize,
        crop: CGRect,
        scale: CGFloat,
        clickMarkers: [RenderedMouseClickMarker]
    ) -> AVMutableVideoComposition {
        let renderRect = CGRect(origin: .zero, size: renderSize)
        let baseRadius = max(18, min(34, max(renderSize.width, renderSize.height) * 0.018))

        let videoComposition = AVMutableVideoComposition(asset: asset) { request in
            let transformedFrame = request.sourceImage
                .cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .cropped(to: renderRect)

            let time = request.compositionTime.seconds
            let image = Self.drawMouseClicks(
                clickMarkers,
                at: time,
                over: transformedFrame,
                renderRect: renderRect,
                baseRadius: baseRadius
            )
            request.finish(with: image.cropped(to: renderRect), context: nil)
        }

        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        return videoComposition
    }

    private static func drawMouseClicks(
        _ markers: [RenderedMouseClickMarker],
        at time: TimeInterval,
        over frame: CIImage,
        renderRect: CGRect,
        baseRadius: CGFloat
    ) -> CIImage {
        var image = frame
        for marker in markers {
            let age = time - marker.timestamp
            guard age >= 0, age <= 0.58 else { continue }
            image = drawMouseClick(
                marker,
                age: age,
                over: image,
                renderRect: renderRect,
                baseRadius: baseRadius
            )
        }
        return image
    }

    private static func drawMouseClick(
        _ marker: RenderedMouseClickMarker,
        age: TimeInterval,
        over frame: CIImage,
        renderRect: CGRect,
        baseRadius: CGFloat
    ) -> CIImage {
        let progress = CGFloat(min(max(age / 0.58, 0), 1))
        let accent: CIColor
        switch marker.button {
        case .left:
            accent = CIColor(red: 0.10, green: 0.54, blue: 1.0, alpha: 1.0)
        case .right:
            accent = CIColor(red: 1.0, green: 0.58, blue: 0.08, alpha: 1.0)
        }

        let pulseRadius = baseRadius * (1.25 + progress * 2.4)
        let pulseAlpha = 0.70 * (1.0 - progress)
        let pulse = radialClickImage(
            center: marker.point,
            radius: pulseRadius,
            innerAlpha: pulseAlpha,
            outerAlpha: 0,
            accent: accent,
            renderRect: renderRect
        )

        var image = pulse.composited(over: frame)
        if progress < 0.42 {
            let coreProgress = progress / 0.42
            let coreRadius = baseRadius * (0.52 + coreProgress * 0.40)
            let coreAlpha = 0.78 * (1.0 - coreProgress)
            let core = radialClickImage(
                center: marker.point,
                radius: coreRadius,
                innerAlpha: coreAlpha,
                outerAlpha: 0,
                accent: accent,
                renderRect: renderRect
            )
            image = core.composited(over: image)
        }
        return image
    }

    private static func radialClickImage(
        center: CGPoint,
        radius: CGFloat,
        innerAlpha: CGFloat,
        outerAlpha: CGFloat,
        accent: CIColor,
        renderRect: CGRect
    ) -> CIImage {
        let filter = CIFilter(
            name: "CIRadialGradient",
            parameters: [
                "inputCenter": CIVector(x: center.x, y: center.y),
                "inputRadius0": max(1, radius * 0.20),
                "inputRadius1": max(2, radius),
                "inputColor0": CIColor(
                    red: accent.red,
                    green: accent.green,
                    blue: accent.blue,
                    alpha: innerAlpha
                ),
                "inputColor1": CIColor(
                    red: accent.red,
                    green: accent.green,
                    blue: accent.blue,
                    alpha: outerAlpha
                )
            ]
        )
        return (filter?.outputImage ?? CIImage.empty()).cropped(to: renderRect)
    }

    private func scaledRenderSize(for sourceSize: CGSize, maximumLongEdge: CGFloat?) -> CGSize {
        guard let maximumLongEdge else { return sourceSize }
        let sourceLongEdge = max(sourceSize.width, sourceSize.height)
        guard sourceLongEdge > maximumLongEdge else { return sourceSize }

        let scale = maximumLongEdge / sourceLongEdge
        let width = max(80, Int((sourceSize.width * scale).rounded(.down)))
        let height = max(80, Int((sourceSize.height * scale).rounded(.down)))
        return CGSize(width: width - width % 2, height: height - height % 2)
    }

    private func insertAvailableAudioRange(
        from sourceTrack: AVAssetTrack,
        into destinationTrack: AVMutableCompositionTrack,
        videoDuration: CMTime
    ) async throws {
        let sourceRange = try await sourceTrack.load(.timeRange)
        let availableDuration = CMTimeMinimum(sourceRange.duration, videoDuration)
        guard availableDuration.isValid, CMTimeCompare(availableDuration, .zero) > 0 else { return }
        try destinationTrack.insertTimeRange(
            CMTimeRange(start: sourceRange.start, duration: availableDuration),
            of: sourceTrack,
            at: sourceRange.start
        )
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
        recordingOutput = nil
        finalOutputURL = nil
        temporaryOutputURL = nil
        postCropRect = nil
        captureDisplayFrame = nil
        outputResolution = .native
        shouldHighlightMouseClicks = false
        clickMarkers = []
        recordingStartContinuation = nil
        recordingFinishContinuation = nil
        recordingOutputError = nil
        recordingDidStart = false
        recordingDidFinish = false
    }

    private func resetAfterStop() {
        queue.sync {
            self.reset()
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

    private func fileSummary(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = Int64(values?.fileSize ?? 0)
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        return "file=\(url.lastPathComponent) size=\(size) path=\(url.path)"
    }

    private func rectDescription(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height))"
    }

    private func appendRecorderNote(_ message: String) {
        let file = recordingsFolderURL().appendingPathComponent("status.txt")
        let text = "[\(Date())] 调试：\(message)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
