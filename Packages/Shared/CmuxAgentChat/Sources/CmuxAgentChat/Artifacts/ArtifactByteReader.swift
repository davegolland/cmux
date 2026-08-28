import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads already-authorized artifact bytes and metadata from the local filesystem.
///
/// Authorization is intentionally outside this type. Callers must scope-check the
/// requested path before invoking these methods.
public struct ArtifactByteReader: Sendable {
    /// Maximum immediate children returned by one directory-list request.
    public static let maximumDirectoryEntryCount = 500
    /// Maximum bytes returned by one fetch request, even when this type is
    /// called directly instead of through an RPC handler.
    public static let maximumFetchBytes = ChatArtifactTransferPolicy.defaultPolicy.maxRawChunkBytes
    /// Maximum compressed bytes read into memory while creating one thumbnail.
    public static let maximumThumbnailInputBytes = 64 * 1024 * 1024
    /// Maximum requested thumbnail dimension accepted by the decoder.
    public static let maximumThumbnailDimension = 4_096
    /// Maximum source image dimension inspected before ImageIO decodes a
    /// thumbnail. Compressed images can be small while declaring a very large
    /// pixel surface, so the compressed-byte limit alone is not sufficient.
    public static let maximumThumbnailSourceDimension = 32_768
    /// Maximum source pixels inspected before thumbnail decoding. This keeps
    /// decompression-bomb images from allocating an oversized intermediate
    /// surface even when both individual dimensions look reasonable.
    public static let maximumThumbnailSourcePixels = 64 * 1024 * 1024
    private static let utf8SniffByteCount = 8 * 1024
    private static let ioChunkBytes = 64 * 1024

