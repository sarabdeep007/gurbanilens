# GurbaniLens

**Bring the Bani into focus.** 🙏

Real-time Kirtan-to-Pangti detection. Listens to live or recorded Kirtan audio, identifies the currently-sung Shabad and Pangti from Sri Guru Granth Sahib Ji, and displays the Gurmukhi text with transliteration and translations — automatically scrolling as the Ragi sings.

## Vision

Help Sangat follow Kirtan live, improve accessibility for hearing-impaired and non-Punjabi-speaking Sikhs, and deepen Gurbani engagement worldwide. Built as Seva.

## Status

🚧 **Phase 1: CLI Proof-of-Concept** — validating that ASR + fuzzy matching against the SGGS corpus works reliably on varied Kirtan recordings.

See [`CLAUDE.md`](./CLAUDE.md) for full project context, phases, and architecture.

## Use Cases

1. **Personal follow-along app** — phone listens, Sangat reads along during Kirtan
2. **Gurdwara projector system** — auto-syncs Pangti display with Ragi's Kirtan

## Built With Seva In Mind

- Open-source forever
- Free for individuals and Gurdwaras
- No ads, no tracking, no data harvesting
- Privacy-first: on-device processing preferred

## Cloud ASR keys (optional, iOS only)

The iOS app defaults to **on-device Whisper** — no internet needed, no audio leaves your device. Two cloud providers are wired in for A/B testing and for users who want higher accuracy:

- **Sarvam Saaras-v3** (Indian language SOTA, ₹30/hour)
- **Google Gemini 2.5 Flash** (multimodal, lower cost)

To enable them, copy `.env.example` to `.env` at the repo root and fill in the keys you have:

```bash
cp .env.example .env
# edit .env, fill in SARVAM_API_KEY and/or GEMINI_API_KEY
```

`scripts/inject_env_to_plist.sh` runs as a postBuildScript on `xcodebuild`, reads `.env`, and writes the keys into the app's `Info.plist`. `.env` is gitignored — keys never enter the repo.

Cloud providers ship audio to the respective server for transcription — your microphone audio leaves the device. The Settings → Voice recognition → Cloud toggle is OFF by default and includes a 50/month free-trial counter that protects you from accidental burn during testing.

Long-term, we'll proxy cloud requests through `api.taajsingh.com` so individual users never need their own API key.

## Data

Powered by [BaniDB](https://banidb.com) — open Gurbani database maintained by the GurbaniNow team.

## Contributing

This is an early-stage Seva project. Contributions, sample Kirtan recordings, and feedback from Sangat, Sevadaars, and Gurdwara committees are warmly welcomed.

## License

MIT — see [LICENSE](./LICENSE)

---

ਵਾਹਿਗੁਰੂ ਜੀ ਕਾ ਖਾਲਸਾ, ਵਾਹਿਗੁਰੂ ਜੀ ਕੀ ਫਤਹਿ
