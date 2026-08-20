import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class IslandStore: ObservableObject {
    static let shared = IslandStore()

    private static let clipboardTextCharacterLimit = 20_000
    private static let clipboardTextByteLimit = 256 * 1_024
    private static let clipboardImageByteLimit = 24 * 1_024 * 1_024
    private static let clipboardImagePixelLimit = 32_000_000
    private static let clipboardImageStorageLimit = 512 * 1_024 * 1_024

    @Published var selectedTab: IslandTab = .screenshots
    @Published var isExpanded = false
    @Published var screenshots: [ScreenshotItem]
    @Published var clipboardItems: [ClipboardItem]
    @Published var documents: [DocumentItem]
    @Published var credentials: [CredentialItem]
    @Published var recordings: [RecordingItem]
    @Published var folders: [IslandFolder]
    @Published var islandPosition: IslandPosition
    @Published var islandHorizontalAnchor: Double?
    @Published var clipboardMonitoringEnabled: Bool
    @Published var lastError: String?
    @Published var copiedItemID: UUID?
    @Published var copiedScreenshotID: UUID?
    @Published var isCapturing = false
    @Published private(set) var isScreenshotDragActive = false
    @Published private(set) var isSelectingScreenshotArea = false
    @Published var preferredExpandedHeight: CGFloat = 330
    @Published var customExpandedWidth: CGFloat?
    @Published var customExpandedHeight: CGFloat?
    @Published private(set) var expandedCanvasSize = CGSize(width: 760, height: 360)
    @Published var islandConfigurationMode: IslandConfigurationMode = .none
    @Published var layoutModes: [String: IslandLayoutMode]
    @Published var isRecording = false
    @Published var isRecordingPaused = false
    @Published var recordingElapsed: TimeInterval = 0
    @Published var recordingLevel: Double = 0
    @Published var systemVoiceMemoState: SystemVoiceMemoSyncState = .idle
    @Published var voiceMemosLibraryAccess: VoiceMemosLibraryAccessState = .checking
    @Published private(set) var screenCaptureAccess: ScreenCaptureAccessState = .permissionRequired
    @Published private(set) var hasVoiceMemosAutomationPermission = false
    @Published private(set) var voiceMemosFullDiskSettingsOpened = false
    @Published private(set) var voiceMemosAccessibilitySettingsOpened = false
    @Published var activePlaybackID: UUID?
    @Published var transcriptionStates: [UUID: RecordingTranscriptionState] = [:]

    let directories: AppDirectories

    private let repository: StateRepository
    private var clipboardTimer: Timer?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var collapseTask: Task<Void, Never>?
    private var screenshotDragTask: Task<Void, Never>?
    private var isPointerInside = false
    private var interactionDepth = 0
    private var collapseAllowedAfter = Date.distantPast
    private var audioPlayer: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var voiceMemosRefreshTimer: Timer?
    private var privacyPermissionPollingTask: Task<Void, Never>?
    private var playbackResetTask: Task<Void, Never>?
    private var transcriptionProcesses: [UUID: Process] = [:]
    private var transcriptionPreparationTasks: [UUID: Task<Void, Never>] = [:]
    private var isRefreshingVoiceMemos = false
    private var captureAfterPermissionGrant = false
    private var captureSelectionAfterPermissionGrant = false
    private var startRecordingAfterPermissionGrant = false
    private let voiceMemosLibrary = VoiceMemosLibrary()
    private let systemVoiceMemosBridge = SystemVoiceMemosBridge()

    private init() {
        let resolvedDirectories: AppDirectories
        do {
            resolvedDirectories = try AppDirectories.resolve()
        } catch {
            fatalError("Не удалось создать хранилище приложения: \(error.localizedDescription)")
        }
        directories = resolvedDirectories
        repository = StateRepository(directories: resolvedDirectories)

        let migration = Self.migrateLegacyFolders(repository.load())
        let state = migration.state
        screenshots = state.screenshots
        clipboardItems = state.clipboardItems
        documents = state.documents
        credentials = state.credentials
        recordings = state.recordings ?? []
        folders = state.folders
        islandPosition = state.islandPosition
        islandHorizontalAnchor = state.islandHorizontalAnchor
        clipboardMonitoringEnabled = true
        customExpandedWidth = state.customExpandedWidth.map { CGFloat($0) }
        customExpandedHeight = state.customExpandedHeight.map { CGFloat($0) }
        layoutModes = state.layoutModes ?? [:]
        screenCaptureAccess = ScreenshotService.hasScreenCapturePermission ? .granted : .permissionRequired
        hasVoiceMemosAutomationPermission = systemVoiceMemosBridge.hasAccessibilityPermission

#if DEBUG
        if let previewTabName = ProcessInfo.processInfo.environment["CONVENIENCE_ISLAND_PREVIEW_TAB"],
           let previewTab = IslandTab(rawValue: previewTabName) {
            selectedTab = previewTab
        }
#endif

        if migration.didMigrate {
            try? repository.save(state)
        }

        DispatchQueue.main.async { [weak self] in
            self?.startClipboardMonitor()
            self?.startVoiceMemosLibraryMonitor()
        }

        systemVoiceMemosBridge.onStoppedExternally = { [weak self] in
            guard let self, self.isRecording else { return }
            self.finishNativeRecordingSession()
        }
        systemVoiceMemosBridge.onPauseChangedExternally = { [weak self] paused in
            guard let self, self.isRecording, self.isRecordingPaused != paused else { return }
            self.isRecordingPaused = paused
        }
    }

    deinit {
        clipboardTimer?.invalidate()
        screenshotDragTask?.cancel()
        recordingTimer?.invalidate()
        voiceMemosRefreshTimer?.invalidate()
        privacyPermissionPollingTask?.cancel()
        playbackResetTask?.cancel()
        for task in transcriptionPreparationTasks.values { task.cancel() }
    }

    var collapsedItemCount: Int {
        switch selectedTab {
        case .screenshots: screenshots.count
        case .clipboard: clipboardItems.count
        case .documents: documents.count
        case .credentials: credentials.count
        case .recordings: recordings.count
        }
    }

    var isResizeModeEnabled: Bool { islandConfigurationMode == .resize }
    var isRepositionModeEnabled: Bool { islandConfigurationMode == .reposition }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        let shouldFinishResize = !expanded && islandConfigurationMode == .resize
        isExpanded = expanded
        NotificationCenter.default.post(name: .islandExpansionChanged, object: expanded)
        if shouldFinishResize {
            setIslandConfigurationMode(.none)
        }
    }

    func pointerChanged(isInside: Bool) {
        isPointerInside = isInside
        collapseTask?.cancel()
        guard !isRepositionModeEnabled else { return }
        if isInside {
            if !isExpanded {
                // Once hover begins, let the complete opening animation finish even
                // if the pointer immediately leaves the moving window boundary.
                collapseAllowedAfter = Date().addingTimeInterval(0.26)
            }
            setExpanded(true)
        } else if !isResizeModeEnabled {
            scheduleCollapse()
        }
    }

    func beginInteraction() {
        interactionDepth += 1
        collapseTask?.cancel()
        setExpanded(true)
    }

    func endInteraction() {
        interactionDepth = max(0, interactionDepth - 1)
        if !isPointerInside {
            scheduleCollapse()
        }
    }

    func select(_ tab: IslandTab) {
        selectedTab = tab
        setExpanded(true)
    }

    func layoutMode(for tab: IslandTab) -> IslandLayoutMode {
        if let savedMode = layoutModes[tab.rawValue] {
            return savedMode
        }
        return tab == .screenshots ? .list : .grid
    }

    func toggleLayoutMode(for tab: IslandTab) {
        layoutModes[tab.rawValue] = layoutMode(for: tab).toggled
        persist()
    }

    func setPreferredExpandedHeight(_ height: CGFloat) {
        guard abs(preferredExpandedHeight - height) > 1 else { return }
        preferredExpandedHeight = height
        NotificationCenter.default.post(name: .islandPreferredSizeChanged, object: height)
    }

    func setExpandedCanvasSize(_ size: CGSize) {
        guard abs(expandedCanvasSize.width - size.width) > 0.5
                || abs(expandedCanvasSize.height - size.height) > 0.5 else { return }
        expandedCanvasSize = size
    }

    func setPosition(_ position: IslandPosition) {
        islandPosition = position
        islandHorizontalAnchor = nil
        persist()
        NotificationCenter.default.post(name: .islandPositionChanged, object: position)
    }

    func setHorizontalAnchor(_ anchor: Double) {
        let clamped = min(max(anchor, 0), 1)
        islandHorizontalAnchor = clamped
        if abs(clamped - 0.5) < 0.001 {
            islandPosition = .center
        } else {
            islandPosition = clamped < 0.5 ? .left : .right
        }
        persist()
        NotificationCenter.default.post(name: .islandPositionChanged, object: clamped)
    }

    func snapWindowAfterDrag() {
        NotificationCenter.default.post(name: .islandRequestSnap, object: nil)
    }

    func toggleResizeMode() {
        collapseTask?.cancel()
        switch islandConfigurationMode {
        case .none:
            setIslandConfigurationMode(.resize)
            setExpanded(true)
        case .resize:
            setIslandConfigurationMode(.reposition)
            setExpanded(false)
        case .reposition:
            finishIslandConfiguration()
        }
    }

    func finishIslandConfiguration() {
        guard islandConfigurationMode != .none else { return }
        setIslandConfigurationMode(.none)
        if !isPointerInside, isExpanded {
            scheduleCollapse()
        }
    }

    private func setIslandConfigurationMode(_ mode: IslandConfigurationMode) {
        guard islandConfigurationMode != mode else { return }
        islandConfigurationMode = mode
        NotificationCenter.default.post(name: .islandConfigurationModeChanged, object: mode)
    }

    func setCustomExpandedSize(_ size: CGSize) {
        customExpandedWidth = size.width
        customExpandedHeight = size.height
        persist()
    }

    func resetCustomExpandedSize() {
        customExpandedWidth = nil
        customExpandedHeight = nil
        persist()
        NotificationCenter.default.post(name: .islandCustomSizeChanged, object: nil)
    }

    func beginScreenshotDrag() {
        collapseTask?.cancel()
        if !isScreenshotDragActive {
            isScreenshotDragActive = true
            interactionDepth += 1
        }
        setExpanded(true)

        screenshotDragTask?.cancel()
        screenshotDragTask = Task { [weak self] in
            var observedPressedButton = false

            for iteration in 0..<120 {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }

                let isPressed = CGEventSource.buttonState(
                    .combinedSessionState,
                    button: .left
                )
                observedPressedButton = observedPressedButton || isPressed

                if observedPressedButton, !isPressed {
                    self.endScreenshotDrag()
                    return
                }

                // If AppKit started the provider after mouse-up, do not leave the
                // island pinned forever waiting for a button state we missed.
                if iteration >= 10, !observedPressedButton {
                    self.endScreenshotDrag()
                    return
                }
            }

            self?.endScreenshotDrag()
        }
    }

    func endScreenshotDrag() {
        guard isScreenshotDragActive else { return }
        screenshotDragTask?.cancel()
        screenshotDragTask = nil
        isScreenshotDragActive = false
        interactionDepth = max(0, interactionDepth - 1)

        // SwiftUI may not deliver onHover(false) while a native drag session is
        // active, so trust the real pointer position when the mouse is released.
        isPointerInside = isPointerActuallyInsideIsland
        if !isPointerInside {
            scheduleCollapse()
        }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            guard let self else { return }
            let committedExpansionRemaining = max(0, self.collapseAllowedAfter.timeIntervalSinceNow)
            let delay = max(0.18, committedExpansionRemaining)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if self.isPointerActuallyInsideIsland {
                self.isPointerInside = true
                return
            }
            guard !self.isPointerInside, self.interactionDepth == 0 else { return }
            self.setExpanded(false)
        }
    }

    private var isPointerActuallyInsideIsland: Bool {
        let pointer = NSEvent.mouseLocation
        return NSApp.windows.contains { window in
            window is IslandPanel && window.isVisible && window.frame.contains(pointer)
        }
    }

    // MARK: - Screenshots

    func refreshPrivacyPermissions() {
        let screenCaptureGranted = ScreenshotService.hasScreenCapturePermission
        if screenCaptureGranted {
            screenCaptureAccess = .granted
        } else if screenCaptureAccess == .granted {
            screenCaptureAccess = .permissionRequired
        }

        let automationGranted = systemVoiceMemosBridge.hasAccessibilityPermission
        hasVoiceMemosAutomationPermission = automationGranted
        if automationGranted {
            voiceMemosAccessibilitySettingsOpened = false
            if startRecordingAfterPermissionGrant, !isRecording {
                startRecordingAfterPermissionGrant = false
                startSystemVoiceMemoRecording()
            }
        }

        if screenCaptureGranted, captureSelectionAfterPermissionGrant, !isCapturing {
            captureSelectionAfterPermissionGrant = false
            captureSelectionScreenshot()
        } else if screenCaptureGranted, captureAfterPermissionGrant, !isCapturing {
            captureAfterPermissionGrant = false
            captureScreenshot()
        }
    }

    func requestScreenCapturePermission(forSelection: Bool = false) {
        lastError = nil
        captureAfterPermissionGrant = !forSelection
        captureSelectionAfterPermissionGrant = forSelection

        if ScreenshotService.hasScreenCapturePermission || ScreenshotService.requestScreenCapturePermission() {
            screenCaptureAccess = .granted
            if forSelection {
                captureSelectionAfterPermissionGrant = false
                captureSelectionScreenshot()
            } else {
                captureAfterPermissionGrant = false
                captureScreenshot()
            }
            return
        }

        screenCaptureAccess = .settingsOpened
        ScreenshotService.openScreenCaptureSettings()
        startPrivacyPermissionPolling()
    }

    func relaunchForPermissions() {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            "sleep 0.7; exec /usr/bin/open -n \"$1\"",
            "permission-relaunch",
            Bundle.main.bundleURL.path
        ]

        do {
            try relauncher.run()
            NSApp.terminate(nil)
        } catch {
            lastError = "Не удалось перезапустить островок: \(error.localizedDescription)"
        }
    }

    private func startPrivacyPermissionPolling() {
        privacyPermissionPollingTask?.cancel()
        privacyPermissionPollingTask = Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refreshPrivacyPermissions()
                let waitingForScreenCapture = (self.captureAfterPermissionGrant
                    || self.captureSelectionAfterPermissionGrant)
                    && self.screenCaptureAccess != .granted
                let waitingForVoiceMemos = (self.startRecordingAfterPermissionGrant
                    || self.voiceMemosAccessibilitySettingsOpened)
                    && !self.hasVoiceMemosAutomationPermission
                if !waitingForScreenCapture, !waitingForVoiceMemos {
                    return
                }
            }
        }
    }

    func screenshotURL(for item: ScreenshotItem) -> URL? {
        FileSecurity.safeChildURL(
            fileName: item.fileName,
            in: directories.screenshots,
            allowedExtensions: ["png"]
        )
    }

    func captureScreenshot() {
        guard !isCapturing else { return }
        guard ScreenshotService.hasScreenCapturePermission else {
            requestScreenCapturePermission()
            return
        }
        screenCaptureAccess = .granted
        isCapturing = true
        lastError = nil
        let fileName = "Screenshot-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString.prefix(6)).png"
        let destination = directories.screenshots.appendingPathComponent(fileName)

        Task {
            do {
                if #available(macOS 14.0, *) {
                    try await ScreenshotService.captureMainDisplay(to: destination)
                }
                screenshots.insert(ScreenshotItem(fileName: fileName), at: 0)
                persist()
            } catch {
                if !ScreenshotService.hasScreenCapturePermission {
                    screenCaptureAccess = .permissionRequired
                    lastError = "Разрешите островку делать снимки экрана."
                } else {
                    lastError = error.localizedDescription
                }
            }
            isCapturing = false
        }
    }

    func captureSelectionScreenshot() {
        guard !isCapturing else { return }
        guard ScreenshotService.hasScreenCapturePermission else {
            requestScreenCapturePermission(forSelection: true)
            return
        }
        screenCaptureAccess = .granted
        isCapturing = true
        isSelectingScreenshotArea = true
        lastError = nil
        beginInteraction()

        let fileName = "Selection-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString.prefix(6)).png"
        guard let destination = FileSecurity.safeChildURL(
            fileName: fileName,
            in: directories.screenshots,
            allowedExtensions: ["png"]
        ) else {
            isCapturing = false
            isSelectingScreenshotArea = false
            endInteraction()
            lastError = "Не удалось подготовить безопасный путь для снимка."
            return
        }

        NotificationCenter.default.post(name: .islandCaptureVisibilityChanged, object: true)
        Task {
            do {
                try await Task.sleep(for: .milliseconds(140))
                if try await ScreenshotService.captureSelection(to: destination) {
                    screenshots.insert(ScreenshotItem(fileName: fileName), at: 0)
                    persist()
                } else if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
            } catch {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                lastError = error.localizedDescription
            }

            isCapturing = false
            isSelectingScreenshotArea = false
            collapseAllowedAfter = Date().addingTimeInterval(1.0)
            NotificationCenter.default.post(name: .islandCaptureVisibilityChanged, object: false)
            setExpanded(true)
            endInteraction()
        }
    }

    func deleteScreenshot(_ item: ScreenshotItem) {
        if let url = screenshotURL(for: item),
           FileManager.default.fileExists(atPath: url.path) {
            _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        screenshots.removeAll { $0.id == item.id }
        persist()
    }

    func deleteAllScreenshots() {
        for item in screenshots {
            if let url = screenshotURL(for: item),
               FileManager.default.fileExists(atPath: url.path) {
                _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        screenshots.removeAll()
        persist()
    }

    func copyScreenshot(_ item: ScreenshotItem) {
        guard let url = screenshotURL(for: item),
              let image = NSImage(contentsOf: url),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            lastError = "Не удалось скопировать снимок."
            return
        }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(pngData, forType: .png)
        pasteboardItem.setData(tiffData, forType: .tiff)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([pasteboardItem])
        lastPasteboardChangeCount = pasteboard.changeCount
        copiedScreenshotID = item.id

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if self?.copiedScreenshotID == item.id {
                self?.copiedScreenshotID = nil
            }
        }
    }

    func moveScreenshot(_ itemID: UUID, before targetID: UUID) {
        guard itemID != targetID,
              let sourceIndex = screenshots.firstIndex(where: { $0.id == itemID }),
              let targetIndex = screenshots.firstIndex(where: { $0.id == targetID }) else { return }
        let item = screenshots.remove(at: sourceIndex)
        let adjustedTarget = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        screenshots.insert(item, at: adjustedTarget)
        persist()
    }

    // MARK: - Clipboard

    func copyClipboardItem(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        switch item.resolvedKind {
        case .text, .link:
            pasteboard.clearContents()
            pasteboard.setString(item.text, forType: .string)
        case .image:
            guard let image = clipboardImage(for: item),
                  let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                lastError = "Не удалось скопировать изображение."
                return
            }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(pngData, forType: .png)
            pasteboardItem.setData(tiffData, forType: .tiff)
            pasteboard.clearContents()
            pasteboard.writeObjects([pasteboardItem])
        }
        lastPasteboardChangeCount = pasteboard.changeCount
        copiedItemID = item.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if self?.copiedItemID == item.id {
                self?.copiedItemID = nil
            }
        }
    }

    func updateClipboardItem(_ item: ClipboardItem, text: String) {
        guard let index = clipboardItems.firstIndex(where: { $0.id == item.id }) else { return }
        clipboardItems[index].text = text
        clipboardItems[index].contentKind = ClipboardItem.inferredKind(for: text)
        clipboardItems[index].createdAt = Date()
        persist()
    }

    func toggleClipboardPin(_ item: ClipboardItem) {
        guard let index = clipboardItems.firstIndex(where: { $0.id == item.id }) else { return }
        clipboardItems[index].isPinned.toggle()
        sortClipboardItems()
        persist()
    }

    func deleteClipboardItem(_ item: ClipboardItem) {
        removeClipboardImage(for: item)
        clipboardItems.removeAll { $0.id == item.id }
        persist()
    }

    func deleteAllClipboardItems() {
        clipboardItems.forEach(removeClipboardImage)
        clipboardItems.removeAll()
        copiedItemID = nil
        persist()
    }

    private func startClipboardMonitor() {
        clipboardTimer?.invalidate()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.pollClipboard()
            }
        }
    }

    private func pollClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount

        let typeNames = Set(pasteboard.types?.map(\.rawValue) ?? [])
        let sensitiveTypes = [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "com.agilebits.onepassword"
        ]
        guard typeNames.isDisjoint(with: sensitiveTypes) else { return }

        if let pngData = clipboardPNGData(from: pasteboard) {
            storeClipboardImage(pngData, sourceApplication: NSWorkspace.shared.frontmostApplication?.localizedName)
            return
        }

        if let rawText = pasteboard.data(forType: .string),
           rawText.count > Self.clipboardTextByteLimit {
            return
        }
        guard let text = pasteboard.string(forType: .string) else { return }
        let boundedText = String(text.prefix(Self.clipboardTextCharacterLimit))
        guard !boundedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if let existingIndex = clipboardItems.firstIndex(where: { $0.text == boundedText }) {
            var existing = clipboardItems.remove(at: existingIndex)
            existing.createdAt = Date()
            existing.sourceApplication = NSWorkspace.shared.frontmostApplication?.localizedName
            clipboardItems.insert(existing, at: 0)
        } else {
            clipboardItems.insert(
                ClipboardItem(
                    text: boundedText,
                    sourceApplication: NSWorkspace.shared.frontmostApplication?.localizedName,
                    contentKind: ClipboardItem.inferredKind(for: boundedText)
                ),
                at: 0
            )
            trimClipboardItemsToLimit()
        }
        sortClipboardItems()
        persist()
    }

    func clipboardImageURL(for item: ClipboardItem) -> URL? {
        guard let fileName = item.imageFileName else { return nil }
        let expectedName = "Clipboard-\(item.id.uuidString).png"
        guard fileName == expectedName else { return nil }
        return FileSecurity.safeChildURL(
            fileName: fileName,
            in: directories.clipboardImages,
            allowedExtensions: ["png"],
            mustExist: true
        )
    }

    func clipboardImage(for item: ClipboardItem) -> NSImage? {
        guard let url = clipboardImageURL(for: item) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func clipboardPNGData(from pasteboard: NSPasteboard) -> Data? {
        if let pngData = pasteboard.data(forType: .png),
           ClipboardSecurity.isAllowedImageData(
               pngData,
               byteLimit: Self.clipboardImageByteLimit,
               pixelLimit: Self.clipboardImagePixelLimit
           ) {
            return pngData
        }
        guard let tiffData = pasteboard.data(forType: .tiff),
              ClipboardSecurity.isAllowedImageData(
                  tiffData,
                  byteLimit: Self.clipboardImageByteLimit,
                  pixelLimit: Self.clipboardImagePixelLimit
              ),
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        guard let pngData = bitmap.representation(using: .png, properties: [:]),
              pngData.count <= Self.clipboardImageByteLimit else { return nil }
        return pngData
    }

    private func storeClipboardImage(_ pngData: Data, sourceApplication: String?) {
        let digest = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
        hydrateMissingClipboardDigests()
        if let existingIndex = clipboardItems.firstIndex(where: {
            $0.resolvedKind == .image && $0.imageSHA256 == digest
        }) {
            var existing = clipboardItems.remove(at: existingIndex)
            existing.createdAt = Date()
            existing.sourceApplication = sourceApplication
            clipboardItems.insert(existing, at: 0)
        } else {
            guard makeClipboardImageStorageRoom(for: pngData.count) else {
                lastError = "Буфер изображений достиг безопасного лимита. Удалите несколько закреплённых изображений."
                return
            }
            let id = UUID()
            let fileName = "Clipboard-\(id.uuidString).png"
            guard let url = FileSecurity.safeChildURL(
                fileName: fileName,
                in: directories.clipboardImages,
                allowedExtensions: ["png"]
            ) else { return }
            do {
                try pngData.write(to: url, options: [.atomic])
                clipboardItems.insert(
                    ClipboardItem(
                        id: id,
                        text: "",
                        sourceApplication: sourceApplication,
                        contentKind: .image,
                        imageFileName: fileName,
                        imageSHA256: digest
                    ),
                    at: 0
                )
                trimClipboardItemsToLimit()
            } catch {
                lastError = "Не удалось сохранить изображение из буфера: (error.localizedDescription)"
                return
            }
        }
        sortClipboardItems()
        persist()
    }

    private func trimClipboardItemsToLimit() {
        guard clipboardItems.count > 250 else { return }
        let pinned = clipboardItems.filter(\.isPinned)
        let recent = clipboardItems.filter { !$0.isPinned }.prefix(max(0, 250 - pinned.count))
        let retained = pinned + recent
        let retainedIDs = Set(retained.map(\.id))
        clipboardItems.filter { !retainedIDs.contains($0.id) }.forEach(removeClipboardImage)
        clipboardItems = retained
    }

    private func removeClipboardImage(for item: ClipboardItem) {
        guard let url = clipboardImageURL(for: item) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func hydrateMissingClipboardDigests() {
        var changed = false
        for index in clipboardItems.indices where clipboardItems[index].resolvedKind == .image {
            guard clipboardItems[index].imageSHA256 == nil,
                  let url = clipboardImageURL(for: clipboardItems[index]),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= Self.clipboardImageByteLimit,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            clipboardItems[index].imageSHA256 = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            changed = true
        }
        if changed { persist() }
    }

    private func makeClipboardImageStorageRoom(for additionalBytes: Int) -> Bool {
        var usedBytes = clipboardItems.reduce(0) { partial, item in
            guard let url = clipboardImageURL(for: item),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return partial
            }
            return partial + max(0, size)
        }
        guard usedBytes + additionalBytes > Self.clipboardImageStorageLimit else { return true }

        let candidates = clipboardItems.reversed().filter { !$0.isPinned && $0.resolvedKind == .image }
        for item in candidates {
            guard let url = clipboardImageURL(for: item) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: url)
            clipboardItems.removeAll { $0.id == item.id }
            usedBytes = max(0, usedBytes - size)
            if usedBytes + additionalBytes <= Self.clipboardImageStorageLimit {
                return true
            }
        }
        return usedBytes + additionalBytes <= Self.clipboardImageStorageLimit
    }

    private func sortClipboardItems() {
        clipboardItems.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.createdAt > $1.createdAt
        }
    }

    // MARK: - Documents

    func addDocuments(_ urls: [URL]) {
        var didChange = false
        for url in urls where url.isFileURL {
            guard !documents.contains(where: { $0.pathHint == url.path }) else { continue }
            let accessGranted = url.startAccessingSecurityScopedResource()
            defer {
                if accessGranted { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: [.nameKey, .contentModificationDateKey],
                    relativeTo: nil
                )
                documents.insert(
                    DocumentItem(
                        displayName: url.lastPathComponent,
                        bookmarkBase64: data.base64EncodedString(),
                        pathHint: url.path
                    ),
                    at: 0
                )
                didChange = true
            } catch {
                lastError = "Не удалось закрепить \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if didChange { persist() }
    }

    func resolvedURL(for item: DocumentItem) -> URL? {
        guard let data = Data(base64Encoded: item.bookmarkBase64) else { return nil }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale {
                refreshBookmark(for: item, url: url)
            }
            return url
        } catch {
            return nil
        }
    }

    func openDocument(_ item: DocumentItem) {
        guard let url = resolvedURL(for: item) else {
            lastError = "Файл недоступен: \(item.displayName)"
            return
        }
        setExpanded(false)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(540))
            guard !Task.isCancelled, let self else { return }
            let accessGranted = url.startAccessingSecurityScopedResource()
            let didOpen = NSWorkspace.shared.open(url)
            if accessGranted { url.stopAccessingSecurityScopedResource() }
            if !didOpen {
                self.lastError = "Не удалось открыть: \(item.displayName)"
            }
        }
    }

    func revealDocument(_ item: DocumentItem) {
        guard let url = resolvedURL(for: item) else {
            lastError = "Файл недоступен: \(item.displayName)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func removeDocument(_ item: DocumentItem) {
        documents.removeAll { $0.id == item.id }
        persist()
    }

    private func refreshBookmark(for item: DocumentItem, url: URL) {
        guard let index = documents.firstIndex(where: { $0.id == item.id }),
              let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        documents[index].bookmarkBase64 = data.base64EncodedString()
        documents[index].pathHint = url.path
        persist()
    }

    // MARK: - Credentials

    @discardableResult
    func createCredentialFile(at url: URL) -> CredentialItem? {
        let title = url.deletingPathExtension().lastPathComponent
        let values = CredentialFileValues(title: title, service: "", username: "", password: "")
        guard writeCredentialFile(values, to: url, allowCreation: true) else { return nil }

        guard let bookmark = credentialBookmark(for: url) else {
            lastError = "Не удалось сохранить безопасную ссылку на текстовый файл. Выберите файл ещё раз."
            return nil
        }
        let item = CredentialItem(
            title: title,
            username: "",
            service: "",
            fileBookmarkBase64: bookmark,
            filePathHint: url.path
        )
        credentials.insert(item, at: 0)
        persist()
        return item
    }

    @discardableResult
    func attachCredentialFile(_ item: CredentialItem, to url: URL) -> CredentialItem? {
        let values = credentialValues(for: item)
        guard writeCredentialFile(values, to: url, allowCreation: true),
              let bookmark = credentialBookmark(for: url),
              let index = credentials.firstIndex(where: { $0.id == item.id }) else { return nil }

        credentials[index].fileBookmarkBase64 = bookmark
        credentials[index].filePathHint = url.path
        credentials[index].title = values.title
        credentials[index].service = values.service
        credentials[index].username = values.username
        KeychainService.deletePassword(for: item.id)
        persist()
        return credentials[index]
    }

    func updateCredentialFile(
        _ item: CredentialItem,
        title: String,
        service: String,
        username: String,
        password: String,
        extras: [CredentialExtraField]
    ) {
        guard let url = resolvedCredentialURL(for: item),
              FileManager.default.fileExists(atPath: url.path),
              let index = credentials.firstIndex(where: { $0.id == item.id }) else {
            lastError = "Текстовый файл карточки больше не найден."
            removeMissingCredentialFiles()
            return
        }

        let values = CredentialFileValues(
            title: title,
            service: service,
            username: username,
            password: password,
            extras: extras
        )
        guard writeCredentialFile(values, to: url, allowCreation: false) else { return }
        credentials[index].title = title
        credentials[index].service = service
        credentials[index].username = username
        credentials[index].filePathHint = url.path
        persist()
    }

    func copyCredentialUsername(_ item: CredentialItem) {
        copyString(credentialValues(for: item).username)
    }

    func copyCredentialPassword(_ item: CredentialItem) {
        let password = credentialValues(for: item).password
        guard !password.isEmpty else {
            lastError = "Пароль в текстовом файле не заполнен."
            return
        }
        copySecretString(password)
    }

    func password(for item: CredentialItem) -> String? {
        let password = credentialValues(for: item).password
        return password.isEmpty ? nil : password
    }

    func credentialValues(for item: CredentialItem) -> CredentialFileValues {
        guard let url = resolvedCredentialURL(for: item),
              FileManager.default.fileExists(atPath: url.path) else {
            return CredentialFileValues(
                title: item.title,
                service: item.service,
                username: item.username,
                password: KeychainService.password(for: item.id) ?? ""
            )
        }

        let accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return CredentialFileValues(title: item.title, service: item.service, username: item.username, password: "")
        }
        return parseCredentialFile(text, fallback: item)
    }

    func resolvedCredentialURL(for item: CredentialItem) -> URL? {
        if let encoded = item.fileBookmarkBase64,
           let data = Data(base64Encoded: encoded) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
        }
        return nil
    }

    func openCredentialFile(_ item: CredentialItem) {
        guard let url = resolvedCredentialURL(for: item), FileManager.default.fileExists(atPath: url.path) else {
            lastError = "Текстовый файл карточки не найден."
            removeMissingCredentialFiles()
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealCredentialFile(_ item: CredentialItem) {
        guard let url = resolvedCredentialURL(for: item), FileManager.default.fileExists(atPath: url.path) else {
            lastError = "Текстовый файл карточки не найден."
            removeMissingCredentialFiles()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func removeMissingCredentialFiles() {
        let removedItems = credentials.filter { item in
            guard item.fileBookmarkBase64 != nil,
                  let url = resolvedCredentialURL(for: item) else { return false }
            return !FileManager.default.fileExists(atPath: url.path)
        }
        guard !removedItems.isEmpty else { return }
        let removedIDs = Set(removedItems.map(\.id))
        removedItems.forEach { KeychainService.deletePassword(for: $0.id) }
        credentials.removeAll { removedIDs.contains($0.id) }
        persist()
    }

    private func credentialBookmark(for url: URL) -> String? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.nameKey, .contentModificationDateKey],
            relativeTo: nil
        ).base64EncodedString()
    }

    private func writeCredentialFile(
        _ values: CredentialFileValues,
        to url: URL,
        allowCreation: Bool
    ) -> Bool {
        if !allowCreation && !FileManager.default.fileExists(atPath: url.path) {
            lastError = "Текстовый файл карточки больше не найден."
            return false
        }
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }
        do {
            try credentialFileText(values).write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            lastError = "Не удалось записать текстовый файл: \(error.localizedDescription)"
            return false
        }
    }

    private func credentialFileText(_ values: CredentialFileValues) -> String {
        func oneLine(_ value: String) -> String {
            value.replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }

        let additions: String
        if values.extras.isEmpty {
            additions = ""
        } else {
            let rows = values.extras.map { field in
                let label = oneLine(field.label)
                    .replacingOccurrences(of: "»", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let visibleLabel = label.isEmpty ? field.kind.title : label
                let valueRow = "\(field.kind.title) «\(visibleLabel)»: \(oneLine(field.value))"
                switch field.kind {
                case .website:
                    return "\(valueRow)\nПароль сайта «\(visibleLabel)»: \(oneLine(field.password))"
                case .messenger:
                    return "\(valueRow)\nПароль мессенджера «\(visibleLabel)»: \(oneLine(field.password))"
                case .secret, .custom:
                    return valueRow
                }
            }
            additions = """

            ДОПОЛНЕНИЯ
            --------------------------------
            \(rows.joined(separator: "\n"))
            """
        }

        return """
        ДАННЫЕ ДЛЯ ВХОДА
        ================================

        Название: \(oneLine(values.title))
        Сайт: \(oneLine(values.service))
        Email / логин: \(oneLine(values.username))
        Пароль: \(oneLine(values.password))
        \(additions)

        ================================
        Обновлено приложением «Островок удобства»
        """
    }

    private func parseCredentialFile(_ text: String, fallback item: CredentialItem) -> CredentialFileValues {
        var values = CredentialFileValues(title: item.title, service: item.service, username: item.username, password: "")
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("Название: ") {
                values.title = String(line.dropFirst("Название: ".count))
            } else if line.hasPrefix("Сайт: ") {
                values.service = String(line.dropFirst("Сайт: ".count))
            } else if line.hasPrefix("Email / логин: ") {
                values.username = String(line.dropFirst("Email / логин: ".count))
            } else if line.hasPrefix("Пароль: ") {
                values.password = String(line.dropFirst("Пароль: ".count))
            } else if let extra = parseCredentialExtra(line) {
                values.extras.append(extra)
            } else if let extraPassword = parseCredentialExtraPassword(line),
                      let index = values.extras.lastIndex(where: {
                          $0.kind == extraPassword.kind && $0.label == extraPassword.label
                      }) {
                values.extras[index].password = extraPassword.password
            }
        }
        return values
    }

    private func parseCredentialExtra(_ line: String) -> CredentialExtraField? {
        let supportedKinds: [CredentialExtraKind] = [.website, .messenger, .secret, .custom]
        for kind in supportedKinds {
            let prefix = "\(kind.title) «"
            guard line.hasPrefix(prefix) else { continue }
            let labelStart = line.index(line.startIndex, offsetBy: prefix.count)
            guard let separator = line.range(of: "»: ", range: labelStart..<line.endIndex) else { continue }
            let label = String(line[labelStart..<separator.lowerBound])
            let value = String(line[separator.upperBound...])
            return CredentialExtraField(kind: kind, label: label, value: value)
        }
        return nil
    }

    private func parseCredentialExtraPassword(
        _ line: String
    ) -> (kind: CredentialExtraKind, label: String, password: String)? {
        let supportedPrefixes: [(String, CredentialExtraKind)] = [
            ("Пароль сайта «", .website),
            ("Пароль мессенджера «", .messenger)
        ]
        for (prefix, kind) in supportedPrefixes {
            guard line.hasPrefix(prefix) else { continue }
            let labelStart = line.index(line.startIndex, offsetBy: prefix.count)
            guard let separator = line.range(of: "»: ", range: labelStart..<line.endIndex) else { continue }
            return (
                kind,
                String(line[labelStart..<separator.lowerBound]),
                String(line[separator.upperBound...])
            )
        }
        return nil
    }

    private func copyString(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
    }

    private func copySecretString(_ value: String) {
        lastPasteboardChangeCount = ClipboardSecurity.writeSecret(value, to: .general)
    }

    // MARK: - Recordings

    func recordingURL(for item: RecordingItem) -> URL? {
        if item.isAppleVoiceMemo {
            guard let externalPath = item.externalPath else { return nil }
            return VoiceMemosLibrary.authorizedRecordingURL(for: externalPath)
        }
        return FileSecurity.safeChildURL(
            fileName: item.fileName,
            in: directories.recordings,
            allowedExtensions: VoiceMemosLibrary.supportedExtensions
        )
    }

    func transcriptionState(for item: RecordingItem) -> RecordingTranscriptionState {
        if let state = transcriptionStates[item.id] { return state }
        guard item.transcriptBaseName != nil else { return .idle }
        guard let url = transcriptURL(for: item, extension: "txt") else { return .idle }
        return FileManager.default.fileExists(atPath: url.path)
            ? .ready
            : .idle
    }

    func toggleRecording() {
        if isRecording {
            openSystemVoiceMemos()
        } else {
            startSystemVoiceMemoRecording()
        }
    }

    func startSystemVoiceMemoRecording() {
        guard !isRecording else { return }
        guard systemVoiceMemosBridge.hasAccessibilityPermission else {
            systemVoiceMemoState = .permissionRequired
            startRecordingAfterPermissionGrant = true
            requestSystemVoiceMemosPermission()
            return
        }
        hasVoiceMemosAutomationPermission = true
        stopPlayback()
        systemVoiceMemoState = .starting
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.systemVoiceMemosBridge.startVisible()
                self.isRecording = true
                self.isRecordingPaused = false
                self.recordingElapsed = 0
                self.recordingLevel = 0.42
                self.systemVoiceMemoState = .recording
                self.startNativeRecordingClock()
            } catch SystemVoiceMemosBridge.BridgeError.accessibilityPermissionRequired {
                self.systemVoiceMemoState = .permissionRequired
                self.startRecordingAfterPermissionGrant = true
                self.requestSystemVoiceMemosPermission()
            } catch {
                self.systemVoiceMemoState = .failed(error.localizedDescription)
                self.lastError = "Не удалось начать запись в Apple «Диктофоне»: \(error.localizedDescription)"
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        systemVoiceMemosBridge.stop()
        finishNativeRecordingSession()
    }

    private func finishNativeRecordingSession() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        isRecordingPaused = false
        recordingElapsed = 0
        recordingLevel = 0
        systemVoiceMemoState = .idle
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled else { return }
            self?.refreshSystemVoiceMemos()
        }
    }

    private func startNativeRecordingClock() {
        recordingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRecording else { return }
                if !self.isRecordingPaused {
                    self.recordingElapsed += 0.25
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    func toggleRecordingPause() {
        guard isRecording else { return }
        let paused = !isRecordingPaused
        if systemVoiceMemosBridge.setPaused(paused) {
            isRecordingPaused = paused
        } else {
            lastError = "Не удалось переключить паузу. Используйте кнопку в Apple «Диктофоне»."
            openSystemVoiceMemos()
        }
    }

    func requestSystemVoiceMemosPermission() {
        if systemVoiceMemosBridge.requestAccessibilityPermission() {
            hasVoiceMemosAutomationPermission = true
            voiceMemosAccessibilitySettingsOpened = false
            systemVoiceMemoState = .idle
            if startRecordingAfterPermissionGrant, !isRecording {
                startRecordingAfterPermissionGrant = false
                startSystemVoiceMemoRecording()
            }
        } else {
            hasVoiceMemosAutomationPermission = false
            voiceMemosAccessibilitySettingsOpened = true
            systemVoiceMemoState = .permissionRequired
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.systemVoiceMemosBridge.openAccessibilitySettings()
            }
            startPrivacyPermissionPolling()
        }
    }

    func continueVoiceMemosPermissionSetup() {
        switch voiceMemosLibraryAccess {
        case .checking:
            refreshSystemVoiceMemos()
        case .fullDiskAccessRequired:
            if voiceMemosFullDiskSettingsOpened {
                relaunchForPermissions()
            } else {
                voiceMemosFullDiskSettingsOpened = true
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.openFullDiskAccessSettings()
                }
            }
        case .failed:
            openSystemVoiceMemos()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.refreshSystemVoiceMemos()
            }
        case .granted:
            guard !hasVoiceMemosAutomationPermission else { return }
            requestSystemVoiceMemosPermission()
        }
    }

    private func startVoiceMemosLibraryMonitor() {
        refreshSystemVoiceMemos()
        voiceMemosRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refreshSystemVoiceMemos() }
        }
        RunLoop.main.add(timer, forMode: .common)
        voiceMemosRefreshTimer = timer
    }

    func refreshSystemVoiceMemos() {
        guard !isRefreshingVoiceMemos, !isRecording else { return }
        isRefreshingVoiceMemos = true
        if voiceMemosLibraryAccess != .granted {
            voiceMemosLibraryAccess = .checking
        }
        let library = voiceMemosLibrary
        Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await Task.detached(priority: .utility) {
                    try library.scan()
                }.value
                self.mergeSystemVoiceMemos(entries)
                self.voiceMemosLibraryAccess = .granted
                self.voiceMemosFullDiskSettingsOpened = false
            } catch VoiceMemosLibraryError.fullDiskAccessRequired {
                self.voiceMemosLibraryAccess = .fullDiskAccessRequired
            } catch VoiceMemosLibraryError.libraryUnavailable {
                self.voiceMemosLibraryAccess = .failed("Откройте Apple «Диктофон» один раз, чтобы macOS создала его библиотеку.")
            } catch {
                self.voiceMemosLibraryAccess = .failed(error.localizedDescription)
            }
            self.isRefreshingVoiceMemos = false
        }
    }

    private func mergeSystemVoiceMemos(_ entries: [VoiceMemoLibraryEntry]) {
        let localItems = recordings.filter { !$0.isAppleVoiceMemo }
        let existingByPath = Dictionary(
            recordings.filter(\.isAppleVoiceMemo).compactMap { item in
                item.externalPath.map { ($0, item) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let scannedPaths = Set(entries.map(\.path))
        var syncedItems = entries.map { entry -> RecordingItem in
            if var existing = existingByPath[entry.path] {
                existing.title = entry.title
                existing.fileName = URL(fileURLWithPath: entry.path).lastPathComponent
                existing.createdAt = entry.createdAt
                existing.duration = entry.duration
                existing.source = .appleVoiceMemos
                existing.sourceModificationDate = entry.modificationDate
                return existing
            }
            return RecordingItem(
                title: entry.title,
                fileName: URL(fileURLWithPath: entry.path).lastPathComponent,
                createdAt: entry.createdAt,
                duration: entry.duration,
                source: .appleVoiceMemos,
                externalPath: entry.path,
                sourceModificationDate: entry.modificationDate
            )
        }

        // Сохраняем ранее известную карточку, если файл есть, но «Диктофон» его ещё дописывает.
        syncedItems.append(contentsOf: existingByPath.compactMap { path, item in
            guard !scannedPaths.contains(path),
                  VoiceMemosLibrary.authorizedRecordingURL(for: path) != nil else { return nil }
            return item
        })

        recordings = (localItems + syncedItems).sorted { $0.createdAt > $1.createdAt }
        persist()
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func togglePlayback(_ item: RecordingItem) {
        if activePlaybackID == item.id {
            stopPlayback()
            return
        }
        stopPlayback()
        guard let url = recordingURL(for: item),
              FileManager.default.fileExists(atPath: url.path) else {
            lastError = "Файл записи не найден."
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.play() else {
                lastError = "Не удалось воспроизвести запись."
                return
            }
            audioPlayer = player
            activePlaybackID = item.id
            playbackResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0.1, player.duration)))
                guard !Task.isCancelled else { return }
                self?.stopPlayback()
            }
        } catch {
            lastError = "Не удалось открыть запись: \(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        playbackResetTask?.cancel()
        playbackResetTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        activePlaybackID = nil
    }

    func transcribeRecording(_ item: RecordingItem) {
        guard transcriptionProcesses[item.id] == nil,
              transcriptionPreparationTasks[item.id] == nil else { return }
        guard let audioURL = recordingURL(for: item),
              FileManager.default.fileExists(atPath: audioURL.path) else {
            lastError = "Файл записи не найден."
            return
        }
        let baseName = transcriptBaseName(for: item)
        guard let outputPrefix = FileSecurity.safeChildURL(
            fileName: baseName,
            in: directories.transcripts
        ),
              let logURL = FileSecurity.safeChildURL(
                fileName: baseName + ".log",
                in: directories.transcripts,
                allowedExtensions: ["log"]
              ),
              ["txt", "md", "srt", "json", "log"].allSatisfy({ fileExtension in
                  FileSecurity.safeChildURL(
                      fileName: baseName + "." + fileExtension,
                      in: directories.transcripts,
                      allowedExtensions: [fileExtension]
                  ) != nil
              }) else {
            transcriptionStates[item.id] = .failed("Небезопасный путь транскрибации.")
            return
        }
        transcriptionStates[item.id] = .running
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let preparedAudioURL: URL
                if audioURL.pathExtension.lowercased() == "wav" {
                    preparedAudioURL = audioURL
                } else {
                    guard let wavURL = FileSecurity.safeChildURL(
                        fileName: baseName + "-source.wav",
                        in: self.directories.transcripts,
                        allowedExtensions: ["wav"]
                    ) else {
                        throw NSError(
                            domain: "ConvenienceIsland.Transcription",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Небезопасный путь временного аудиофайла."]
                        )
                    }
                    preparedAudioURL = try await Task.detached(priority: .userInitiated) {
                        try Self.convertToTranscriptionWAV(source: audioURL, destination: wavURL)
                        return wavURL
                    }.value
                }
                try Task.checkCancellation()
                self.transcriptionPreparationTasks[item.id] = nil
                self.launchTranscription(
                    item: item,
                    audioURL: preparedAudioURL,
                    baseName: baseName,
                    outputPrefix: outputPrefix,
                    logURL: logURL
                )
            } catch is CancellationError {
                self.transcriptionPreparationTasks[item.id] = nil
                self.transcriptionStates[item.id] = .idle
            } catch {
                self.transcriptionPreparationTasks[item.id] = nil
                self.transcriptionStates[item.id] = .failed(error.localizedDescription)
                self.lastError = "Не удалось подготовить аудио: \(error.localizedDescription)"
            }
        }
        transcriptionPreparationTasks[item.id] = task
    }

    func transcriptURL(for item: RecordingItem, extension fileExtension: String) -> URL? {
        let allowedExtensions: Set<String> = ["txt", "md", "srt", "json", "log", "wav"]
        guard allowedExtensions.contains(fileExtension.lowercased()) else { return nil }
        return FileSecurity.safeChildURL(
            fileName: transcriptBaseName(for: item) + "." + fileExtension.lowercased(),
            in: directories.transcripts,
            allowedExtensions: [fileExtension.lowercased()]
        )
    }

    func openTranscript(_ item: RecordingItem, extension fileExtension: String = "txt") {
        let preferred = transcriptURL(for: item, extension: fileExtension)
        let fallback = transcriptURL(for: item, extension: "txt")
        let url = preferred.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? fallback
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            lastError = "Документ транскрибации пока не найден."
            return
        }
        openTranscriptInTextEdit(url)
    }

    func copyTranscriptFile(_ item: RecordingItem) {
        guard let url = transcriptURL(for: item, extension: "txt"),
              FileManager.default.fileExists(atPath: url.path) else {
            lastError = "TXT-файл транскрибации пока не найден."
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        lastPasteboardChangeCount = pasteboard.changeCount
    }

    func copyTranscript(_ item: RecordingItem) {
        guard let url = transcriptURL(for: item, extension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            lastError = "Текст транскрибации пока не найден."
            return
        }
        copyString(text)
    }

    private func openTranscriptInTextEdit(_ url: URL) {
        guard let textEditURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.TextEdit"
        ) else {
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: textEditURL,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.lastError = "Не удалось открыть TXT-файл: \(error.localizedDescription)"
            }
        }
    }

    func revealRecording(_ item: RecordingItem) {
        guard let url = recordingURL(for: item),
              FileManager.default.fileExists(atPath: url.path) else {
            lastError = "Оригинал записи больше не найден в Apple «Диктофоне»."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealTranscript(_ item: RecordingItem) {
        let url = transcriptURL(for: item, extension: "md")
        let fallback = transcriptURL(for: item, extension: "txt")
        guard let selectedURL = url.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }) ?? fallback else {
            lastError = "Документ транскрибации пока не найден."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([selectedURL])
    }

    func renameRecording(_ item: RecordingItem, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = recordings.firstIndex(where: { $0.id == item.id }) else { return }
        recordings[index].title = trimmed
        persist()
    }

    func deleteRecording(_ item: RecordingItem) {
        guard !item.isAppleVoiceMemo else {
            lastError = "Чтобы удалить оригинал, откройте Apple «Диктофон». Карточка исчезнет после синхронизации."
            openSystemVoiceMemos()
            return
        }
        if activePlaybackID == item.id { stopPlayback() }
        transcriptionPreparationTasks[item.id]?.cancel()
        transcriptionPreparationTasks[item.id] = nil
        transcriptionProcesses[item.id]?.terminate()
        transcriptionProcesses[item.id] = nil
        if let audioURL = recordingURL(for: item),
           FileManager.default.fileExists(atPath: audioURL.path) {
            _ = try? FileManager.default.trashItem(at: audioURL, resultingItemURL: nil)
        }
        for fileExtension in ["txt", "md", "srt", "json", "log"] {
            if let url = transcriptURL(for: item, extension: fileExtension),
               FileManager.default.fileExists(atPath: url.path) {
                _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        recordings.removeAll { $0.id == item.id }
        transcriptionStates[item.id] = nil
        persist()
    }

    func openSystemVoiceMemos() {
        systemVoiceMemosBridge.showApplication()
    }

    func shutdown() {
        recordingTimer?.invalidate()
        voiceMemosRefreshTimer?.invalidate()
        privacyPermissionPollingTask?.cancel()
        systemVoiceMemosBridge.disconnect()
        stopPlayback()
        for task in transcriptionPreparationTasks.values { task.cancel() }
        transcriptionPreparationTasks.removeAll()
        for process in transcriptionProcesses.values { process.terminate() }
        transcriptionProcesses.removeAll()
    }

    private func transcriptBaseName(for item: RecordingItem) -> String {
        let prefix = item.isAppleVoiceMemo ? "VoiceMemo" : "Recording"
        return "\(prefix)-\(item.id.uuidString)-transcript"
    }

    private func launchTranscription(
        item: RecordingItem,
        audioURL: URL,
        baseName: String,
        outputPrefix: URL,
        logURL: URL
    ) {
        guard let scriptURL = transcriptionScriptURL() else {
            transcriptionStates[item.id] = .failed("В приложении не найден transcribe_mlx.py.")
            return
        }
        guard let pythonURL = transcriptionPythonURL() else {
            transcriptionStates[item.id] = .failed("Не найден встроенный mlx-whisper.")
            return
        }
        guard let modelPath = transcriptionModelPath() else {
            transcriptionStates[item.id] = .failed("Не найдена локальная модель whisper-large-v3-turbo.")
            return
        }

        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        do {
            let logHandle = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = pythonURL
            process.arguments = [
                scriptURL.path,
                audioURL.path,
                "--output-prefix", outputPrefix.path,
                "--model", modelPath,
                "--language", "ru",
                "--chunk-seconds", "600"
            ]
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.terminationHandler = { [weak self] completedProcess in
                try? logHandle.close()
                guard let self else { return }
                Task { @MainActor in
                    self.transcriptionProcesses[item.id] = nil
                    let textURL = outputPrefix.appendingPathExtension("txt")
                    if completedProcess.terminationStatus == 0,
                       FileManager.default.fileExists(atPath: textURL.path),
                       let index = self.recordings.firstIndex(where: { $0.id == item.id }) {
                        self.recordings[index].transcriptBaseName = baseName
                        self.transcriptionStates[item.id] = .ready
                        self.persist()
                    } else {
                        let detail = self.transcriptionLogTail(at: logURL)
                        self.transcriptionStates[item.id] = .failed(detail)
                        self.lastError = "Транскрибация не завершилась. \(detail)"
                    }
                }
            }
            try process.run()
            transcriptionProcesses[item.id] = process
        } catch {
            transcriptionStates[item.id] = .failed(error.localizedDescription)
            lastError = "Не удалось запустить транскрибатор: \(error.localizedDescription)"
        }
    }

    nonisolated private static func convertToTranscriptionWAV(source: URL, destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [source.path, destination.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let detail = String(
            decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(
                domain: "ConvenienceIsland.AudioConversion",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "afconvert не смог преобразовать запись." : detail]
            )
        }
    }

    private func transcriptionScriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "transcribe_mlx", withExtension: "py") {
            return bundled
        }
#if DEBUG
        return executableURLFromEnvironment(named: "CONVENIENCE_ISLAND_TRANSCRIBER_SCRIPT")
#else
        return nil
#endif
    }

    private func transcriptionPythonURL() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources
                .appendingPathComponent("PythonRuntime", isDirectory: true)
                .appendingPathComponent("bin/python3")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
#if DEBUG
        return executableURLFromEnvironment(
            named: "CONVENIENCE_ISLAND_TRANSCRIBER_PYTHON",
            mustBeExecutable: true
        )
#else
        return nil
#endif
    }

    private func transcriptionModelPath() -> String? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent("whisper-large-v3-turbo", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("config.json").path) {
                return bundled.path
            }
        }
