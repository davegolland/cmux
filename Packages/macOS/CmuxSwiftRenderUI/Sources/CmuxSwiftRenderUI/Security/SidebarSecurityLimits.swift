import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Resource limits for authored sidebar programs and their host bridge.
///
/// A sidebar is user-editable input. These limits keep a malformed or hostile
/// file from turning one sidebar into an unbounded memory, JSON, or command
/// workload. The values are deliberately shared by the loader, JavaScript
/// runtime, scene store, and action policy so each boundary has the same
/// contract.
public enum SidebarSecurityLimits {
    /// Maximum UTF-8 source size accepted for one sidebar file.
    public static let maxSourceBytes = 1 * 1024 * 1024

    /// Maximum encoded data value sent to JavaScript for one key.
    public static let maxDataJSONBytes = 4 * 1024 * 1024

    /// Maximum data keys delivered to one sidebar runtime. This is separate
    /// from per-node property limits because host state is a flat namespace.
    public static let maxDataKeys = 2_048

    /// Maximum encoded event payload sent to JavaScript.
    public static let maxEventJSONBytes = 64 * 1024

    /// Maximum encoded scene operation batch accepted by the host.
    public static let maxSceneBatchJSONBytes = 2 * 1024 * 1024

    /// Maximum encoded action object accepted from JavaScript.
    public static let maxActionJSONBytes = 16 * 1024

    /// Maximum operations in one scene batch.
    public static let maxSceneOperationsPerBatch = 4_096

    /// Maximum live nodes in one JavaScript scene.
    public static let maxSceneNodes = 4_096

    /// Maximum children attached to one scene node.
    public static let maxSceneChildren = 2_048

    /// Maximum directed child edges retained by one scene graph.
    ///
    /// A child reference is an edge even when it points to a node that is
    /// already present elsewhere. Bounding the total prevents a program from
    /// making a wide graph that is individually valid at every node.
    public static let maxSceneEdges = 16_384

    /// Maximum total property slots retained by one scene graph. Per-node
    /// limits alone still permit a large Cartesian product of nodes and props.
    public static let maxScenePropertyCountTotal = 32_768

    /// Maximum UTF-8 bytes retained by all scene identifiers, keys, and string
    /// properties. This bounds the graph after a sequence of small updates.
    public static let maxSceneStringBytesTotal = 8 * 1024 * 1024

    /// Maximum nesting depth accepted by the declarative JSON tree and the
    /// JavaScript child flattener.
    public static let maxDSLDepth = 64

    /// Maximum properties retained on one scene node.
    public static let maxSceneProperties = 128

    /// Maximum UTF-8 bytes for scene identifiers, types, keys, and data keys.
    public static let maxIdentifierBytes = 128

    /// Maximum UTF-8 bytes for a scene string property.
    public static let maxSceneStringBytes = 16 * 1024

    /// Maximum magnitude of a numeric scene property. SwiftUI layout and
    /// drawing APIs can turn very large finite values into infinities or
    /// expensive geometry, so finite alone is not a safe bound.
    public static let maxSceneNumberMagnitude = 1_000_000.0

    /// Maximum width, height, or row extent accepted by AppKit layout code.
    /// Keep this below the scene-number limit because geometry APIs allocate
    /// backing surfaces and can otherwise turn a finite value into a very
    /// large resource request.
    public static let maxSurfaceDimension = 10_000.0

    /// Maximum commands captured by one button event.
    public static let maxActionCommands = 16

    /// Maximum command calls emitted during one host-delivered UI event.
    public static let maxActionsPerEvent = 32

    /// Maximum UTF-8 bytes in a command method name.
    public static let maxActionMethodBytes = 128

    /// Maximum named parameters in one command.
    public static let maxActionParameters = 32

    /// Maximum UTF-8 bytes in a command parameter name.
    public static let maxActionParameterKeyBytes = 64

    /// Maximum UTF-8 bytes in a command parameter value.
    public static let maxActionParameterValueBytes = 4 * 1024

