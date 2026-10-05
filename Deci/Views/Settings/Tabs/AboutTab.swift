// Deci/Views/Settings/Tabs/AboutTab.swift
import AppKit
import SwiftUI

@MainActor
struct AboutTab: View {
    private var versionShort: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var yearText: String {
        let currentYear = Calendar.current.component(.year, from: .now)
        return "\(currentYear)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)

                Text("Deci")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Version \(versionShort) (\(buildNumber))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            footer
                .padding(.top, 16)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("GPL-3.0")
            Text("·")
            Text("© \(yearText) Abraham")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
}
