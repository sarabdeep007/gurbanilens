import XCTest
@testable import GurbaniLensCore

/// Brief #9.26 5a/5b/5c tests for the refined ``JaikaraDetector``.
final class JaikaraDetectorTests: XCTestCase {

    // MARK: - 5a: seed expansion

    /// The expanded seeds must include every Guru-name jaikara.
    func test_seedExpansion_coversTegBahadar() {
        let detector = JaikaraDetector()
        // Full substring match against the Teg Bahadar seed.
        let transcript = "ਧੰਨ ਗੁਰੂ ਤੇਗ ਬਹਾਦੁਰ ਸਾਹਿਬ ਜੀ"
        let result = detector.detect(transcript: transcript)
        XCTAssertEqual(result, "ਧੰਨ ਗੁਰੂ ਤੇਗ ਬਹਾਦੁਰ ਸਾਹਿਬ ਜੀ",
            "Full-length Teg Bahadar jaikara transcript must resolve to the Teg Bahadar seed")
        // Sanity: the seeds list explicitly contains every additional Guru.
        for expected in [
            "ਧੰਨ ਗੁਰੂ ਅੰਗਦ ਦੇਵ ਜੀ",
            "ਧੰਨ ਗੁਰੂ ਅਮਰ ਦਾਸ ਜੀ",
            "ਧੰਨ ਗੁਰੂ ਰਾਮ ਦਾਸ ਜੀ",
            "ਧੰਨ ਗੁਰੂ ਅਰਜਨ ਦੇਵ ਜੀ",
            "ਧੰਨ ਗੁਰੂ ਹਰਗੋਬਿੰਦ ਸਾਹਿਬ ਜੀ",
            "ਧੰਨ ਗੁਰੂ ਹਰ ਰਾਇ ਸਾਹਿਬ ਜੀ",
            "ਧੰਨ ਗੁਰੂ ਹਰਿ ਕ੍ਰਿਸ਼ਨ ਸਾਹਿਬ ਜੀ",
            "ਧੰਨ ਗੁਰੂ ਤੇਗ ਬਹਾਦੁਰ ਸਾਹਿਬ ਜੀ",
            "ਧੰਨ ਗੁਰੂ ਗੋਬਿੰਦ ਸਿੰਘ ਜੀ",
            "ਵਾਹਿਗੁਰੂ ਜੀ ਕਾ ਖਾਲਸਾ ਵਾਹਿਗੁਰੂ ਜੀ ਕੀ ਫ਼ਤਹਿ",
        ] {
            XCTAssertTrue(JaikaraDetector.seeds.contains(expected), "Seeds must include: \(expected)")
        }
    }

    // MARK: - 5b: guru-specific-token guard

    /// Transcript "ਧੰਨ ਗੁਰੂ ਤੇਗ" (partial recitation of Teg Bahadar
    /// jaikara) must NOT resolve to Nanak Dev even though it prefix-
    /// matches the Nanak Dev seed. The distinguishing "ਤੇਗ" token
    /// gives the Teg Bahadar seed unambiguous priority.
    func test_guruTokenRequired_blocksNanakWhenTegSung() {
        let detector = JaikaraDetector()
        let result = detector.detect(transcript: "ਧੰਨ ਗੁਰੂ ਤੇਗ")
        XCTAssertEqual(result, "ਧੰਨ ਗੁਰੂ ਤੇਗ ਬਹਾਦੁਰ ਸਾਹਿਬ ਜੀ",
            "Partial recitation containing ਤੇਗ must resolve to Teg Bahadar, NOT Nanak Dev")
        // The pure ambiguous prefix "ਧੰਨ ਗੁਰੂ" must return nil (no
        // Guru-name token → all guarded seeds skip; no unguarded
        // seed matches this transcript).
        let ambiguous = detector.detect(transcript: "ਧੰਨ ਗੁਰੂ")
        XCTAssertNil(ambiguous,
            "Bare \"ਧੰਨ ਗੁਰੂ\" without a Guru-name token must NOT greedy-resolve to Nanak Dev")
    }

    // MARK: - 5c: Mool Mantar context guard

    /// While Mool Mantar's "ਅਕਾਲ ਮੂਰਤਿ" is on-screen, an ASR
    /// transcript containing "ਅਕਾਲ" must NOT fire the "ਅਕਾਲ"
    /// jaikara banner — the raagi is singing Gurbani, not calling
    /// out a jaikara.
    func test_moolMantarContext_blocksAkalBanner() {
        let detector = JaikaraDetector()
        let currentLine = "ਨਿਰਭਉ ਨਿਰਵੈਰੁ ਅਕਾਲ ਮੂਰਤਿ"
        let result = detector.detect(transcript: "ਅਕਾਲ", currentLineText: currentLine)
        XCTAssertNil(result,
            "\"ਅਕਾਲ\" transcript must be suppressed while Mool Mantar (ਅਕਾਲ ਮੂਰਤਿ) is on screen")
        // Sanity: with no context, the same transcript still fires.
        let noContext = detector.detect(transcript: "ਅਕਾਲ")
        XCTAssertNotNil(noContext,
            "\"ਅਕਾਲ\" transcript alone (no context) must still fire the jaikara banner")
    }

    // MARK: - Regression: unchanged wins still fire

    /// Solitary "ਵਾਹਿਗੁਰੂ" transcript must still fire regardless
    /// of the new guards. Context-free path.
    func test_waheguru_stillFiresAlone() {
        let detector = JaikaraDetector()
        let result = detector.detect(transcript: "ਵਾਹਿਗੁਰੂ")
        XCTAssertNotNil(result,
            "Bare Waheguru transcript must still resolve to a Waheguru jaikara")
        // The result must be a Waheguru-family seed (either the
        // solitary form or the doubled form — order/frequency choice
        // in the seeds array picks which one wins).
        XCTAssertTrue(result?.contains("ਵਾਹਿਗੁਰੂ") ?? false)
    }

    /// "ਬੋਲੇ ਸੋ ਨਿਹਾਲ" must still resolve to itself as a full
    /// substring match, with no context text supplied.
    func test_boleSoNihaal_stillFires() {
        let detector = JaikaraDetector()
        let result = detector.detect(transcript: "ਬੋਲੇ ਸੋ ਨਿਹਾਲ")
        XCTAssertEqual(result, "ਬੋਲੇ ਸੋ ਨਿਹਾਲ",
            "Bole so Nihaal jaikara must still fire from a substring match")
    }
}