    /// Maximum UTF-8 bytes in a URL opened by a sidebar.
    public static let maxActionURLBytes = 2 * 1024

    /// Maximum UTF-8 bytes in a sidebar log message.
    public static let maxActionLogBytes = 4 * 1024

    /// Maximum child-agent correlation id exposed by the agent registry.
    public static let maxAgentChildIDBytes = 128

    /// Maximum child-agent label exposed by the agent registry.
    public static let maxAgentChildLabelBytes = 512

    /// Maximum UTF-8 bytes for one validation diagnostic component.
    public static let maxDiagnosticComponentBytes = 512

    /// Returns a UTF-8 bounded string without splitting a Unicode scalar.
    /// Diagnostics and authored text can be attacker-controlled, so callers
    /// must bound them before logging or retaining them.
    public static func boundedString(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0, value.utf8.count > maxBytes else {
            return maxBytes > 0 ? value : ""
        }
        var result = ""
        result.reserveCapacity(maxBytes)
        var used = 0
        for scalar in value.unicodeScalars {
            let width = String(scalar).utf8.count
            guard used + width <= maxBytes else { break }
            result.unicodeScalars.append(scalar)
            used += width
        }
        return result
    }
}

/// A bounded read error that can be shown without exposing filesystem details.
enum SidebarFileReadError: Error {
    case tooLarge
    case invalidUTF8
    case notRegularFile
    case readFailed
}

/// Reads an authored sidebar without allowing a file-size race to allocate an
/// unbounded `Data` value. The extra byte read detects a file that grows after
/// the metadata check.
enum SidebarBoundedFileReader {
    private static let chunkSize = 64 * 1024

    static func data(from url: URL, fileManager: FileManager = .default) throws -> Data {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular else {
            throw SidebarFileReadError.notRegularFile
        }
        if let size = attributes[.size] as? NSNumber,
           size.uint64Value > UInt64(SidebarSecurityLimits.maxSourceBytes) {
            throw SidebarFileReadError.tooLarge
        }

#if canImport(Darwin)
        // Open without following the final symlink. The metadata check above
        // is useful for injected FileManager implementations, but it is not a
        // security boundary by itself because the path can change between
        // `stat` and `open`. `O_NOFOLLOW` closes that TOCTOU window for the
        // actual read descriptor.
        // A sidebar source path is authored input. O_NONBLOCK avoids blocking
        // the renderer if the path is swapped to a FIFO after validation.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SidebarFileReadError.notRegularFile }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            throw SidebarFileReadError.notRegularFile
        }
        guard info.st_size >= 0 else { throw SidebarFileReadError.readFailed }
        if info.st_size > off_t(SidebarSecurityLimits.maxSourceBytes) {
            throw SidebarFileReadError.tooLarge
        }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while result.count <= SidebarSecurityLimits.maxSourceBytes {
            let remaining = SidebarSecurityLimits.maxSourceBytes + 1 - result.count
            let amount = min(buffer.count, remaining)
            let readCount = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, amount)
            }
            if readCount > 0 {
                buffer.withUnsafeBytes { raw in
                    result.append(contentsOf: raw.bindMemory(to: UInt8.self).prefix(readCount))
                }
            } else if readCount == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw SidebarFileReadError.readFailed
            }
        }
        guard result.count <= SidebarSecurityLimits.maxSourceBytes else {
            throw SidebarFileReadError.tooLarge
        }
        return result
#else
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while result.count <= SidebarSecurityLimits.maxSourceBytes {
            let remaining = SidebarSecurityLimits.maxSourceBytes + 1 - result.count
            let amount = min(chunkSize, remaining)
            guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else { break }
            result.append(chunk)
        }
        guard result.count <= SidebarSecurityLimits.maxSourceBytes else {
            throw SidebarFileReadError.tooLarge
        }
        return result
#endif
    }

    static func string(from url: URL, fileManager: FileManager = .default) throws -> String {
        let data = try self.data(from: url, fileManager: fileManager)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SidebarFileReadError.invalidUTF8
        }
        return string
    }
}