#if DEBUG
        let configuredModel = ProcessInfo.processInfo.environment["CONVENIENCE_ISLAND_TRANSCRIBER_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configuredModel,
              !configuredModel.isEmpty else { return nil }
        let url = URL(fileURLWithPath: configuredModel, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path)
            ? url.path
            : nil
#else
        return nil
#endif
    }

    private func executableURLFromEnvironment(named name: String, mustBeExecutable: Bool = false) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (!mustBeExecutable || FileManager.default.isExecutableFile(atPath: url.path)) ? url : nil
    }

    private func transcriptionLogTail(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return "Подробности сохранены в журнале транскрибации."
        }
        let tail = data.suffix(1_800)
        let text = String(decoding: tail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Неизвестная ошибка транскрибатора." : String(text.suffix(600))
    }

    // MARK: - Folders

    func createFolder(name: String, tab: IslandTab, colorName: String = "graphite") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folders.append(IslandFolder(name: trimmed, colorName: colorName, tab: tab))
        persist()
    }

    func renameFolder(_ folder: IslandFolder, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].name = trimmed
        persist()
    }

    func deleteFolder(_ folder: IslandFolder) {
        for index in screenshots.indices where screenshots[index].folderID == folder.id {
            screenshots[index].folderID = nil
        }
        for index in clipboardItems.indices where clipboardItems[index].folderID == folder.id {
            clipboardItems[index].folderID = nil
        }
        for index in documents.indices where documents[index].folderID == folder.id {
            documents[index].folderID = nil
        }
        for index in credentials.indices where credentials[index].folderID == folder.id {
            credentials[index].folderID = nil
        }
        for index in recordings.indices where recordings[index].folderID == folder.id {
            recordings[index].folderID = nil
        }
        folders.removeAll { $0.id == folder.id }
        persist()
    }

    func moveScreenshot(_ item: ScreenshotItem, to folderID: UUID?) {
        guard let index = screenshots.firstIndex(where: { $0.id == item.id }) else { return }
        screenshots[index].folderID = folderID
        persist()
    }

    func moveClipboardItem(_ item: ClipboardItem, to folderID: UUID?) {
        guard let index = clipboardItems.firstIndex(where: { $0.id == item.id }) else { return }
        clipboardItems[index].folderID = folderID
        persist()
    }

    func moveDocument(_ item: DocumentItem, to folderID: UUID?) {
        guard let index = documents.firstIndex(where: { $0.id == item.id }) else { return }
        documents[index].folderID = folderID
        persist()
    }

    func moveCredential(_ item: CredentialItem, to folderID: UUID?) {
        guard let index = credentials.firstIndex(where: { $0.id == item.id }) else { return }
        credentials[index].folderID = folderID
        persist()
    }

    func moveRecording(_ item: RecordingItem, to folderID: UUID?) {
        guard let index = recordings.firstIndex(where: { $0.id == item.id }) else { return }
        recordings[index].folderID = folderID
        persist()
    }

    private static func migrateLegacyFolders(_ source: PersistedState) -> (state: PersistedState, didMigrate: Bool) {
        var state = source
        var scopedFolders: [IslandFolder] = []
        var didMigrate = false

        for folder in state.folders {
            guard folder.tab == nil else {
                scopedFolders.append(folder)
                continue
            }

            didMigrate = true
            var usedTabs: [IslandTab] = []
            if state.screenshots.contains(where: { $0.folderID == folder.id }) { usedTabs.append(.screenshots) }
            if state.clipboardItems.contains(where: { $0.folderID == folder.id }) { usedTabs.append(.clipboard) }
            if state.documents.contains(where: { $0.folderID == folder.id }) { usedTabs.append(.documents) }
            if state.credentials.contains(where: { $0.folderID == folder.id }) { usedTabs.append(.credentials) }
            if (state.recordings ?? []).contains(where: { $0.folderID == folder.id }) { usedTabs.append(.recordings) }
            if usedTabs.isEmpty { usedTabs = [.screenshots] }

            for (index, tab) in usedTabs.enumerated() {
                var scopedFolder = folder
                scopedFolder.id = index == 0 ? folder.id : UUID()
                scopedFolder.tab = tab
                scopedFolders.append(scopedFolder)
                reassignFolderReferences(
                    in: &state,
                    from: folder.id,
                    to: scopedFolder.id,
                    tab: tab
                )
            }
        }

        state.folders = scopedFolders
        return (state, didMigrate)
    }

    private static func reassignFolderReferences(
        in state: inout PersistedState,
        from oldID: UUID,
        to newID: UUID,
        tab: IslandTab
    ) {
        switch tab {
        case .screenshots:
            for index in state.screenshots.indices where state.screenshots[index].folderID == oldID {
                state.screenshots[index].folderID = newID
            }
        case .clipboard:
            for index in state.clipboardItems.indices where state.clipboardItems[index].folderID == oldID {
                state.clipboardItems[index].folderID = newID
            }
        case .documents:
            for index in state.documents.indices where state.documents[index].folderID == oldID {
                state.documents[index].folderID = newID
            }
        case .credentials:
            for index in state.credentials.indices where state.credentials[index].folderID == oldID {
                state.credentials[index].folderID = newID
            }
        case .recordings:
            guard var recordings = state.recordings else { return }
            for index in recordings.indices where recordings[index].folderID == oldID {
                recordings[index].folderID = newID
            }
            state.recordings = recordings
        }
    }

    func persist() {
        let state = PersistedState(
            screenshots: screenshots,
            clipboardItems: clipboardItems,
            documents: documents,
            credentials: credentials,
            recordings: recordings,
            folders: folders,
            islandPosition: islandPosition,
            islandHorizontalAnchor: islandHorizontalAnchor,
            clipboardMonitoringEnabled: clipboardMonitoringEnabled,
            customExpandedWidth: customExpandedWidth.map { Double($0) },
            customExpandedHeight: customExpandedHeight.map { Double($0) },
            layoutModes: layoutModes
        )
        do {
            try repository.save(state)
        } catch {
            lastError = "Не удалось сохранить данные: \(error.localizedDescription)"
        }
    }
}
