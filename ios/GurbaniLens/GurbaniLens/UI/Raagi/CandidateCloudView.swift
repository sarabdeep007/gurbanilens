import SwiftUI
import GurbaniLensCore

/// Brief #9.26 Fix 1: progressive-narrowing candidate cloud shown by
/// ``RaagiModeScreen`` when the streaming engine's DISCOVERING state
/// has processed ≥5 partials without a fast-lock. Rows represent
/// candidate shabads the accumulator is currently tracking; each row
/// previews the most-recently-matched pangti and taps to force-lock.
///
/// Layout follows Deep's brief:
///   • Header — "🎧 Listening… found N possible shabads" + "\(partials)
///     partials"
///   • Body   — up to 8 rows; each is Gurmukhi pangti + Ang label +
///              subtle divider, tap-to-open
///   • Footer — "Cancel Listening" pill → back Home
///
/// Rows fetch pangti text asynchronously via the injected
/// ``fetchPangtiText`` closure (wired to
/// `StreamingRaagiModeEngine.fetchPangtiText`). Text load races
/// harmlessly against subsequent cloud updates — the id() modifier on
/// each row ties the load task to that row's (shabadId, lineId) pair
/// so a stale row disappears when the pair changes.
struct CandidateCloudView: View {

    let rows: [SungModeAccumulatorStore.CandidateRow]
    let partialsSeen: Int
    let onForceLock: (String, String) -> Void
    let onCancel: () -> Void
    let fetchPangtiText: (String, String) async -> String?

    private static let saffron = Color(red: 1.0, green: 0.60, blue: 0.20)

    var body: some View {
        VStack(spacing: 12) {
            header
            if rows.isEmpty {
                // Defensive: brief says the accumulator should always
                // publish ≥ 1 row when the cloud is .visible, but a
                // transient race (start-of-session hair) could produce
                // empty. Show a placeholder so we never blank the
                // screen.
                emptyPlaceholder
            } else {
                candidateList
            }
            Spacer(minLength: 8)
            cancelButton
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("🎧 Listening… found \(rows.count) possible shabad\(rows.count == 1 ? "" : "s")")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.onBackground)
                .multilineTextAlignment(.center)
            Text("\(partialsSeen) partial\(partialsSeen == 1 ? "" : "s") observed — narrowing…")
                .font(.system(size: 12))
                .foregroundColor(Theme.onSurfaceVariant)
        }
        .padding(.bottom, 8)
    }

    private var candidateList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(rows, id: \.shabadId) { row in
                    CandidateRowView(
                        row: row,
                        onTap: { onForceLock(row.shabadId, row.matchedLineId) },
                        fetchPangtiText: fetchPangtiText
                    )
                    .id("\(row.shabadId)#\(row.matchedLineId)")
                    .transition(
                        .opacity.combined(with: .move(edge: .top))
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        .animation(.easeInOut(duration: 0.22), value: rows.map(\.shabadId))
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.onSurfaceVariant)
            Text("🎧 Listening…")
                .font(.system(size: 14))
                .foregroundColor(Theme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Text("Cancel Listening")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.onPrimary)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(
                    Capsule().fill(Theme.surface.opacity(0.8))
                )
                .overlay(
                    Capsule().stroke(Self.saffron.opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel Listening — return to home")
    }
}

/// A single candidate row inside the cloud. Renders the matched pangti
/// (14pt Noto Serif Gurmukhi) + Ang small-cap label; taps to force-
/// lock. Fetches the pangti text asynchronously from the injected
/// closure — while loading, shows "…" so the row height stays stable.
private struct CandidateRowView: View {

    let row: SungModeAccumulatorStore.CandidateRow
    let onTap: () -> Void
    let fetchPangtiText: (String, String) async -> String?

    @State private var pangtiText: String?

    private static let saffron = Color(red: 1.0, green: 0.60, blue: 0.20)
    private static let darkNavy = Color(red: 0.10, green: 0.11, blue: 0.18)

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pangtiText ?? "…")
                    .font(.notoSerifGurmukhi(14))
                    .foregroundColor(Theme.onSurface)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(angLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Self.saffron.opacity(0.9))
                        .kerning(0.5)
                    Text("•")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.onSurfaceVariant)
                    Text("TAP TO OPEN")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .kerning(0.8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Self.darkNavy.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Self.saffron.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .task(id: "\(row.shabadId)#\(row.matchedLineId)") {
            pangtiText = nil
            let text = await fetchPangtiText(row.shabadId, row.matchedLineId)
            if !Task.isCancelled { pangtiText = text }
        }
    }

    private var angLabel: String {
        row.ang > 0 ? "ANG \(row.ang)" : "ANG —"
    }
}

#if DEBUG
struct CandidateCloudView_Previews: PreviewProvider {
    static var previews: some View {
        let sampleRows: [SungModeAccumulatorStore.CandidateRow] = [
            .init(shabadId: "SHB1", ang: 917, matchedLineId: "L1", maxScoreSeen: 92, weight: 340, hits: 6),
            .init(shabadId: "SHB2", ang: 590, matchedLineId: "L2", maxScoreSeen: 78, weight: 210, hits: 4),
            .init(shabadId: "SHB3", ang: 450, matchedLineId: "L3", maxScoreSeen: 71, weight: 130, hits: 3),
        ]
        return ZStack {
            Color(red: 0.10, green: 0.11, blue: 0.18).ignoresSafeArea()
            CandidateCloudView(
                rows: sampleRows,
                partialsSeen: 8,
                onForceLock: { _, _ in },
                onCancel: {},
                fetchPangtiText: { _, _ in
                    "ਅਨੰਦੁ ਭਇਆ ਮੇਰੀ ਮਾਏ ਸਤਿਗੁਰੂ ਮੈ ਪਾਇਆ"
                }
            )
        }
        .preferredColorScheme(.dark)
    }
}
#endif
