import SwiftUI
import AppKit

/// A row displaying an individual Google Chrome tab with playback and volume controls.
struct ChromeTabRow: View {
    let tab: ChromeTab
    let now: Date
    
    @State private var dragOverrideValue: Double?

    private var chromeManager: ChromeExtensionManager {
        ChromeExtensionManager.shared
    }

    private var volumeValue: Double {
        dragOverrideValue ?? Double(tab.volume)
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { volumeValue },
            set: { newValue in
                dragOverrideValue = newValue
                chromeManager.setTabVolume(tabId: tab.id, volume: Float(newValue))
            }
        )
    }

    private var displayedPercentage: Int {
        Int((volumeValue * 100).rounded())
    }

    private var chromeIcon: some View {
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
        }
        return Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
    }

    private var displayedCurrentTime: Double {
        guard let lastSyncedAt = tab.lastSyncedAt else { return tab.currentTime }
        guard !tab.paused else { return tab.currentTime }
        let elapsed = max(0, now.timeIntervalSince(lastSyncedAt))
        return tab.currentTime + elapsed
    }

    private var songElapsed: Double {
        max(0, displayedCurrentTime - tab.songBaselineCurrentTime)
    }

    private var elapsedLabel: String {
        let elapsed = Int(songElapsed)
        return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: false) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                // Tab Favicon
                Group {
                    if let urlString = tab.favIconUrl, !urlString.isEmpty, let url = URL(string: urlString) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fit)
                            } else {
                                chromeIcon
                            }
                        }
                        .frame(width: 18, height: 18)
                    } else {
                        chromeIcon.frame(width: 18, height: 18)
                    }
                }
                .frame(width: 24, height: 24)

                // Title + Playback Info
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title.isEmpty ? "Chrome Tab" : tab.title)
                        .font(DesignTokens.Typography.rowName)
                        .lineLimit(1)
                        .help(tab.title)

                    HStack(spacing: 4) {
                        Button {
                            chromeManager.togglePlayback(tabId: tab.id)
                        } label: {
                            Image(systemName: tab.paused ? "play.fill" : "pause.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(tab.paused ? "Play" : "Pause")

                        Text(elapsedLabel)
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                    }
                }

                Spacer(minLength: DesignTokens.Spacing.xs)

                // Volume Controls
                HStack(spacing: DesignTokens.Spacing.sm) {
                    MuteButton(isMuted: tab.isMuted || tab.volume == 0, levelFraction: volumeValue) {
                        chromeManager.toggleMute(tabId: tab.id)
                    }

                    LiquidGlassSlider(
                        value: volumeBinding,
                        in: 0...1,
                        showUnityMarker: false,
                        onEditingChanged: { isEditing in
                            if !isEditing {
                                dragOverrideValue = nil
                            }
                        }
                    )
                    .frame(width: DesignTokens.Dimensions.sliderWidth)

                    Text("\(displayedPercentage)%")
                        .font(DesignTokens.Typography.percentage)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .frame(width: DesignTokens.Dimensions.percentageWidth, alignment: .trailing)
                }
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
        } expandedContent: {
            EmptyView()
        }
    }
}
