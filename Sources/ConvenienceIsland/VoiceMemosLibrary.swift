import AVFoundation
import Foundation

struct VoiceMemoLibraryEntry: Sendable {
    let path: String
    let title: String
    let createdAt: Date
    let duration: TimeInterval
    let modificationDate: Date
}

enum VoiceMemosLibraryError: LocalizedError {
    case fullDiskAccessRequired
    case libraryUnavailable

    var errorDescription: String? {
        switch self {
        case .fullDiskAccessRequired:
            "macOS не даёт островку читать библиотеку «Диктофона» без полного доступа к диску."
        case .libraryUnavailable:
            "Библиотека Apple «Диктофона» пока недоступна."
        }
    }
}

struct VoiceMemosLibrary {
    static let rootURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared", isDirectory: true)

    static let supportedExtensions: Set<String> = [
        "m4a", "caf", "wav", "aif", "aiff", "mp3"
    ]

    static func authorizedRecordingURL(for path: String) -> URL? {
        FileSecurity.safeExistingURL(
            path: path,
            under: rootURL,
            allowedExtensions: supportedExtensions
        )
    }

    func scan() throws -> [VoiceMemoLibraryEntry] {
        let fileManager = FileManager.default
        let root = Self.rootURL

        do {
            _ = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw VoiceMemosLibraryError.fullDiskAccessRequired
        } catch {
            if fileManager.fileExists(atPath: root.path) {
                throw VoiceMemosLibraryError.fullDiskAccessRequired
            }
            throw VoiceMemosLibraryError.libraryUnavailable
        }

        let preferredRecordingsRoot = root.appendingPathComponent("Recordings", isDirectory: true)
        let searchRoot = fileManager.fileExists(atPath: preferredRecordingsRoot.path)
            ? preferredRecordingsRoot
            : root
        let requestedKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: requestedKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw VoiceMemosLibraryError.fullDiskAccessRequired
        }

        var entries: [VoiceMemoLibraryEntry] = []
        let now = Date()
        for case let url as URL in enumerator {
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(requestedKeys)),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) > 0 else { continue }

            let modificationDate = values.contentModificationDate ?? values.creationDate ?? now
            // Не показываем файл, который «Диктофон» ещё дописывает.
            guard now.timeIntervalSince(modificationDate) > 2.5 else { continue }

            let asset = AVURLAsset(url: url)
            let seconds = CMTimeGetSeconds(asset.duration)
            guard seconds.isFinite, seconds > 0.05 else { continue }
            let createdAt = values.creationDate ?? modificationDate
            entries.append(
                VoiceMemoLibraryEntry(
                    path: url.path,
                    title: Self.displayTitle(for: asset, url: url, date: createdAt),
                    createdAt: createdAt,
                    duration: seconds,
                    modificationDate: modificationDate
                )
            )
        }

        if let enumerationError {
            let nsError = enumerationError as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileReadNoPermission.rawValue {
                throw VoiceMemosLibraryError.fullDiskAccessRequired
            }
        }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    private static func displayTitle(for asset: AVAsset, url: URL, date: Date) -> String {
        if let titleItem = AVMetadataItem.metadataItems(
            from: asset.commonMetadata,
            filteredByIdentifier: .commonIdentifierTitle
        ).first,
           let title = titleItem.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }

        let fileStem = url.deletingPathExtension().lastPathComponent
        if UUID(uuidString: fileStem) == nil,
           fileStem.range(of: "^[0-9A-Fa-f-]{20,}$", options: .regularExpression) == nil {
            return fileStem
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM, HH:mm"
        return "Запись \(formatter.string(from: date))"
    }
}
