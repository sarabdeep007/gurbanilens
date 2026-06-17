import Foundation
import GurbaniLensCore

// Executable port-parity validator. Mirrors the XCTest suite in
// PortParityTests.swift but runs without XCTest (which is unavailable on
// systems with only Apple Command Line Tools, no full Xcode).
//
// Usage:
//   GURBANILENS_CORPUS_PATH=$PWD/data/sggs/database.sqlite \
//     swift run port-parity-run \
//        path/to/test_vectors.json

struct GroundTruth: Decodable {
    let ang: Int
    let pangti: Int
}
struct Thresholds: Decodable {
    let TOKEN_MATCH_THRESHOLD: Double
    let LONG_TOKEN_MIN: Int
    let MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE: Int
    let CANDIDATE_POOL: Int
}
struct PythonCanonical: Decodable {
    let top_ang: Int?
    let top_pangti: Int?
    let top_score: Double?
}
struct GoodAssertions: Decodable {
    let score_at_least: Double
}
struct BadAssertions: Decodable {
    let score_at_most: Double
}
struct Assertions: Decodable {
    let good: GoodAssertions?
    let bad: BadAssertions?
}
struct TestCase: Decodable {
    let id: String
    let label: String
    let query: String
    let category: String
    let python_canonical: PythonCanonical
    let assertions: Assertions
}
struct Vectors: Decodable {
    let version: Int
    let ground_truth: GroundTruth
    let thresholds: Thresholds
    let test_cases: [TestCase]
}

func runValidation() throws {
        FileHandle.standardOutput.write("port-parity-run starting\n".data(using: .utf8)!)
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("usage: port-parity-run <test_vectors.json>")
            exit(2)
        }
        let vectorsURL = URL(fileURLWithPath: args[1])
        guard let dbPathString = ProcessInfo.processInfo.environment["GURBANILENS_CORPUS_PATH"] else {
            print("error: GURBANILENS_CORPUS_PATH env var must point at the SGGS SQLite")
            exit(2)
        }
        let dbURL = URL(fileURLWithPath: dbPathString)
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            print("error: corpus DB not found at \(dbURL.path)")
            exit(2)
        }

        FileHandle.standardError.write("loading json from \(vectorsURL.path)\n".data(using: .utf8)!)
        let data = try Data(contentsOf: vectorsURL)
        FileHandle.standardError.write("json loaded, \(data.count) bytes; decoding\n".data(using: .utf8)!)
        let vectors = try JSONDecoder().decode(Vectors.self, from: data)
        FileHandle.standardError.write("decoded \(vectors.test_cases.count) test cases\n".data(using: .utf8)!)

        // Threshold sanity check vs the constants the Swift code compiles in
        precondition(vectors.thresholds.TOKEN_MATCH_THRESHOLD == Matcher.tokenMatchThreshold,
                     "TOKEN_MATCH_THRESHOLD drift between JSON and Swift code")
        precondition(vectors.thresholds.LONG_TOKEN_MIN == Matcher.longTokenMin,
                     "LONG_TOKEN_MIN drift")
        precondition(vectors.thresholds.MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE ==
                     Matcher.minLongTokensForFullConfidence, "MIN drift")
        precondition(vectors.thresholds.CANDIDATE_POOL == Matcher.candidatePool, "POOL drift")

        FileHandle.standardError.write("loading corpus from \(dbURL.path)\n".data(using: .utf8)!)
        let corpus = try Corpus(dbPath: dbURL)
        FileHandle.standardError.write("corpus loaded; building matcher\n".data(using: .utf8)!)
        let matcher = try Matcher(corpus: corpus)
        FileHandle.standardError.write("matcher built; \(matcher.count) lines indexed\n".data(using: .utf8)!)

        let gt = vectors.ground_truth
        var totalPass = 0
        var totalFail = 0
        var failures: [String] = []

        FileHandle.standardError.write("entering test loop\n".data(using: .utf8)!)
        print("case | category | top | swift_score | py_score | result")
        print(String(repeating: "-", count: 100))

        for tc in vectors.test_cases {
            let results = matcher.match(tc.query, topN: 3)
            let top = results.first
            let pyAng = tc.python_canonical.top_ang ?? -1
            let pyPangti = tc.python_canonical.top_pangti ?? -1
            let pyScore = tc.python_canonical.top_score ?? -1

            var passed = true
            var note: String? = nil

            if tc.category == "good" {
                guard let t = top else {
                    passed = false; note = "no result"
                    failures.append("\(tc.label): no result")
                    continue
                }
                if t.line.ang != gt.ang || t.line.pangti != gt.pangti {
                    passed = false
                    note = "wrong Ang/Pangti"
                    failures.append("\(tc.label): top Ang \(t.line.ang):P\(t.line.pangti ?? -1), expected \(gt.ang):P\(gt.pangti)")
                }
                if let g = tc.assertions.good, t.score < g.score_at_least {
                    passed = false
                    note = (note ?? "") + " score \(String(format: "%.1f", t.score)) < \(String(format: "%.1f", g.score_at_least))"
                    failures.append("\(tc.label): score \(String(format: "%.1f", t.score)) < \(String(format: "%.1f", g.score_at_least))")
                }
            } else {
                // bad
                for r in results where r.line.ang == gt.ang && r.line.pangti == gt.pangti {
                    passed = false
                    note = "GT in top-3"
                    failures.append("\(tc.label): GT in top-3 at score \(String(format: "%.1f", r.score))")
                }
                if let t = top, let b = tc.assertions.bad, t.score > b.score_at_most {
                    passed = false
                    note = (note ?? "") + " score \(String(format: "%.1f", t.score)) > \(String(format: "%.1f", b.score_at_most))"
                    failures.append("\(tc.label): score \(String(format: "%.1f", t.score)) > \(String(format: "%.1f", b.score_at_most))")
                }
            }

            let topDesc = top.map { "Ang \($0.line.ang):P\($0.line.pangti ?? -1)" } ?? "—"
            let swiftScore = top.map { String(format: "%.1f", $0.score) } ?? "—"
            _ = pyAng; _ = pyPangti; _ = pyScore
            let result = passed ? "PASS" : "FAIL"
            let noteStr = note.map { " (" + $0 + ")" } ?? ""
            let line = "\(tc.label) | \(tc.category) | \(topDesc) | \(swiftScore) | py=\(pyScore) | \(result)\(noteStr)"
            FileHandle.standardError.write("\(line)\n".data(using: .utf8)!)

            if passed { totalPass += 1 } else { totalFail += 1 }
        }

        print("\n=========================")
        print("PASS: \(totalPass)")
        print("FAIL: \(totalFail)")
        if !failures.isEmpty {
            print("\nFailures:")
            for f in failures { print("  - " + f) }
            exit(1)
        }
}

do {
    try runValidation()
} catch {
    print("error: \(error)")
    exit(2)
}
