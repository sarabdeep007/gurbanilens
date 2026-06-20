import SwiftUI

/// v1 Home — single CTA: "Search by voice." Mirrors
/// `android/.../ui/home/HomeScreen.kt`.
struct HomeScreen: View {
    let onSearchTap: () -> Void
    let onSettingsTap: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer().frame(height: 8)
                Text("Bring the Bani into focus.")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(Theme.onBackground)
                    .multilineTextAlignment(.center)
                Text("Tap and recite a Pangti. We'll find the Shabad.")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                Spacer().frame(height: 32)
                Button(action: onSearchTap) {
                    ZStack {
                        Circle().fill(Theme.primary)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 64, weight: .medium))
                            .foregroundColor(Theme.onPrimary)
                    }
                    .frame(width: 160, height: 160)
                    .shadow(color: Theme.primary.opacity(0.4), radius: 24, y: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search by voice")
                Text("Search by voice")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Theme.onBackground)
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themed()
            .navigationTitle("GurbaniLens")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: onSettingsTap) {
                        Image(systemName: "gearshape").foregroundColor(Theme.onBackground)
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
    }
}
