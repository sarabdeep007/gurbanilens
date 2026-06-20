import Foundation

/// Minimal WAV writer for 16 kHz mono Float32 PCM. Writes a standard
/// `WAVE_FORMAT_IEEE_FLOAT` (format code 3) RIFF container that QuickTime,
/// Audacity, and ffmpeg open without complaint.
///
/// Used by v1 voice-search to persist every captured clip to the app's
/// Documents directory so we can hear exactly what WhisperKit received
/// when transcription goes sideways.
///
/// Extraction: in Xcode → Window → Devices and Simulators → (your iPhone)
/// → Installed Apps → GurbaniLens → ⋯ → Download Container → finder shows
/// `Documents/capture-*.wav`.
enum WaveWriter {

    enum WaveError: LocalizedError {
        case writeFailed(URL, Error)
        var errorDescription: String? {
            switch self {
            case .writeFailed(let u, let e):
                return "WAV write failed for \(u.lastPathComponent): \(e.localizedDescription)"
            }
        }
    }

    /// Write `samples` (16 kHz mono Float32 PCM in [-1.0, 1.0]) to `url` as
    /// a WAV file. Returns the absolute path written.
    @discardableResult
    static func writeFloat32MonoWav(
        samples: [Float],
        sampleRate: Int = 16_000,
        to url: URL
    ) throws -> URL {
        let bitsPerSample: UInt16 = 32
        let channels: UInt16 = 1
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
        let dataSize = UInt32(samples.count * Int(bitsPerSample / 8))
        let riffSize: UInt32 = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.appendLE(uint32: riffSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendLE(uint32: 16)              // fmt chunk size
        header.appendLE(uint16: 3)               // 3 = IEEE float
        header.appendLE(uint16: channels)
        header.appendLE(uint32: UInt32(sampleRate))
        header.appendLE(uint32: byteRate)
        header.appendLE(uint16: blockAlign)
        header.appendLE(uint16: bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.appendLE(uint32: dataSize)

        do {
            try header.write(to: url)
            // Append samples raw bytes
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            samples.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    let raw = UnsafeRawBufferPointer(
                        start: base,
                        count: ptr.count * MemoryLayout<Float>.size
                    )
                    handle.write(Data(raw))
                }
            }
            try handle.close()
            return url
        } catch {
            throw WaveError.writeFailed(url, error)
        }
    }

    /// Convenience: write into the app's Documents directory with a
    /// timestamped name (`capture-<unix-ms>.wav`). Returns the URL written.
    @discardableResult
    static func saveCaptureToDocuments(
        samples: [Float],
        sampleRate: Int = 16_000
    ) throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = docs.appendingPathComponent("capture-\(stamp).wav")
        return try writeFloat32MonoWav(samples: samples, sampleRate: sampleRate, to: url)
    }
}

private extension Data {
    mutating func appendLE(uint32 v: UInt32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { self.append(contentsOf: $0) }
    }
    mutating func appendLE(uint16 v: UInt16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { self.append(contentsOf: $0) }
    }
}
