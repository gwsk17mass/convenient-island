import Foundation

enum IslandTab: String, CaseIterable, Identifiable, Codable {
    case screenshots
    case clipboard
    case documents
    case credentials
    case recordings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshots: "Снимки"
        case .clipboard: "Буфер"
        case .documents: "Документы"
        case .credentials: "Доступы"
        case .recordings: "Диктофон"
        }
    }

    var symbol: String {
        switch self {
        case .screenshots: "camera.viewfinder"
        case .clipboard: "clipboard"
        case .documents: "doc.text"
        case .credentials: "key"
        case .recordings: "waveform"
        }
    }
}

enum IslandPosition: String, CaseIterable, Codable {
    case left
    case center
    case right

    var title: String {
        switch self {
        case .left: "Слева"
        case .center: "По центру"
        case .right: "Справа"
        }
    }
}

enum IslandConfigurationMode: Equatable {
    case none
    case resize
    case reposition
}

struct IslandFolder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var colorName: String = "graphite"
    var createdAt: Date = Date()
    var tab: IslandTab?
}

struct ScreenshotItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var fileName: String
    var createdAt: Date = Date()
    var folderID: UUID?
    var isPinned: Bool = false
}

enum ClipboardContentKind: String, Codable, Hashable {
    case text
    case link
    case image

    var title: String {
        switch self {
        case .text: "Текст"
        case .link: "Ссылка"
        case .image: "Изображение"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        }
    }
}

struct ClipboardItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var text: String
    var sourceApplication: String?
    var createdAt: Date = Date()
    var folderID: UUID?
    var isPinned: Bool = false
    var contentKind: ClipboardContentKind?
    var imageFileName: String?
    var imageSHA256: String?

    var resolvedKind: ClipboardContentKind {
        if imageFileName != nil { return .image }
        return contentKind ?? Self.inferredKind(for: text)
    }

    static func inferredKind(for text: String) -> ClipboardContentKind {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.contains(where: \.isWhitespace),
              let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return .text }
        return .link
    }
}

struct DocumentItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var displayName: String
    var bookmarkBase64: String
    var pathHint: String
    var addedAt: Date = Date()
    var folderID: UUID?
    var isPinned: Bool = false
}

struct CredentialItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var username: String
    var service: String
    var createdAt: Date = Date()
    var folderID: UUID?
    var fileBookmarkBase64: String?
    var filePathHint: String?
}

struct CredentialFileValues: Equatable {
    var title: String
    var service: String
    var username: String
    var password: String
    var extras: [CredentialExtraField] = []
}

enum CredentialExtraKind: String, Equatable {
    case website
    case messenger
    case secret
    case custom

    var title: String {
        switch self {
        case .website: "Сайт"
        case .messenger: "Мессенджер"
        case .secret: "Токен / API"
        case .custom: "Дополнение"
        }
    }

    var symbol: String {
        switch self {
        case .website: "globe"
        case .messenger: "message.fill"
        case .secret: "key.horizontal.fill"
        case .custom: "text.badge.plus"
        }
    }
}

struct CredentialExtraField: Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: CredentialExtraKind
    var label: String
    var value: String
    var password: String = ""
}

struct RecordingItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var fileName: String
    var createdAt: Date = Date()
    var duration: TimeInterval
    var transcriptBaseName: String?
    var folderID: UUID?
    var source: RecordingSource?
    var externalPath: String?
    var sourceModificationDate: Date?

    var resolvedSource: RecordingSource { source ?? .island }
    var isAppleVoiceMemo: Bool { resolvedSource == .appleVoiceMemos }
}

enum RecordingSource: String, Codable, Hashable {
    case island
    case appleVoiceMemos
}

enum RecordingTranscriptionState: Equatable {
    case idle
    case running
    case ready
    case failed(String)
}

enum SystemVoiceMemoSyncState: Equatable {
    case idle
    case starting
    case recording
    case permissionRequired
    case failed(String)
}

enum VoiceMemosLibraryAccessState: Equatable {
    case checking
    case granted
    case fullDiskAccessRequired
    case failed(String)
}

enum ScreenCaptureAccessState: Equatable {
    case granted
    case permissionRequired
    case settingsOpened
}

enum IslandLayoutMode: String, Codable, Hashable {
    case list
    case grid
    case icons

    var toggled: IslandLayoutMode {
        switch self {
        case .list: .grid
        case .grid: .icons
        case .icons: .list
        }
    }
}

struct PersistedState: Codable {
    var screenshots: [ScreenshotItem] = []
    var clipboardItems: [ClipboardItem] = []
    var documents: [DocumentItem] = []
    var credentials: [CredentialItem] = []
    var recordings: [RecordingItem]?
    var folders: [IslandFolder] = []
    var islandPosition: IslandPosition = .center
    var islandHorizontalAnchor: Double?
    var clipboardMonitoringEnabled = true
    var customExpandedWidth: Double?
    var customExpandedHeight: Double?
    var layoutModes: [String: IslandLayoutMode]?
}

extension Notification.Name {
    static let islandExpansionChanged = Notification.Name("ConvenienceIsland.expansionChanged")
    static let islandPositionChanged = Notification.Name("ConvenienceIsland.positionChanged")
    static let islandRequestSnap = Notification.Name("ConvenienceIsland.requestSnap")
    static let islandPreferredSizeChanged = Notification.Name("ConvenienceIsland.preferredSizeChanged")
    static let islandCustomSizeChanged = Notification.Name("ConvenienceIsland.customSizeChanged")
    static let islandConfigurationModeChanged = Notification.Name("ConvenienceIsland.configurationModeChanged")
    static let islandCaptureVisibilityChanged = Notification.Name("ConvenienceIsland.captureVisibilityChanged")
}
