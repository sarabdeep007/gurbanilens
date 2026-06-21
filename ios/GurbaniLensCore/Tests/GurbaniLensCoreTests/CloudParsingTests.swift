import XCTest
@testable import GurbaniLensCore

/// Phase A.4b — unit tests for the parsing + script-detection helpers
/// shared by the iOS SarvamProvider + GeminiProvider. Pure functions,
/// no network / Bundle / Foundation-on-Linux quirks → runs cleanly via
/// `swift test` against the GurbaniLensCore SPM target.
final class CloudParsingTests: XCTestCase {

    // MARK: - detectScript

    func testDetectScript_pureGurmukhi() {
        XCTAssertEqual(
            CloudParsing.detectScript("ਏਕ ਓਅੰਕਾਰ ਸਤਿ ਨਾਮੁ"),
            .gurmukhi
        )
    }

    func testDetectScript_pureDevanagari() {
        XCTAssertEqual(
            CloudParsing.detectScript("एक ओंकार सत नाम"),
            .devanagari
        )
    }

    func testDetectScript_other() {
        XCTAssertEqual(CloudParsing.detectScript("hello world"), .other)
        XCTAssertEqual(CloudParsing.detectScript(""), .other)
    }

    func testDetectScript_mixed_majorityWins() {
        // 7 Devanagari scalars vs 1 Gurmukhi scalar — Devanagari wins.
        XCTAssertEqual(
            CloudParsing.detectScript("एकोंकार\u{0A0F}"),
            .devanagari
        )
        // 4 Gurmukhi scalars vs 1 Devanagari scalar — Gurmukhi wins.
        XCTAssertEqual(
            CloudParsing.detectScript("\u{0A0F}\u{0A15}\u{0A13}\u{0A05}\u{0902}"),
            .gurmukhi
        )
    }

    func testDetectScript_tieGoesToGurmukhi() {
        // Exactly equal counts (1 each) → tie resolved toward Gurmukhi
        // so a stray Devanagari artefact in otherwise-Gurmukhi text
        // doesn't flip the display script unexpectedly.
        XCTAssertEqual(CloudParsing.detectScript("ਅा"), .gurmukhi)
    }

    // MARK: - sanitize

    func testSanitize_stripsTranscriptPrefix() {
        XCTAssertEqual(
            CloudParsing.sanitize("Transcript: ਏਕ ਓਅੰਕਾਰ"),
            "ਏਕ ਓਅੰਕਾਰ"
        )
        XCTAssertEqual(
            CloudParsing.sanitize("transcription: hello"),
            "hello"
        )
        XCTAssertEqual(
            CloudParsing.sanitize("Text: foo"),
            "foo"
        )
    }

    func testSanitize_stripsCodeFences() {
        XCTAssertEqual(
            CloudParsing.sanitize("```\nਏਕ ਓਅੰਕਾਰ\n```"),
            "ਏਕ ਓਅੰਕਾਰ"
        )
        XCTAssertEqual(
            CloudParsing.sanitize("```punjabi\nfoo bar\n```"),
            "foo bar"
        )
    }

    func testSanitize_passThrough() {
        XCTAssertEqual(
            CloudParsing.sanitize("ਏਕ ਓਅੰਕਾਰ"),
            "ਏਕ ਓਅੰਕਾਰ"
        )
        XCTAssertEqual(
            CloudParsing.sanitize("   spaced   "),
            "spaced"
        )
    }

    // MARK: - extractSarvamTranscript

    func testSarvam_flatTranscriptField() {
        let dict: [String: Any] = ["transcript": "ਏਕ ਓਅੰਕਾਰ", "is_final": true]
        XCTAssertEqual(
            CloudParsing.extractSarvamTranscript(from: dict),
            "ਏਕ ਓਅੰਕਾਰ"
        )
    }

    func testSarvam_textFallback() {
        let dict: [String: Any] = ["text": "hello"]
        XCTAssertEqual(
            CloudParsing.extractSarvamTranscript(from: dict),
            "hello"
        )
    }

    func testSarvam_nestedDataEnvelope() {
        let dict: [String: Any] = [
            "type": "result",
            "data": ["transcript": "ਨੇਸਟੇਡ"]
        ]
        XCTAssertEqual(
            CloudParsing.extractSarvamTranscript(from: dict),
            "ਨੇਸਟੇਡ"
        )
    }

