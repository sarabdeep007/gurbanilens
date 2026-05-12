# Phase 1 Conclusion

_Closed 2026-05-12. Decision: proceed to Phase 2A (Paath companion app)._

## What Phase 1 set out to validate

Per `CLAUDE.md`: "Validate that ASR + fuzzy matching against the SGGS corpus works reliably on varied Kirtan recordings *before* investing in mobile/desktop apps."

## What Phase 1 actually built

A working end-to-end CLI:

```
$ gurbanilens match-file ./samples/japji\ sahib\ 1.mp3
[00:00 → 00:04]  long segment (10 tokens) — windowing
  [00:01 → 00:03]  no     (conf  71.8)  Ang 2:P7  [Pankti]
             latin: naanak gaaviyaam gunee nidhaan gaaviyaam sunimgem
             line : naanak; gaaveeai gunee nidhaan |
```

Five Python modules, ~1,500 LOC, 7 commits, 7 project-memory entries.

| Module | Lines | Purpose |
|---|---|---|
| `corpus.py` | ~170 | SGGS SQLite loader (Shabad OS v4.8.7), `lookup()`, `all_lines()`, `shabad_lines()` |
| `matcher.py` | ~110 | Naive `rapidfuzz` matcher with token-coverage discrimination + length factor |
| `asr.py` | ~130 | `ASREngine` Protocol, `WhisperASR` impl, script-aware `to_latin()` |
| `cli.py` | ~140 | `gurbanilens match-file <audio>` with sliding-window matching |
| `scripts/evaluate.py` | ~340 | Full 13-sample evaluation with caching, per-model reports, near-miss inference |
| `tests/test_corpus.py` | ~55 | 4 corpus assertions |
| `tests/test_matcher.py` | ~145 | 11-case regression battery (6 good + 5 bad) |

## Findings (the data)

### Architecture validated end-to-end
Corpus → Whisper → Latin normalisation → matcher → sliding-window → CLI output all wired together and produces sensible, debuggable output.

### Matcher is solid; ASR is the bottleneck
| Model | Confident matches (≥75) | Negative test (waheguru) | Cluster stability |
|---|---|---|---|
| `medium` | 4 / 13 (31%) | ✅ rejected | clean (5/5 harjinder Shabad-grouped correctly) |
| `large-v3` | 6 / 13 (46%) | ✅ rejected | degraded (broke 2 of 3 harjinder cluster predictions) |

The headline 31% → 46% bump is real but misleading: large-v3 trades Shabad-level consistency for per-segment confidence. **Model scaling alone won't get us to projector-grade accuracy.** Fine-tuning on Kirtan is required for Use Case 2.

### Critical defensive result
The length factor with `MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE = 4` eliminated the original 100.0 false positive on `waheguru 1.mp3` (Simran audio — must never match). The system can refuse to match, which is the non-negotiable safety property for the projector use case.

### Other findings worth remembering
- **Whisper-pa transcribes Punjabi to Devanagari**, not Gurmukhi (covered in `whisper_punjabi_devanagari.md` memory)
- **Silero VAD eats sung Kirtan**, must default off (`whisper_vad_kirtan.md`)
- **Whisper is non-deterministic** — same audio, different transcripts on repeat runs. Need seeded mode for projector reproducibility.
- **`shabados/database` v4.8.7** is the SGGS source of truth, not Khalis BaniDB which is API-only (`corpus_source.md`)
- **Gurmukhi is stored in Anmol Lipi font encoding** in the corpus; Unicode conversion deferred but now required for Phase 2A (`script_and_matching_surface.md`)

## What we explicitly deferred

| Deferred | When it becomes required | Why deferred |
|---|---|---|
| Anmol Lipi → Unicode Gurmukhi conversion | **Phase 2A (now)** — user-facing display needs it | Phase 1 was about matching accuracy, not display polish |
| Sequential-progression bias in matcher | Phase 2A — Sehaj Paath mode needs it | Validate base matcher first |
| First-letter prefilter for matcher speed | Maybe Phase 2A if 60K full scan is too slow on mobile | Naive scan was fast enough on desktop |
| Whisper fine-tuning on Kirtan | Phase 2B (parallel track) | Needs labeled dataset Deep is collecting |
| Vishraam-aware scoring | Future polish | Not blocking |
| Line-type weighting (Rahao boost) | Future polish | Not blocking |

## Decision: proceed to Phase 2A

Given the data:
- **Use Case 1** (personal Paath companion, lag-tolerant): viable now with medium ASR + manual confirmation on near-misses. Worth building a thin iOS prototype to test UX assumptions.
- **Use Case 2** (Gurdwara projector, strict accuracy): not shippable yet. Fine-tuning prerequisites needed.

Phase 2A starts with the Paath/Bani recitation app because:
1. **Paath quality > Kirtan quality** at current ASR: `japji sahib 1` scored 96.6 confidence on large-v3 (vs Kirtan samples 76-90). Spoken Paath is genuinely easier for Whisper than sung Kirtan.
2. **Nitnem and Sukhmani are known-content** — the matcher only has to search a few hundred Pangtis per Bani, not all 60K. Constrains search, lifts accuracy.
3. **Sehaj Paath is the harder mode** — find-the-reader-anywhere-in-SGGS — but it's the same algorithm we already validated, with sequential-progression bias added.

Phase 2B (Kirtan dataset / fine-tuning) runs in parallel via separate work tracks (`scripts/fetch_samples.py`, aeneas forced-alignment spike). Phase 2C (projector) waits for both 2A polish and 2B fine-tuning.

## Phase 1 artifacts (preserved)

- Source: `src/gurbanilens/{corpus,matcher,asr,cli}.py`
- Tests: `tests/test_{corpus,matcher}.py` (4 + 3 passing)
- Data: `data/sggs/database.sqlite` (gitignored, fetch via `scripts/fetch_corpus.py`)
- Evaluation: `evaluation/phase1_medium_report.md`, `phase1_large-v3_report.md` + CSVs
- Documentation: 7 memory entries linked from `~/.claude/projects/.../MEMORY.md`

The CLI remains the reference implementation for the matcher's behavior — Phase 2A's Swift/Kotlin ports should produce identical results on the same Latin input.