    /// Filesystem/decoder failures surfaced by artifact RPC handlers.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The scoped path no longer exists or cannot be statted.
        case fileNotFound
        /// The scoped path exists but cannot be read by cmux.
        case permissionDenied
        /// The operation requires a directory, but the path is not one.
        case notDirectory
        /// The operation requires a regular file, but the path is another filesystem type.
        case notRegularFile
        /// The operation does not apply to this media type.
        case unsupportedMedia
        /// The path has a supported media type, but its bytes cannot be decoded.
        case corruptMedia
        /// A decoded image could not be encoded as a thumbnail.
        case previewFailed
        /// The path exists, but a filesystem operation failed for another reason.
        case readFailed
    }

    /// Creates a byte reader.
    public init() {}

    /// Reads metadata for an already-authorized path.
    public func stat(path: String) throws -> ChatArtifactStat {
        let metadata = try lstat(path: path)
        let mode = metadata.st_mode & mode_t(S_IFMT)
        let isDirectory = mode == mode_t(S_IFDIR)
        let isRegularFile = mode == mode_t(S_IFREG)
        guard metadata.st_size >= 0 else { throw Error.readFailed }
        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return ChatArtifactStat(
            exists: true,
            isDirectory: isDirectory,
            size: Int64(metadata.st_size),
            modifiedAt: modifiedAt,
            kind: kind(
                path: path,
                isDirectory: isDirectory,
                isRegularFile: isRegularFile
            ),
            mimeType: mimeType(path: path, isDirectory: isDirectory)
        )
    }

    /// Reads one clamped byte chunk for an already-authorized file path.
    public func fetch(path: String, offset: Int64, length: Int) throws -> ChatArtifactChunk {
        let opened = try openVerifiedRegularFile(path: path)
        let handle = opened.handle
        defer { try? handle.close() }
        let totalSize = opened.size
        let clampedOffset = min(max(offset, 0), totalSize)
        let safeLength = min(max(length, 0), Self.maximumFetchBytes)
        // Bound the descriptor read to the size observed with the verified
        // descriptor. Without this clamp, a file that grows after `open` can
        // make one fetch return bytes beyond the authorized snapshot and can
        // turn a nominally bounded range into an unbounded growth race.
        let remaining = totalSize - clampedOffset
        let requestedLength = Int64(safeLength)
        let readLength = Int(min(requestedLength, remaining))
        let data: Data
        do {
            try handle.seek(toOffset: UInt64(clampedOffset))
            data = try handle.read(upToCount: readLength) ?? Data()
        } catch {
            throw filesystemError(error)
        }
        // Compute EOF from the remaining range. A sparse file can report a
        // size near Int64.max, so adding the byte count directly could trap
        // on integer overflow for a valid, authorized path.
        let reachedEOF = data.count < readLength || Int64(data.count) >= remaining
        return ChatArtifactChunk(
            data: data,
            offset: clampedOffset,
            totalSize: totalSize,
            eof: reachedEOF
        )
    }

    /// Generates a JPEG thumbnail for an already-authorized image path.
    public func thumbnail(path: String, maxDimension: Int) throws -> ChatArtifactThumbnail {
        let opened = try openVerifiedRegularFile(path: path)
        let handle = opened.handle
        defer { try? handle.close() }
        guard opened.size <= Int64(Self.maximumThumbnailInputBytes) else {
            throw Error.readFailed
        }
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        guard let type = UTType(filenameExtension: fileExtension),
              type.conforms(to: .image) else {
            throw Error.unsupportedMedia
        }
        let input = try readAll(
            handle: handle,
            expectedSize: opened.size,
            maximumBytes: Self.maximumThumbnailInputBytes
        )
        guard let source = CGImageSourceCreateWithData(input as CFData, nil) else {
            throw Error.corruptMedia
        }
        guard sourceDimensionsAreBounded(source) else {
            throw Error.corruptMedia
        }
        let dimension = min(max(maxDimension, 1), Self.maximumThumbnailDimension)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: dimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Error.corruptMedia
        }
        guard let destinationData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                destinationData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw Error.previewFailed
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.previewFailed
        }
        return ChatArtifactThumbnail(
            data: destinationData as Data,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    /// Checks image metadata before asking ImageIO to materialise pixels. Some
    /// formats do not expose dimensions until decode, so missing metadata is
    /// left to ImageIO; a partially present or invalid pair fails closed.
    private func sourceDimensionsAreBounded(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            return true
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        guard width != nil || height != nil else { return true }
        guard let width, let height,
              width > 0,
              height > 0,
              width <= Self.maximumThumbnailSourceDimension,
              height <= Self.maximumThumbnailSourceDimension,
              width <= Self.maximumThumbnailSourcePixels / height else {
            return false
        }
        return true
    }

    /// Lists up to ``maximumDirectoryEntryCount`` immediate children for an
    /// already-authorized directory.
    ///
    /// One readdir pass collects child names; per-child filesystem metadata is
    /// read only for the capped entries that the listing actually returns.
    public func list(path: String) throws -> ChatArtifactDirectoryListing {
        let stat = try stat(path: path)
        guard stat.isDirectory else { throw Error.notDirectory }
        // Read only one entry beyond the response cap. The old
        // contentsOfDirectory call materialized an unbounded name array for a
        // directory controlled by the terminal, which made a large directory
        // a simple memory-exhaustion input.
        guard let enumerator = FileManager.default.enumerator(atPath: path) else {
            throw Error.readFailed
        }
        var names: [String] = []
        names.reserveCapacity(Self.maximumDirectoryEntryCount + 1)
        while let name = enumerator.nextObject() as? String {
            // This is an immediate-child listing. Never descend into a child
            // directory, including a directory reached through a symlink.
            enumerator.skipDescendants()
            names.append(name)
            if names.count > Self.maximumDirectoryEntryCount {
                break
            }
        }
        let sortedNames = names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        var listed: [ChatArtifactDirectoryEntry] = []
        listed.reserveCapacity(min(sortedNames.count, Self.maximumDirectoryEntryCount))
        for name in sortedNames.prefix(Self.maximumDirectoryEntryCount) {
            do {
                let entry = directoryURL.appendingPathComponent(name)
                let metadata = try lstat(path: entry.path)
                let mode = metadata.st_mode & mode_t(S_IFMT)
                let isDirectory = mode == mode_t(S_IFDIR)
                let isRegularFile = mode == mode_t(S_IFREG)
                guard metadata.st_size >= 0 else { continue }
                listed.append(ChatArtifactDirectoryEntry(
                    name: name,
                    isDirectory: isDirectory,
                    size: Int64(metadata.st_size),
                    kind: kind(
                        path: entry.path,
                        isDirectory: isDirectory,
                        isRegularFile: isRegularFile
                    )
                ))
            } catch {
                let failure = filesystemError(error)
                if failure == .fileNotFound {
                    continue
                }
                throw failure
            }
        }
        return ChatArtifactDirectoryListing(
            entries: listed,
            isTruncated: names.count > Self.maximumDirectoryEntryCount
        )
    }

    /// Infers preview category from directory status, extension, and a verified regular-file UTF-8 sniff.
    public func kind(path: String, isDirectory: Bool) -> ChatArtifactKind {
        return kind(
            path: path,
            isDirectory: isDirectory,
            isRegularFile: nil
        )
    }

    private func kind(
        path: String,
        isDirectory: Bool,
        isRegularFile: Bool?
    ) -> ChatArtifactKind {
        if isDirectory { return .directory }
        // A symlink or other special file must never inherit a preview type
        // from its extension. Callers that have not already inspected the
        // path may leave this nil, so missing paths retain their old
        // extension-derived kind for UI metadata.
        if isRegularFile == false { return .binary }
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        let type = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)
        guard let type, !type.isDynamic else {
            let verifiedRegularFile: Bool
            if let isRegularFile {
                verifiedRegularFile = isRegularFile
            } else {
                let metadata = try? lstat(path: path)
                verifiedRegularFile = metadata.map {
                    ($0.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
                } ?? false
            }
            guard verifiedRegularFile else { return .binary }
            return isUTF8Text(path: path) ? .text : .binary
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) {
            return .text
        }
        return .binary
    }

    private func isUTF8Text(path: String) -> Bool {
        guard let opened = try? openVerifiedRegularFile(path: path) else {
            return false
        }
        let handle = opened.handle
        defer { try? handle.close() }
        let bytes: Data
        do {
            bytes = try handle.read(upToCount: Self.utf8SniffByteCount + 1) ?? Data()
        } catch {
            return false
        }
        let sample = Data(bytes.prefix(Self.utf8SniffByteCount))
        if String(data: sample, encoding: .utf8) != nil {
            return true
        }
        guard bytes.count > Self.utf8SniffByteCount else {
            return false
        }
        return hasValidUTF8PrefixEndingInPartialScalar(sample)
    }

    private func hasValidUTF8PrefixEndingInPartialScalar(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return false }
        let earliestCandidate = max(0, bytes.count - 4)
        for start in stride(from: bytes.count - 1, through: earliestCandidate, by: -1) {
            guard let expectedLength = utf8ScalarLength(leadingByte: bytes[start]) else {
                continue
            }
            let actualLength = bytes.count - start
            guard actualLength < expectedLength,
                  utf8PartialScalarBytesAreValid(Array(bytes[start...])) else {
                continue
            }
            let prefix = Data(bytes[..<start])
            return String(data: prefix, encoding: .utf8) != nil
        }
        return false
    }

    /// Opens `path` without blocking and validates the opened descriptor as a regular file.
    func openVerifiedRegularFile(path: String) throws -> (handle: FileHandle, size: Int64) {
        // Set close-on-exec atomically at open; fcntl afterward cannot close the fork race.
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw filesystemError(errno: Darwin.errno) }

        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            let errorCode = Darwin.errno
            Darwin.close(descriptor)
            throw filesystemError(errno: errorCode)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            Darwin.close(descriptor)
            throw Error.notRegularFile
        }

        let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) >= 0 else {
            let errorCode = Darwin.errno
            Darwin.close(descriptor)
            throw filesystemError(errno: errorCode)
        }

        return (
            FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            Int64(metadata.st_size)
        )
    }

    /// Reads a complete, bounded file through the already-verified descriptor.
    /// The final descriptor stat rejects a growth or truncation race before
    /// the bytes reach ImageIO.
    private func readAll(
        handle: FileHandle,
        expectedSize: Int64,
        maximumBytes: Int
    ) throws -> Data {
        guard expectedSize >= 0,
              expectedSize <= Int64(maximumBytes),
              expectedSize <= Int64(Int.max) else {
            throw Error.readFailed
        }
        let byteCount = Int(expectedSize)
        var result = Data()
        result.reserveCapacity(byteCount)
        while result.count < byteCount {
            let amount = min(Self.ioChunkBytes, byteCount - result.count)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: amount) ?? Data()
            } catch {
                throw filesystemError(error)
            }
            guard !chunk.isEmpty else { throw Error.readFailed }
            result.append(chunk)
        }
        var metadata = Darwin.stat()
        guard Darwin.fstat(handle.fileDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == mode_t(S_IFREG),
              metadata.st_size == off_t(expectedSize) else {
            throw Error.readFailed
        }
        return result
    }

    private func lstat(path: String) throws -> Darwin.stat {
        var metadata = Darwin.stat()
        guard Darwin.lstat(path, &metadata) == 0 else {
            throw filesystemError(errno: Darwin.errno)
        }
        return metadata
    }

    private func utf8ScalarLength(leadingByte: UInt8) -> Int? {
        switch leadingByte {
        case 0xC2...0xDF:
            return 2
        case 0xE0...0xEF:
            return 3
        case 0xF0...0xF4:
            return 4
        default:
            return nil
        }
    }

    private func utf8PartialScalarBytesAreValid(_ bytes: [UInt8]) -> Bool {
        guard let leadingByte = bytes.first else { return false }
        for byte in bytes.dropFirst() where byte & 0xC0 != 0x80 {
            return false
        }
        guard bytes.count > 1 else { return true }
        let firstContinuation = bytes[1]
        switch leadingByte {
        case 0xE0:
            return firstContinuation >= 0xA0
        case 0xED:
            return firstContinuation <= 0x9F
        case 0xF0:
            return firstContinuation >= 0x90
        case 0xF4:
            return firstContinuation <= 0x8F
        default:
            return true
        }
    }

    private func filesystemError(_ error: any Swift.Error) -> Error {
        if let readerError = error as? Error {
            return readerError
        }
        if let posixError = error as? POSIXError {
            return filesystemError(errno: posixError.code.rawValue)
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return filesystemError(errno: Int32(nsError.code))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== nsError {
            return filesystemError(underlying)
        }
        if let cocoaError = error as? CocoaError {
            switch cocoaError.code {
            case .fileReadNoSuchFile:
                return .fileNotFound
            case .fileReadNoPermission:
                return .permissionDenied
            default:
                break
            }
        }
        return .readFailed
    }

    private func filesystemError(errno errorCode: Int32) -> Error {
        switch POSIXErrorCode(rawValue: errorCode) {
        case .ENOENT, .ESTALE:
            return .fileNotFound
        case .EACCES, .EPERM:
            return .permissionDenied
        case .ENOTDIR:
            return .notDirectory
        case .EISDIR:
            return .notRegularFile
        default:
            return .readFailed
        }
    }

    private func mimeType(path: String, isDirectory: Bool) -> String? {
        guard !isDirectory,
              let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) else {
            return nil
        }
        return type.preferredMIMEType
    }
}