    func testSarvam_googleStyleAlternatives() {
        let dict: [String: Any] = [
            "results": [
                ["alternatives": [["transcript": "google-style"]]]
            ]
        ]
        XCTAssertEqual(
            CloudParsing.extractSarvamTranscript(from: dict),
            "google-style"
        )
    }

    func testSarvam_appliesSanitize() {
        let dict: [String: Any] = ["transcript": "Transcript: ਟੈਸਟ"]
        XCTAssertEqual(
            CloudParsing.extractSarvamTranscript(from: dict),
            "ਟੈਸਟ"
        )
    }

    func testSarvam_missingFieldsReturnsNil() {
        let dict: [String: Any] = ["unrelated": "noise"]
        XCTAssertNil(CloudParsing.extractSarvamTranscript(from: dict))
    }

    func testSarvam_emptyStringReturnsNil() {
        let dict: [String: Any] = ["transcript": "   "]
        XCTAssertNil(CloudParsing.extractSarvamTranscript(from: dict))
    }

    // MARK: - extractGeminiText

    func testGemini_extractsCandidateText() throws {
        let json = """
        {
          "candidates": [
            { "content": { "parts": [ { "text": "ਏਕ ਓਅੰਕਾਰ" } ] } }
          ]
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertEqual(
            CloudParsing.extractGeminiText(fromResponseJson: data),
            "ਏਕ ਓਅੰਕਾਰ"
        )
    }

    func testGemini_multiPartConcatenation() throws {
        let json = """
        {
          "candidates": [
            { "content": { "parts": [
              { "text": "ਏਕ" },
              { "text": "ਓਅੰਕਾਰ" }
            ] } }
          ]
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertEqual(
            CloudParsing.extractGeminiText(fromResponseJson: data),
            "ਏਕ ਓਅੰਕਾਰ"
        )
    }

    func testGemini_appliesSanitize() throws {
        let json = """
        {
          "candidates": [
            { "content": { "parts": [ { "text": "Transcription: foo" } ] } }
          ]
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertEqual(
            CloudParsing.extractGeminiText(fromResponseJson: data),
            "foo"
        )
    }

    func testGemini_missingCandidatesReturnsNil() throws {
        let json = #"{ "error": { "message": "bad request" } }"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertNil(CloudParsing.extractGeminiText(fromResponseJson: data))
    }

    func testGemini_emptyTextReturnsNil() throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"   "}]}}]}"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertNil(CloudParsing.extractGeminiText(fromResponseJson: data))
    }

    // MARK: - joinAccumulator

    func testJoin_emptyPrev() {
        XCTAssertEqual(CloudParsing.joinAccumulator(prev: "", next: "foo bar"), "foo bar")
    }

    func testJoin_emptyNext() {
        XCTAssertEqual(CloudParsing.joinAccumulator(prev: "foo bar", next: ""), "foo bar")
    }

    func testJoin_simpleConcat_addsSpace() {
        XCTAssertEqual(
            CloudParsing.joinAccumulator(prev: "ਏਕ ਓਅੰਕਾਰ", next: "ਸਤਿ ਨਾਮੁ"),
            "ਏਕ ਓਅੰਕਾਰ ਸਤਿ ਨਾਮੁ"
        )
    }

    func testJoin_overlapDedup() {
        // Construct so the last 20 chars of prev EXACTLY match the
        // first 20 chars of next, exercising the overlap-dedup path.
        let tail = "karataa purakh nira" // 19 chars; we'll pad to 20
        let tail20 = tail + "b"           // 20 chars
        let prev = "ek oankaar sat naam " + tail20  // ends with tail20
        let next = tail20 + "hau akaal"             // begins with tail20
        XCTAssertEqual(String(prev.suffix(20)), tail20, "Test setup: prev's last-20 should equal tail20")
        XCTAssertTrue(next.hasPrefix(tail20), "Test setup: next should start with tail20")
        let joined = CloudParsing.joinAccumulator(prev: prev, next: next)
        XCTAssertEqual(joined, prev + String(next.dropFirst(tail20.count)))
    }

    func testJoin_noOverlapAddsSpace() {
        let prev = "ek oankaar"
        let next = "completely different content"
        XCTAssertEqual(
            CloudParsing.joinAccumulator(prev: prev, next: next),
            "ek oankaar completely different content"
        )
    }

    func testJoin_trimsWhitespace() {
        XCTAssertEqual(
            CloudParsing.joinAccumulator(prev: "  foo  ", next: "  bar  "),
            "foo bar"
        )
    }
}
