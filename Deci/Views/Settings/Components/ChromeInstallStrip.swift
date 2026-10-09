import SwiftUI
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "ChromeInstallStrip")

/// Inline strip shown in the Chrome section while the extension is not answering.
/// Same look as `AccessibilityPromptStrip`. "Install Extension" copies the bundled
/// extension to a folder, opens chrome://extensions and then walks through the three
/// steps Chrome needs for an unpacked extension.
///
/// While visible it re-asks Chrome every few seconds, so the strip goes away by itself
/// (the parent hides it once the connection is up) when the extension gets loaded.
@MainActor
struct ChromeInstallStrip: View {
    let chrome: ChromeExtensionManager
    let makeInstaller: () -> ChromeExtensionInstaller

    @State private var installedPath: String?
    @State private var errorMessage: String?
    @State private var isChecking = false

    /// `installedPath` and `errorMessage` set the starting state; previews use them.
    init(
        chrome: ChromeExtensionManager,
        makeInstaller: @escaping () -> ChromeExtensionInstaller = { ChromeExtensionInstaller.live() },
        installedPath: String? = nil,
        errorMessage: String? = nil
    ) {
        self.chrome = chrome
        self.makeInstaller = makeInstaller
        _installedPath = State(initialValue: installedPath)
        _errorMessage = State(initialValue: errorMessage)
    }

    /// How long "Check Again" waits for an answer, a little over the connection timeout.
    private static let checkDuration: Duration = .milliseconds(2700)
    private static let pollInterval: Duration = .seconds(3)

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DesignTokens.Colors.accentPrimary)
                    .frame(width: 28, alignment: .center)

                Text("Deci's Chrome extension isn't connected.")
                    .font(DesignTokens.Typography.rowDescription)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: DesignTokens.Spacing.xs)

                Button(action: checkAgain) {
                    Text(isChecking ? "Checking..." : "Check Again")
                        .font(DesignTokens.Typography.pickerText)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(isChecking)
                .accessibilityHint("Asks Chrome again whether the Deci extension is running.")

                Button(action: install) {
                    Text(installedPath == nil ? "Install Extension" : "Install Again")
                        .font(DesignTokens.Typography.pickerText)
                        .foregroundStyle(DesignTokens.Colors.accentPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Copies the extension to a folder and opens Chrome's extensions page.")
            }

            if let installedPath {
                steps(path: installedPath)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(DesignTokens.Typography.rowDescription)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28 + DesignTokens.Spacing.sm)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            // Re-asks while the strip is on screen. Asking again never delays the verdict.
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                chrome.requestTabs()
            }
        }
        .onChange(of: chrome.connectionState) { _, state in
            if state == .connected {
                installedPath = nil
                errorMessage = nil
            }
        }
    }

    @ViewBuilder
    private func steps(path: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("1. Turn on Developer mode (top right).")
            Text("2. Click Load unpacked.")
            Text("3. Press Cmd+Shift+G, paste the copied path, press Return, then click Select.")

            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy Path") { makeInstaller().copyToPasteboard(path) }
                    .buttonStyle(.plain)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .padding(.top, DesignTokens.Spacing.xxs)
        }
        .font(DesignTokens.Typography.rowDescription)
        .foregroundStyle(DesignTokens.Colors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 28 + DesignTokens.Spacing.sm)
    }

    private func install() {
        do {
            let folder = try makeInstaller().installExtension()
            installedPath = folder.path
            errorMessage = nil
        } catch {
            logger.error("Extension install failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func checkAgain() {
        isChecking = true
        chrome.requestTabs()
        Task { @MainActor in
            try? await Task.sleep(for: Self.checkDuration)
            isChecking = false
        }
    }
}

// MARK: - Previews

#Preview("Not connected") {
    PreviewContainer {
        ChromeInstallStrip(chrome: ChromeExtensionManager(observeHost: false))
            .frame(width: 560)
            .padding()
    }
}

#Preview("Install steps") {
    PreviewContainer {
        ChromeInstallStrip(
            chrome: ChromeExtensionManager(observeHost: false),
            installedPath: "/Users/you/Library/Application Support/Deci/ChromeExtension"
        )
        .frame(width: 560)
        .padding()
    }
}

#Preview("Chrome not found") {
    PreviewContainer {
        ChromeInstallStrip(
            chrome: ChromeExtensionManager(observeHost: false),
            errorMessage: "Google Chrome not found."
        )
        .frame(width: 560)
        .padding()
    }
}
