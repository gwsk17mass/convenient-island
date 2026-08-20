import Foundation

enum FileSecurity {
    static func safeChildURL(
        fileName: String,
        in directory: URL,
        allowedExtensions: Set<String>? = nil,
        mustExist: Bool = false
    ) -> URL? {
        guard isSafeFileName(fileName) else { return nil }
        if let allowedExtensions,
           !allowedExtensions.contains(URL(fileURLWithPath: fileName).pathExtension.lowercased()) {
            return nil
        }

        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = directory.appendingPathComponent(fileName).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard isStrictDescendant(resolved, of: root) else { return nil }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: candidate.path) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
                  attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                return nil
            }
        } else if mustExist {
            return nil
        }
        return candidate
    }

    static func safeExistingURL(
        path: String,
        under directory: URL,
        allowedExtensions: Set<String>? = nil
    ) -> URL? {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.resolvingSymlinksInPath()
        guard isStrictDescendant(resolved, of: root),
              FileManager.default.fileExists(atPath: candidate.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return nil
        }
        if let allowedExtensions,
           !allowedExtensions.contains(candidate.pathExtension.lowercased()) {
            return nil
        }
        return candidate
    }

    static func isSafeFileName(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0") else {
            return false
        }
        return URL(fileURLWithPath: value).lastPathComponent == value
    }

    static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    static func ensureDirectory(
        _ directory: URL,
        within root: URL,
        permissions: NSNumber
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path),
           let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw CocoaError(.fileReadInvalidFileName)
        }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions]
        )

        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard directory.standardizedFileURL == root.standardizedFileURL
                || isStrictDescendant(canonicalDirectory, of: canonicalRoot) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: directory.path
        )
    }
}
