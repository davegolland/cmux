import Testing
@testable import CmuxSidebarInterpreterClient

struct SidebarWorkerEnvironmentTests {
    @Test func inheritedEnvironmentIsRestrictedToNonSecretRuntimeKeys() {
        let inherited = [
            "HOME": "/Users/test",
            "PATH": "/usr/bin",
            "CMUX_SOCKET_PASSWORD": "secret",
            "AWS_SECRET_ACCESS_KEY": "secret",
            "API_TOKEN": "secret",
            "CMUX_RENDER_WORKER_DEBUG": "1",
        ]

        let result = SidebarWorkerEnvironment.make(extra: [:], inherited: inherited)

        #expect(result["HOME"] == "/Users/test")
        #expect(result["PATH"] == "/usr/bin")
        #expect(result["CMUX_RENDER_WORKER_DEBUG"] == "1")
        #expect(result["CMUX_SOCKET_PASSWORD"] == nil)
        #expect(result["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(result["API_TOKEN"] == nil)
    }

    @Test func explicitTestEnvironmentIsPassedThrough() {
        let result = SidebarWorkerEnvironment.make(
            extra: ["CMUX_INTERPRETER_TEST_CRASH_TOKEN": "sentinel"],
            inherited: ["CMUX_SOCKET_PASSWORD": "secret"]
        )
        #expect(result["CMUX_INTERPRETER_TEST_CRASH_TOKEN"] == "sentinel")
        #expect(result["CMUX_SOCKET_PASSWORD"] == nil)
    }

    @Test func arbitraryExplicitEnvironmentIsDroppedAndValuesAreBounded() {
        let result = SidebarWorkerEnvironment.make(
            extra: [
                "AWS_SECRET_ACCESS_KEY": "secret",
                "CMUX_INTERPRETER_TEST_CRASH_TOKEN": String(repeating: "x", count: 16_385),
            ],
            inherited: [:]
        )
        #expect(result["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(result["CMUX_INTERPRETER_TEST_CRASH_TOKEN"] == nil)
    }
}
