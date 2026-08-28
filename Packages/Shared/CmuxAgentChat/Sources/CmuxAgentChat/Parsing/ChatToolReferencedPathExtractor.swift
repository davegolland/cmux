import Foundation

struct ChatToolReferencedPathExtractor: Sendable {
    private static let pathKeys: Set<String> = ["file_path", "notebook_path", "path"]

    func referencedPaths(in value: TranscriptJSONValue?) -> [String]? {
        guard let value else { return nil }
        var paths: [String] = []
        var seen: Set<String> = []
        appendReferencedPaths(in: value, key: nil, into: &paths, seen: &seen)
        return paths.isEmpty ? nil : paths
    }

    @discardableResult
    private func appendReferencedPaths(
        in value: TranscriptJSONValue,
        key: String?,
        into paths: inout [String],
        seen: inout Set<String>
    ) -> Bool {
        guard paths.count < ChatArtifactSecurityLimits.maxPathsPerValue else { return false }
        if let key, Self.pathKeys.contains(key) {
            return appendStringValues(in: value, into: &paths, seen: &seen)
        }
        switch value {
        case .object(let object):
            for (childKey, childValue) in object {
                guard appendReferencedPaths(
                    in: childValue,
                    key: childKey,
                    into: &paths,
                    seen: &seen
                ) else { return false }
            }
        case .array(let array):
            for item in array {
                guard appendReferencedPaths(in: item, key: nil, into: &paths, seen: &seen) else {
                    return false
                }
            }
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isAbsolutePathValue(trimmed),
               !trimmed.contains(where: \.isWhitespace),
               trimmed.utf8.count <= ChatArtifactSecurityLimits.maxPathBytes,
               !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                append(trimmed, into: &paths, seen: &seen)
            }
        case .number, .bool, .null:
            break
        }
        return paths.count < ChatArtifactSecurityLimits.maxPathsPerValue
    }

    @discardableResult
    private func appendStringValues(
        in value: TranscriptJSONValue,
        into paths: inout [String],
        seen: inout Set<String>
    ) -> Bool {
        guard paths.count < ChatArtifactSecurityLimits.maxPathsPerValue else { return false }
        switch value {
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               trimmed.utf8.count <= ChatArtifactSecurityLimits.maxPathBytes,
               !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                append(trimmed, into: &paths, seen: &seen)
            }
        case .array(let array):
            for item in array {
                guard appendStringValues(in: item, into: &paths, seen: &seen) else { return false }
            }
        case .object(let object):
            for child in object.values {
                guard appendStringValues(in: child, into: &paths, seen: &seen) else { return false }
            }
        case .number, .bool, .null:
            break
        }
        return paths.count < ChatArtifactSecurityLimits.maxPathsPerValue
    }

    private func append(
        _ path: String,
        into paths: inout [String],
        seen: inout Set<String>
    ) {
        guard paths.count < ChatArtifactSecurityLimits.maxPathsPerValue,
              seen.insert(path).inserted else { return }
        paths.append(path)
    }

    private static func isAbsolutePathValue(_ value: String) -> Bool {
        value.hasPrefix("/") || value == "~" || value.hasPrefix("~/") || value.hasPrefix("file://")
    }
}
