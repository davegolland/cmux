import Foundation

/// Constructs the small environment a sidebar worker needs. A render worker
/// is a crash-isolation boundary, not a reason to copy the host's entire
/// environment, which can contain socket passwords, cloud tokens, and API
/// keys. Test-only fault-injection variables still arrive through the
/// explicit `extraEnvironment` initializer argument.
enum SidebarWorkerEnvironment {
    private static let maxKeyBytes = 128
    private static let maxValueBytes = 16 * 1024
    private static let maxEnvironmentBytes = 64 * 1024

    private static let inheritedKeys: Set<String> = [
        "HOME", "PATH", "TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL", "LC_CTYPE",
        "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "OS_ACTIVITY_MODE",
        // These are harmless AppKit/runtime hints and do not carry credentials.
        "NSUnbufferedIO",
    ]

    private static let safeDebugKeys: Set<String> = [
        "CMUX_RENDER_WORKER_DEBUG",
        "CMUX_SIDEBAR_MARQUEE_DEBUG",
        "CMUX_REORDER_DEBUG",
    ]

    // Fault-injection switches are explicit capabilities used only by package
    // tests. Do not pass arbitrary caller-provided variables into a worker:
    // an environment value can contain secrets or alter runtime behavior.
    private static let explicitTestKeys: Set<String> = [
        "CMUX_INTERPRETER_TEST_CRASH_TOKEN",
        "CMUX_INTERPRETER_TEST_HANG_TOKEN",
        "CMUX_RENDER_FIXTURE_CRASH_TOKEN",
        "CMUX_RENDER_FIXTURE_CLOSE_STDIN_ONCE_PATH",
        "CMUX_RENDER_FIXTURE_HANG_TOKEN",
        "CMUX_RENDER_FIXTURE_STOP_READING_ONCE_PATH",
    ]

    static func make(
        extra: [String: String],
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result: [String: String] = [:]
        var retainedBytes = 0
        for (key, value) in inherited where inheritedKeys.contains(key) || safeDebugKeys.contains(key) {
            guard valid(key: key, value: value),
                  retainedBytes <= maxEnvironmentBytes - key.utf8.count - value.utf8.count else {
                continue
            }
            result[key] = value
            retainedBytes += key.utf8.count + value.utf8.count
        }
        // Explicit values are used by the supervisor's tests and are an
        // intentional caller capability. Keep the allowlist and byte cap even
        // for explicit values so a public test hook cannot become an arbitrary
        // environment injection surface.
        for (key, value) in extra where explicitTestKeys.contains(key) || safeDebugKeys.contains(key) {
            guard valid(key: key, value: value) else { continue }
            let previous = result[key].map { key.utf8.count + $0.utf8.count } ?? 0
            guard retainedBytes - previous <= maxEnvironmentBytes - key.utf8.count - value.utf8.count else {
                continue
            }
            result[key] = value
            retainedBytes = retainedBytes - previous + key.utf8.count + value.utf8.count
        }
        return result
    }

    private static func valid(key: String, value: String) -> Bool {
        guard !key.isEmpty,
              key.utf8.count <= maxKeyBytes,
              key.unicodeScalars.allSatisfy({ scalar in
                  scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
              }),
              value.utf8.count <= maxValueBytes,
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }
        return true
    }
}
