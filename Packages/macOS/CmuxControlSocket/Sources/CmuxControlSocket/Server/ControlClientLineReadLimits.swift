/// Resource limits applied while a socket client is not yet authorized.
public struct ControlClientLineReadLimits: Sendable {
    /// Largest preauthorization byte budget accepted from any caller.
    ///
    /// The connection is unauthenticated while this limit is active, so a
    /// public initializer must not allow a caller to accidentally disable the
    /// resource bound with `Int.max`.
    public static let maximumAllowedBytes = 8 * 1024 * 1024

    /// Longest preauthorization window accepted from any caller.
    ///
    /// A finite cap prevents an invalid or forgotten timeout from keeping an
    /// unauthenticated connection alive indefinitely.
    public static let maximumAllowedTimeoutMilliseconds = 5 * 60 * 1_000

    /// Maximum raw bytes read during the limited phase.
    public let maximumBytes: Int

    /// Absolute read budget, measured from reader creation.
    public let timeoutMilliseconds: Int

    /// Creates preauthorization read limits.
    ///
    /// - Parameters:
    ///   - maximumBytes: Maximum raw bytes, including invalid UTF-8 and delimiters.
    ///   - timeoutMilliseconds: Total time allowed before authorization
    ///     clears the limits.
    public init(maximumBytes: Int, timeoutMilliseconds: Int) {
        self.maximumBytes = min(
            max(0, maximumBytes),
            Self.maximumAllowedBytes
        )
        self.timeoutMilliseconds = min(
            max(0, timeoutMilliseconds),
            Self.maximumAllowedTimeoutMilliseconds
        )
    }
}
