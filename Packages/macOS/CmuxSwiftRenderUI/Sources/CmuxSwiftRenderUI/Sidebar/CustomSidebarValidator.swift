import CmuxSwiftRender
import Foundation

/// Validates custom sidebar files using the same JSON schema and Swift interpreter as rendering.
public struct CustomSidebarValidator {
    private static let maxDirectoryEntriesInspected = 4_096
    private static let maxDiscoveredSidebars = 256
    private let fileManager: FileManager
    private let fallbackDataContext: [String: SwiftValue]

    /// Creates a validator with injectable filesystem and data-context dependencies.
    public init(
        fileManager: FileManager = .default,
        fallbackDataContext: [String: SwiftValue] = Self.defaultDataContext
    ) {
        self.fileManager = fileManager
        self.fallbackDataContext = fallbackDataContext
    }

    /// Discovers custom sidebar source files in a directory.
    ///
    /// When several files share a base name, the extension priority is
    /// `js > swift > json`.
    public func discover(in directory: URL, name requestedName: String? = nil) -> [URL] {
        // Priority when several extensions share a base name: js > swift > json.
        func priority(_ ext: String) -> Int {
            switch ext {
            case "js": return 3
            case "swift": return 2
            case "json": return 1
            default: return 0
            }
        }
        var fileByName: [String: URL] = [:]
        guard directory.isFileURL,
              directory.path.hasPrefix("/"),
              directory.path.utf8.count <= SidebarSecurityLimits.maxFilePathBytes,
              let directoryValues = try? directory.resourceValues(
                  forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            return []
        }
        // Use the directory enumerator so a hostile directory cannot force
        // FileManager to materialise an unbounded array before we apply our
        // own inspection cap. Subdirectories are deliberately skipped: custom
        // sidebars are immediate children of this directory. We call
        // `skipDescendants()` instead of relying on an SDK-specific option,
        // because the package is also compiled by the Linux Swift toolchain.
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [] }
        var inspected = 0
        while let object = enumerator.nextObject() {
            inspected += 1
            guard inspected <= Self.maxDirectoryEntriesInspected,
                  let url = object as? URL else {
                if inspected > Self.maxDirectoryEntriesInspected { break }
                continue
            }
            guard url.isFileURL,
                  url.path.utf8.count <= SidebarSecurityLimits.maxFilePathBytes,
                  let values = try? url.resourceValues(
                      forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
                  ) else {
                continue
            }
            if values.isSymbolicLink == true || values.isDirectory == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard priority(ext) > 0 else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if let requestedName, requestedName != name { continue }
            if let existing = fileByName[name], priority(existing.pathExtension.lowercased()) >= priority(ext) { continue }
            fileByName[name] = url
        }

