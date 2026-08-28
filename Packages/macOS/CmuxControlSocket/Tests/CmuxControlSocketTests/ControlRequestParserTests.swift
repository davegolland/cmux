import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("ControlRequestParser")
struct ControlRequestParserTests {
    private let parser = ControlRequestParser()

    private func strictError(_ line: String) -> ControlRequestParseError? {
        switch parser.request(fromLine: line) {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }

    // MARK: - Lenient parse (socket-worker fast path)

    @Test func lenientParsesFullEnvelope() throws {
        let request = try #require(parser.lenientRequest(
            fromLine: #"  {"id":7,"method":" system.ping ","params":{"k":"v"}} "#
        ))
        #expect(request.id == .int(7))
        #expect(request.method == "system.ping")
        #expect(request.params == ["k": .string("v")])
    }

    @Test func lenientRequiresObjectPrefixAfterTrim() {
        #expect(parser.lenientRequest(fromLine: "ping") == nil)
        #expect(parser.lenientRequest(fromLine: #"[{"method":"x"}]"#) == nil)
        #expect(parser.lenientRequest(fromLine: "") == nil)
    }

    @Test func lenientRejectsMissingOrEmptyMethod() {
        #expect(parser.lenientRequest(fromLine: #"{"id":1}"#) == nil)
        #expect(parser.lenientRequest(fromLine: #"{"method":"  "}"#) == nil)
        #expect(parser.lenientRequest(fromLine: #"{"method":5}"#) == nil)
    }

    @Test func lenientDefaultsMissingOrNonObjectParams() throws {
        let missing = try #require(parser.lenientRequest(fromLine: #"{"method":"m"}"#))
        #expect(missing.params.isEmpty)
        #expect(missing.id == nil)
        let nonObject = try #require(parser.lenientRequest(fromLine: #"{"method":"m","params":[1]}"#))
        #expect(nonObject.params.isEmpty)
    }

    // MARK: - Strict parse (main dispatcher)

    @Test func strictParsesEnvelope() throws {
        let result = parser.request(fromLine: #"{"id":"abc","method":"surface.list","params":{"n":2}}"#)
        let request = try #require(try? result.get())
        #expect(request.id == .string("abc"))
        #expect(request.method == "surface.list")
        #expect(request.params == ["n": .int(2)])
    }

    @Test func strictClassifiesInvalidJSON() {
        #expect(strictError("not json") == .invalidJSON)
        #expect(strictError(#"{"method""#) == .invalidJSON)
    }

    @Test func strictClassifiesNonObjectTopLevel() {
        #expect(strictError("[1,2]") == .notAnObject)
    }

    @Test func strictClassifiesMissingMethodAndEchoesId() {
        #expect(strictError(#"{"id":3}"#) == .missingMethod(id: .int(3)))
        #expect(strictError(#"{"method":""}"#) == .missingMethod(id: nil))
        #expect(strictError(#"{"id":null,"method":" "}"#) == .missingMethod(id: .null))
    }

    @Test func strictDoesNotTrimLine() {
        // The legacy dispatcher parsed the raw line; leading whitespace is
        // fine for JSONSerialization, so it still parses.
        let result = parser.request(fromLine: #"  {"method":"m"}"#)
        #expect((try? result.get())?.method == "m")
    }

    // MARK: - Resource limits

    @Test func rejectsExcessiveNestingBeforeFoundationParsing() {
        let line = String(repeating: "[", count: ControlJSONGuard.maximumDepth + 1)
            + "0"
            + String(repeating: "]", count: ControlJSONGuard.maximumDepth + 1)
        #expect(strictError(line) == .invalidJSON)
        #expect(parser.lenientRequest(fromLine: line) == nil)
    }

    @Test func rejectsExcessiveTokenCountBeforeFoundationParsing() {
        let values = String(repeating: "0,", count: ControlJSONGuard.maximumTokens / 2)
            + "0"
        let line = "{\"method\":\"probe\",\"params\":{\"values\":[" + values + "]}}"
        #expect(strictError(line) == .invalidJSON)
    }

    @Test func rejectsOversizedRequestLine() {
        let value = String(repeating: "x", count: ControlJSONGuard.maximumBytes)
        let line = "{\"method\":\"probe\",\"value\":\"" + value + "\"}"
        #expect(line.utf8.count > ControlJSONGuard.maximumBytes)
        #expect(strictError(line) == .invalidJSON)
    }

    @Test func acceptsEscapedUnicodeAndBoundedText() throws {
        let request = try #require(parser.lenientRequest(
            fromLine: #"{"method":"probe","params":{"text":"line\n\u263a"}}"#
        ))
        #expect(request.params["text"] == .string("line\n☺"))
    }

    @Test func rejectsOversizedEnvelopeFieldsBeforeBridging() {
        let longMethod = String(repeating: "m", count: ControlJSONGuard.maximumMethodBytes + 1)
        #expect(parser.lenientRequest(fromLine: #"{"method":""# + longMethod + #""}"#) == nil)

        let longKey = String(repeating: "k", count: ControlJSONGuard.maximumParameterKeyBytes + 1)
        let keyLine = #"{"method":"probe","params":{""# + longKey + #"":"v"}}"#
        #expect(parser.lenientRequest(fromLine: keyLine) == nil)
    }

    @Test func rejectsTooManyTopLevelParameters() {
        var pairs: [String] = []
        pairs.reserveCapacity(ControlJSONGuard.maximumParameterCount + 1)
        for index in 0...ControlJSONGuard.maximumParameterCount {
            pairs.append(#""p"# + String(index) + #"":0"#)
        }
        let line = #"{"method":"probe","params":{"# + pairs.joined(separator: ",") + "}}"
        #expect(parser.lenientRequest(fromLine: line) == nil)
    }
}
