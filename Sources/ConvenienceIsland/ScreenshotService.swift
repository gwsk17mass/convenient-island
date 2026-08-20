import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenshotService {
    enum CaptureError: LocalizedError {
        case displayUnavailable
        case encodingFailed
        case selectionFailed

        var errorDescription: String? {
            switch self {
            case .displayUnavailable:
                "Не удалось определить экран для снимка."
            case .encodingFailed:
                "Не удалось сохранить снимок."
            case .selectionFailed:
                "Не удалось сохранить выделенную область."
            }
        }
    }

    static var hasScreenCapturePermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenCaptureSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @available(macOS 14.0, *)
    static func captureMainDisplay(to destination: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        let displayID: CGDirectDisplayID? = await MainActor.run { () -> CGDirectDisplayID? in
            guard let screen = NSScreen.main ?? NSScreen.screens.first,
                  let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CGDirectDisplayID(displayNumber.uint32Value)
        }
        guard let displayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApplication = content.applications.first(where: { $0.processID == ownPID })
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplication.map { [$0] } ?? [],
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            throw CaptureError.encodingFailed
        }
        try data.write(to: destination, options: Data.WritingOptions.atomic)
    }

    static func captureSelection(to destination: URL) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", "-t", "png", destination.path]
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                if !FileManager.default.fileExists(atPath: destination.path) {
                    return false
                }
                throw CaptureError.selectionFailed
            }
            guard FileManager.default.fileExists(atPath: destination.path),
                  let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0 else {
                return false
            }
            return true
        }.value
    }
}