        return fileByName.keys.sorted().prefix(Self.maxDiscoveredSidebars).compactMap { fileByName[$0] }
    }

    /// Validates every discovered sidebar, or one requested sidebar name.
    public func validate(
        directory: URL,
        name requestedName: String? = nil,
        dataContext: [String: SwiftValue]? = nil
    ) -> CustomSidebarValidationReport {
        let urls = discover(in: directory, name: requestedName)
        if let requestedName, urls.isEmpty {
            return CustomSidebarValidationReport(entries: [
                missingEntry(name: requestedName, directory: directory)
            ])
        }
        let context = dataContext ?? fallbackDataContext
        let entries = urls.map { validate(fileURL: $0, dataContext: context) }
        return CustomSidebarValidationReport(entries: entries)
    }

    /// Validates a specific sidebar file URL.
    public func validate(
        fileURL: URL,
        dataContext: [String: SwiftValue]? = nil
    ) -> CustomSidebarValidationEntry {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        let kind: CustomSidebarFileKind
        switch ext {
        case "js": kind = .js
        case "swift": kind = .swift
        default: kind = .json
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return CustomSidebarValidationEntry(
                name: name,
                fileURL: fileURL,
                kind: kind,
                errorMessage: String(localized: "sidebar.custom.validation.fileMissing", defaultValue: "Sidebar file is missing.")
            )
        }

        do {
            switch kind {
            case .swift:
                let source = try SidebarBoundedFileReader.string(from: fileURL, fileManager: fileManager)
                let node = SwiftViewInterpreter().evaluate(source, state: dataContext ?? fallbackDataContext)
                guard node != nil else {
                    return CustomSidebarValidationEntry(
                        name: name,
                        fileURL: fileURL,
                        kind: kind,
                        errorMessage: String(localized: "sidebar.custom.noView", defaultValue: "No supported SwiftUI view found.")
                    )
                }
            case .json:
                let data = try SidebarBoundedFileReader.data(from: fileURL, fileManager: fileManager)
                _ = try DSLDocument.decodeValidated(from: data)
            case .js:
                let source = try SidebarBoundedFileReader.string(from: fileURL, fileManager: fileManager)
                if let message = SidebarJSRuntime.validate(source: source, state: dataContext ?? fallbackDataContext) {
                    return CustomSidebarValidationEntry(
                        name: name,
                        fileURL: fileURL,
                        kind: kind,
                        errorMessage: message
                    )
                }
            }
            return CustomSidebarValidationEntry(
                name: name,
                fileURL: fileURL,
                kind: kind,
                errorMessage: nil
            )
        } catch {
            return CustomSidebarValidationEntry(
                name: name,
                fileURL: fileURL,
                kind: kind,
                errorMessage: describe(error)
            )
        }
    }

    /// Converts decoding and filesystem errors into sidebar-facing text.
    public func describe(_ error: Error) -> String {
        if case SidebarFileReadError.tooLarge = error {
            return String(
                localized: "sidebar.custom.validation.fileTooLarge",
                defaultValue: "Sidebar file is too large.",
                bundle: .module
            )
        }
        if case SidebarFileReadError.invalidUTF8 = error {
            return String(
                localized: "sidebar.custom.validation.invalidEncoding",
                defaultValue: "Sidebar file is not valid UTF-8.",
                bundle: .module
            )
        }
        if error is DSLDocumentValidationError {
            return String(
                localized: "sidebar.custom.validation.resourceLimit",
                defaultValue: "Sidebar JSON exceeds a safe resource limit.",
                bundle: .module
            )
        }
        if let decoding = error as? DecodingError {
            switch decoding {
            case let .keyNotFound(key, ctx):
                return String(
                    format: String(localized: "sidebar.custom.validation.missingKey", defaultValue: "Missing key '%@' at %@"),
                    boundedDiagnostic(key.stringValue),
                    decodingPath(ctx)
                )
            case let .typeMismatch(_, ctx):
                return String(
                    format: String(localized: "sidebar.custom.validation.typeMismatch", defaultValue: "Type mismatch at %@"),
                    decodingPath(ctx)
                )
            case let .valueNotFound(_, ctx):
                return String(
                    format: String(localized: "sidebar.custom.validation.missingValue", defaultValue: "Missing value at %@"),
                    decodingPath(ctx)
                )
            case let .dataCorrupted(ctx):
                return String(
                    format: String(localized: "sidebar.custom.validation.invalidJSON", defaultValue: "Invalid JSON at %@"),
                    decodingPath(ctx)
                )
            @unknown default:
                return String(localized: "sidebar.custom.validation.decodeFailed", defaultValue: "Failed to decode sidebar JSON.")
            }
        }
        return String(localized: "sidebar.custom.validation.readFailed", defaultValue: "Failed to read sidebar file.")
    }

    /// Representative data context used when validating Swift sidebars outside a live render.
    public static let defaultDataContext: [String: SwiftValue] = [
        "workspaces": .array([
            .object([
                "id": .string("workspace-sample"),
                "title": .string("Sample Workspace"),
                "selected": .bool(true),
                "pinned": .bool(false),
                "index": .int(0),
                "directory": .string("~/project"),
                "ports": .array([.int(3000)]),
                "portCount": .int(1),
                "unread": .int(0),
                "tabs": .array([]),
                "tabCount": .int(0),
                "description": .string(""),
                "color": .string(""),
                "branch": .string("main"),
                "dirty": .bool(false),
                "pr": .string(""),
                "prs": .array([]),
                "progress": .string(""),
                "latestMessage": .string(""),
                "latestPrompt": .string(""),
                "latestAt": .string(""),
                "remote": .string("")
            ])
        ]),
        "groups": .array([
            .object([
                "id": .string("group-sample"),
                "name": .string("Sample Group"),
                "collapsed": .bool(false),
                "pinned": .bool(false),
                "anchorId": .string("workspace-sample"),
            ])
        ]),
        "workspaceCount": .int(1),
        "selectedTitle": .string("Sample Workspace"),
        "selectedId": .string("workspace-sample"),
        "unreadTotal": .int(0),
        "clock": .string("12:00")
    ]

    private func missingEntry(name: String, directory: URL) -> CustomSidebarValidationEntry {
        let candidates = ["js", "swift", "json"].map { directory.appendingPathComponent("\(name).\($0)") }
        let missingURL = candidates.first { fileManager.fileExists(atPath: $0.path) } ?? candidates[2]
        let kind: CustomSidebarFileKind
        switch missingURL.pathExtension.lowercased() {
        case "js": kind = .js
        case "swift": kind = .swift
        default: kind = .json
        }
        return CustomSidebarValidationEntry(
            name: name,
            fileURL: missingURL,
            kind: kind,
            errorMessage: String(localized: "sidebar.custom.validation.fileMissing", defaultValue: "Sidebar file is missing.")
        )
    }
}

private func decodingPath(_ ctx: DecodingError.Context) -> String {
    let parts = ctx.codingPath.prefix(32).map { boundedDiagnostic($0.stringValue) }
    return parts.isEmpty ? String(localized: "sidebar.custom.validation.rootPath", defaultValue: "root") : parts.joined(separator: " › ")
}

/// Decoding keys come from the sidebar file. Keep malformed input from
/// injecting control characters or an unbounded string into the validation UI.
private func boundedDiagnostic(_ value: String) -> String {
    var result = ""
    for scalar in value.unicodeScalars {
        let replacement = CharacterSet.controlCharacters.contains(scalar) ? "�" : String(scalar)
        guard result.utf8.count + replacement.utf8.count <= SidebarSecurityLimits.maxDiagnosticComponentBytes else {
            break
        }
        result.append(contentsOf: replacement)
    }
    return result.isEmpty ? "?" : result
}
