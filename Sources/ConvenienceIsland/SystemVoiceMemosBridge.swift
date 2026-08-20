import AppKit
import ApplicationServices
import Foundation

@MainActor
final class SystemVoiceMemosBridge {
    enum BridgeError: LocalizedError {
        case accessibilityPermissionRequired
        case applicationUnavailable
        case commandUnavailable(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .accessibilityPermissionRequired:
                "Нужно разрешение «Универсальный доступ» для связи с Диктофоном Apple."
            case .applicationUnavailable:
                "Не удалось запустить Диктофон Apple."
            case .commandUnavailable(let command):
                "Диктофон Apple не предоставил команду «\(command)»."
            case .commandFailed(let command):
                "Не удалось выполнить команду «\(command)» в Диктофоне Apple."
            }
        }
    }

    var onStoppedExternally: (() -> Void)?
    var onPauseChangedExternally: ((Bool) -> Void)?

    private let bundleIdentifier = "com.apple.VoiceMemos"
    private let applicationURL = URL(fileURLWithPath: "/System/Applications/VoiceMemos.app")
    private var applicationElement: AXUIElement?
    private var doneButton: AXUIElement?
    private var monitoringTask: Task<Void, Never>?
    private var isMirroring = false
    private var lastPauseState: NativePauseState = .unknown

    private enum NativePauseState: Equatable {
        case recording
        case paused
        case unknown
    }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    func startVisible() async throws {
        guard hasAccessibilityPermission else {
            requestAccessibilityPermission()
            throw BridgeError.accessibilityPermissionRequired
        }

        let application = try await launchIfNeeded()
        application.unhide()
        application.activate(options: [.activateIgnoringOtherApps])

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var nativeState = pauseState(in: applicationElement)

        // Если в Apple «Диктофоне» уже идёт запись, просто подключаемся к ней.
        if nativeState == .unknown {
            let recordButton = try await waitForControl(named: "начать запись", in: applicationElement) {
                self.recordButton(in: $0)
            }
            guard AXUIElementPerformAction(recordButton, kAXPressAction as CFString) == .success else {
                throw BridgeError.commandFailed("начать запись")
            }
            nativeState = try await waitForRecordingState(in: applicationElement)
            if nativeState == .unknown {
                throw BridgeError.commandFailed("начать запись")
            }
        }

        self.applicationElement = applicationElement
        doneButton = doneButton(in: applicationElement)
        isMirroring = true
        lastPauseState = nativeState
        startMonitoring()
    }

    @discardableResult
    func setPaused(_ paused: Bool) -> Bool {
        guard isMirroring, let applicationElement else { return false }
        let desiredButton = paused ? pauseButton(in: applicationElement) : resumeButton(in: applicationElement)
        guard let desiredButton else { return false }
        let succeeded = AXUIElementPerformAction(desiredButton, kAXPressAction as CFString) == .success
        if succeeded {
            lastPauseState = paused ? .paused : .recording
        }
        return succeeded
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil

        guard isMirroring else { return }
        isMirroring = false

        if let doneButton, isEnabled(doneButton) {
            _ = AXUIElementPerformAction(doneButton, kAXPressAction as CFString)
        }
        applicationElement = nil
        self.doneButton = nil
        lastPauseState = .unknown
    }

    func disconnect() {
        monitoringTask?.cancel()
        monitoringTask = nil
        isMirroring = false
        applicationElement = nil
        doneButton = nil
        lastPauseState = .unknown
    }

    func showApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, _ in }
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private var runningApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    private func launchIfNeeded() async throws -> NSRunningApplication {
        if let runningApplication {
            runningApplication.unhide()
            runningApplication.activate(options: [.activateIgnoringOtherApps])
            return runningApplication
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { app, error in
                if let app {
                    continuation.resume(returning: app)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: BridgeError.applicationUnavailable)
                }
            }
        }
    }

    private func waitForRecordingState(in applicationElement: AXUIElement) async throws -> NativePauseState {
        for _ in 0..<40 {
            try Task.checkCancellation()
            let state = pauseState(in: applicationElement)
            if state != .unknown { return state }
            try await Task.sleep(for: .milliseconds(100))
        }
        return .unknown
    }

    private func waitForControl(
        named name: String,
        in applicationElement: AXUIElement,
        resolver: (AXUIElement) -> AXUIElement?
    ) async throws -> AXUIElement {
        for _ in 0..<40 {
            try Task.checkCancellation()
            if let control = resolver(applicationElement) {
                return control
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BridgeError.commandUnavailable(name)
    }

    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            // Avoid treating the short menu transition immediately after start
            // as an external stop.
            try? await Task.sleep(for: .seconds(1))
            var stoppedChecks = 0

            while !Task.isCancelled {
                guard let self, self.isMirroring, let applicationElement = self.applicationElement else { return }
                let currentPauseState = self.pauseState(in: applicationElement)
                if currentPauseState == .unknown {
                    stoppedChecks += 1
                    if stoppedChecks >= 3 {
                        self.isMirroring = false
                        self.applicationElement = nil
                        self.doneButton = nil
                        self.monitoringTask = nil
                        self.lastPauseState = .unknown
                        self.onStoppedExternally?()
                        return
                    }
                } else {
                    stoppedChecks = 0
                    self.doneButton = self.doneButton(in: applicationElement)
                }

                if currentPauseState != .unknown, currentPauseState != self.lastPauseState {
                    self.lastPauseState = currentPauseState
                    self.onPauseChangedExternally?(currentPauseState == .paused)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func pauseState(in element: AXUIElement) -> NativePauseState {
        if resumeButton(in: element) != nil { return .paused }
        if pauseButton(in: element) != nil { return .recording }
        return .unknown
    }

    private func pauseButton(in element: AXUIElement) -> AXUIElement? {
        button(in: element, matchingAny: ["pause", "пауз", "приостан"])
    }

    private func resumeButton(in element: AXUIElement) -> AXUIElement? {
        button(in: element, matchingAny: ["resume", "возобнов", "продолж"])
    }

    private func recordButton(in element: AXUIElement) -> AXUIElement? {
        exactButton(in: element, descriptions: ["record", "записать"])
    }

    private func doneButton(in element: AXUIElement) -> AXUIElement? {
        exactButton(
            in: element,
            descriptions: ["done", "готово"],
            identifiers: ["RecordingView/DoneButton"]
        )
    }

    private func exactButton(
        in element: AXUIElement,
        descriptions: Set<String>,
        identifiers: Set<String> = []
    ) -> AXUIElement? {
        let role: String? = attribute(kAXRoleAttribute as CFString, from: element)
        if role == (kAXButtonRole as String) {
            let description: String = attribute(kAXDescriptionAttribute as CFString, from: element) ?? ""
            let identifier: String = attribute(kAXIdentifierAttribute as CFString, from: element) ?? ""
            if descriptions.contains(description.lowercased()) || identifiers.contains(identifier) {
                return element
            }
        }

        let children: [AXUIElement] = attribute(kAXChildrenAttribute as CFString, from: element) ?? []
        for child in children {
            if let result = exactButton(in: child, descriptions: descriptions, identifiers: identifiers) {
                return result
            }
        }
        return nil
    }

    private func button(in element: AXUIElement, matchingAny tokens: [String]) -> AXUIElement? {
        let role: String? = attribute(kAXRoleAttribute as CFString, from: element)
        if role == (kAXButtonRole as String) {
            let searchableAttributes = [
                kAXTitleAttribute as CFString,
                kAXDescriptionAttribute as CFString,
                kAXHelpAttribute as CFString,
                kAXIdentifierAttribute as CFString
            ]
            let combined = searchableAttributes.compactMap { name -> String? in
                attribute(name, from: element)
            }
            .joined(separator: " ")
            .lowercased()

            if tokens.contains(where: combined.contains) {
                return element
            }
        }

        let children: [AXUIElement] = attribute(kAXChildrenAttribute as CFString, from: element) ?? []
        for child in children {
            if let result = button(in: child, matchingAny: tokens) {
                return result
            }
        }
        return nil
    }

    private func isEnabled(_ element: AXUIElement) -> Bool {
        attribute(kAXEnabledAttribute as CFString, from: element) ?? false
    }

    private func attribute<T>(_ name: CFString, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? T
    }
}
