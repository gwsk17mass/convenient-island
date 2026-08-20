import AppKit
import Foundation
import Testing
@testable import ConvenienceIsland

@Suite("Security boundaries")
struct SecurityBoundaryTests {
    @Test func acceptsOrdinaryChildFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = FileSecurity.safeChildURL(
            fileName: "Screenshot-safe.png",
            in: root,
            allowedExtensions: ["png"]
        )

        #expect(url?.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    }

    @Test func rejectsTraversalAndNestedComponents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(FileSecurity.safeChildURL(fileName: "../outside.png", in: root) == nil)
        #expect(FileSecurity.safeChildURL(fileName: "nested/outside.png", in: root) == nil)
        #expect(FileSecurity.safeChildURL(fileName: "..", in: root) == nil)
    }

    @Test func rejectsSymlinkEscapingRoot() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let target = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: target)
        let link = root.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(FileSecurity.safeChildURL(fileName: "linked.txt", in: root, mustExist: true) == nil)
        #expect(FileSecurity.safeExistingURL(path: link.path, under: root) == nil)
    }

    @Test func existingURLMustRemainInsideAuthorizedRoot() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let insideFile = root.appendingPathComponent("memo.m4a")
        let outsideFile = outside.appendingPathComponent("memo.m4a")
        try Data([0x01]).write(to: insideFile)
        try Data([0x01]).write(to: outsideFile)

        #expect(FileSecurity.safeExistingURL(path: insideFile.path, under: root, allowedExtensions: ["m4a"]) != nil)
        #expect(FileSecurity.safeExistingURL(path: outsideFile.path, under: root, allowedExtensions: ["m4a"]) == nil)
    }

    @Test func passwordPasteboardItemIsConcealedAndTransient() {
        let item = ClipboardSecurity.secretItem("test-password")

        #expect(item.string(forType: .string) == "test-password")
        #expect(item.types.contains(ClipboardSecurity.concealedType))
        #expect(item.types.contains(ClipboardSecurity.transientType))
    }

    @Test func clipboardImageLimitsRejectEmptyAndOversizedInput() {
        #expect(!ClipboardSecurity.isAllowedImageData(Data(), byteLimit: 10, pixelLimit: 10))
        #expect(!ClipboardSecurity.isAllowedImageData(Data(repeating: 0x41, count: 11), byteLimit: 10, pixelLimit: 10))
    }

    @Test func privateStorageUsesRestrictedPermissions() throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = support.appendingPathComponent("ConvenienceIsland", isDirectory: true)
        try FileSecurity.ensureDirectory(root, within: support, permissions: NSNumber(value: Int16(0o700)))

        let directories = AppDirectories(
            root: root,
            screenshots: root.appendingPathComponent("Screenshots", isDirectory: true),
            originals: root.appendingPathComponent("Originals", isDirectory: true),
            clipboardImages: root.appendingPathComponent("Clipboard", isDirectory: true),
            recordings: root.appendingPathComponent("Recordings", isDirectory: true),
            transcripts: root.appendingPathComponent("Transcripts", isDirectory: true),
            stateFile: root.appendingPathComponent("state.json")
        )
        try StateRepository(directories: directories).save(PersistedState())

        let rootMode = try posixPermissions(at: root)
        let stateMode = try posixPermissions(at: directories.stateFile)
        #expect(rootMode == 0o700)
        #expect(stateMode == 0o600)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConvenienceIslandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
