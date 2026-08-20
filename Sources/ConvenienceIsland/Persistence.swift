import Foundation

struct AppDirectories {
    private static let privateDirectoryPermissions = NSNumber(value: Int16(0o700))
    fileprivate static let privateFilePermissions = NSNumber(value: Int16(0o600))

    let root: URL
    let screenshots: URL
    let originals: URL
    let clipboardImages: URL
    let recordings: URL
    let transcripts: URL
    let stateFile: URL

    static func resolve() throws -> AppDirectories {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root: URL
#if DEBUG
        if let overridePath = ProcessInfo.processInfo.environment["CONVENIENCE_ISLAND_DATA_ROOT"],
           !overridePath.isEmpty {
            root = URL(fileURLWithPath: overridePath, isDirectory: true)
        } else {
            root = support.appendingPathComponent("ConvenienceIsland", isDirectory: true)
        }
#else
        root = support.appendingPathComponent("ConvenienceIsland", isDirectory: true)
#endif
        let screenshots = root.appendingPathComponent("Screenshots", isDirectory: true)
        let originals = root.appendingPathComponent("Originals", isDirectory: true)
        let clipboardImages = root.appendingPathComponent("Clipboard", isDirectory: true)
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let transcripts = root.appendingPathComponent("Transcripts", isDirectory: true)

        try FileSecurity.ensureDirectory(
            root,
            within: support,
            permissions: privateDirectoryPermissions
        )
        for directory in [screenshots, originals, clipboardImages, recordings, transcripts] {
            try FileSecurity.ensureDirectory(
                directory,
                within: root,
                permissions: privateDirectoryPermissions
            )
        }

        return AppDirectories(
            root: root,
            screenshots: screenshots,
            originals: originals,
            clipboardImages: clipboardImages,
            recordings: recordings,
            transcripts: transcripts,
            stateFile: root.appendingPathComponent("state.json")
        )
    }
}

struct StateRepository {
    let directories: AppDirectories

    func load() -> PersistedState {
        guard let data = try? Data(contentsOf: directories.stateFile) else {
            return PersistedState()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(PersistedState.self, from: data) else {
            return PersistedState()
        }
        return sanitized(decoded)
    }

    func save(_ state: PersistedState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: directories.stateFile, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: AppDirectories.privateFilePermissions],
            ofItemAtPath: directories.stateFile.path
        )
    }

    private func sanitized(_ source: PersistedState) -> PersistedState {
        var state = source
        state.screenshots = state.screenshots.filter { item in
            FileSecurity.safeChildURL(
                fileName: item.fileName,
                in: directories.screenshots,
                allowedExtensions: ["png"]
            ) != nil
        }
        state.clipboardItems = state.clipboardItems.filter { item in
            guard let fileName = item.imageFileName else { return true }
            let expectedName = "Clipboard-\(item.id.uuidString).png"
            return fileName == expectedName
                && FileSecurity.safeChildURL(
                    fileName: fileName,
                    in: directories.clipboardImages,
                    allowedExtensions: ["png"]
                ) != nil
        }
        state.recordings = state.recordings?.filter { item in
            if item.isAppleVoiceMemo {
                guard let path = item.externalPath else { return false }
                return VoiceMemosLibrary.authorizedRecordingURL(for: path) != nil
            }
            return FileSecurity.safeChildURL(
                fileName: item.fileName,
                in: directories.recordings,
                allowedExtensions: VoiceMemosLibrary.supportedExtensions
            ) != nil
        }
        return state
    }
}
