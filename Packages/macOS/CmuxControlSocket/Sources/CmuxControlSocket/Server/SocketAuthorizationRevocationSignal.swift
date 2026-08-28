internal import Darwin
internal import os

/// A one-shot, pollable signal shared by connections accepted under one
/// authorization generation.
///
/// Readers retain the signal while polling its read descriptor. Revocation
/// writes one byte and closes the write end, leaving the read end permanently
/// ready so every reader in the generation wakes without periodic polling.
/// Reader threads only access the immutable read descriptor. Production
/// revocation is serialized by the authorization-state owner, and `deinit`
/// cannot overlap an in-flight method that retains `self`.
public final class SocketAuthorizationRevocationSignal: @unchecked Sendable {
    /// Descriptor that becomes readable when this authorization generation is revoked.
    public let readFileDescriptor: Int32

    /// The write end can be revoked by the authorization owner and by
    /// deinitialization. Swap it under a lock before closing so concurrent
    /// revocations cannot write to a reused descriptor.
    private let writeFileDescriptor: OSAllocatedUnfairLock<Int32>

    /// Creates a signal backed by a close-on-exec pipe.
    public init() {
        var descriptors: [Int32] = [-1, -1]
        if pipe(&descriptors) == 0 {
            readFileDescriptor = descriptors[0]
            writeFileDescriptor = OSAllocatedUnfairLock(initialState: descriptors[1])
            _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        } else {
            // Descriptor exhaustion already prevents accepting useful new
            // clients. Preserve the non-throwing server initializer; the
            // normal per-command generation check remains fail-closed.
            readFileDescriptor = -1
            writeFileDescriptor = OSAllocatedUnfairLock(initialState: -1)
        }
    }

    /// Revokes the generation and wakes every reader polling this signal.
    public func revoke() {
        let descriptor: Int32 = writeFileDescriptor.withLock { descriptor in
            guard descriptor >= 0 else { return -1 }
            let revoked = descriptor
            descriptor = -1
            return revoked
        }
        guard descriptor >= 0 else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(descriptor, &byte, 1)
        close(descriptor)
    }

    deinit {
        revoke()
        if readFileDescriptor >= 0 {
            close(readFileDescriptor)
        }
    }
}
