import AppKit
import Foundation
import os

/// Installs what Chrome needs to talk to Deci: the native messaging host manifest, and a
/// copy of the bundled extension in a folder the user can "Load unpacked". Every outside
/// dependency is injected so tests run against a temp home folder and a fake app bundle.
struct ChromeExtensionInstaller {
    enum InstallError: LocalizedError, Equatable {
        /// `DeciHost` is not inside the app bundle (only the scripted builds ship it).
        case hostMissing
        /// The app has no bundled copy of the extension to install.
        case extensionNotBundled
        case chromeNotFound
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .hostMissing:
                return "Deci's Chrome helper is missing from this copy of the app. Reinstall Deci."
            case .extensionNotBundled:
                return "This copy of Deci doesn't include the Chrome extension. Reinstall Deci."
            case .chromeNotFound:
                return "Google Chrome not found."
            case .copyFailed(let reason):
                return "Couldn't copy the extension: \(reason)"
            }
        }
    }

    static let hostName = "com.abraham.deci"
    /// Fixed by the `key` in the extension manifest, so it is the same from any folder.
    static let extensionID = "dhnhdhfcagmpfdoocppooomgljoldhjf"
    static let chromeBundleID = "com.google.Chrome"
    static let bundledFolderName = "ChromeExtension"

    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "ChromeInstaller")

    let homeDirectory: URL
    /// The extension folder inside the app's Resources, nil when the bundle has none.
    let bundledExtensionURL: URL?
    let appBundleURL: URL
    let copyToPasteboard: (String) -> Void
    /// Where Google Chrome is installed, nil when it is not.
    let chromeAppURL: () -> URL?
    /// Opens a URL in the given app (Chrome).
    let openInChrome: (_ url: URL, _ chromeApp: URL) -> Void
    /// The system-wide Applications folder. A property so tests can point it at a temp folder.
    var systemApplicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// The real home folder, app bundle, clipboard and Chrome.
    static func live() -> ChromeExtensionInstaller {
        ChromeExtensionInstaller(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            bundledExtensionURL: Bundle.main.resourceURL?.appendingPathComponent(bundledFolderName, isDirectory: true),
            appBundleURL: Bundle.main.bundleURL,
            copyToPasteboard: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            },
            chromeAppURL: {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleID)
            },
            openInChrome: { url, chromeApp in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: chromeApp, configuration: configuration) { _, error in
                    if let error {
                        logger.error("Could not open Chrome: \(error.localizedDescription)")
                    }
                }
            }
        )
    }

    // MARK: - Locations

    var hostBinaryURL: URL {
        appBundleURL.appendingPathComponent("Contents/MacOS/DeciHost")
    }

    var hostManifestURL: URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(Self.hostName).json")
    }

    /// Where the extension is copied to; the folder the user picks in "Load unpacked".
    var installedExtensionURL: URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Deci", isDirectory: true)
            .appendingPathComponent(Self.bundledFolderName, isDirectory: true)
    }

    // MARK: - Where Deci runs from

    /// True when this copy of Deci sits in /Applications or ~/Applications, the only places
    /// worth pointing Chrome at. A mounted disk image or an AppTranslocation path goes away
    /// later and would break a working install.
    var runsFromApplicationsFolder: Bool {
        let homeApplications = homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        return [systemApplicationsURL, homeApplications].contains { Self.folder($0, contains: appBundleURL) }
    }

    /// Path-prefix check with a trailing slash, so "/ApplicationsOld/Deci.app" does not match.
    private static func folder(_ folder: URL, contains item: URL) -> Bool {
        let folderPath = folder.standardizedFileURL.path
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        return item.standardizedFileURL.path.hasPrefix(prefix)
    }

    // MARK: - Host manifest

    /// What Chrome reads to find DeciHost. Same content as scripts/install-chrome-host.sh.
    private func hostManifest() -> [String: Any] {
        [
            "name": Self.hostName,
            "description": "Deci Audio Control Host",
            "path": hostBinaryURL.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Self.extensionID)/"]
        ]
    }

    private func requireHostBinary() throws {
        guard FileManager.default.isExecutableFile(atPath: hostBinaryURL.path) else {
            throw InstallError.hostMissing
        }
    }

    /// Writes the native messaging host manifest, creating Chrome's folders if needed.
    func writeHostManifest() throws {
        try requireHostBinary()
        let data = try JSONSerialization.data(
            withJSONObject: hostManifest(),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: hostManifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: hostManifestURL, options: .atomic)
    }

    /// Writes the manifest only when it is missing or differs in content (formatting does
    /// not count). Returns whether it wrote.
    @discardableResult
    func ensureHostManifest() throws -> Bool {
        try requireHostBinary()
        if let data = try? Data(contentsOf: hostManifestURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           NSDictionary(dictionary: existing).isEqual(to: hostManifest()) {
            return false
        }
        try writeHostManifest()
        return true
    }

    /// The automatic path for launch and settings changes: same as `ensureHostManifest()`
    /// with a failure logged, but only for a Deci in /Applications or ~/Applications and
    /// only when Chrome is installed. Anything else is skipped quietly, so a copy run from
    /// a disk image never repoints a working install and no Chrome folders appear for
    /// people without Chrome. The Install button (`installExtension()`) is not limited.
    func ensureHostManifestLoggingErrors() {
        guard runsFromApplicationsFolder else {
            Self.logger.debug("Host manifest not touched: Deci is not running from an Applications folder")
            return
        }
        guard chromeAppURL() != nil else {
            Self.logger.debug("Host manifest not touched: Google Chrome is not installed")
            return
        }
        do {
            if try ensureHostManifest() {
                Self.logger.info("Wrote Chrome native messaging host manifest")
            }
        } catch {
            Self.logger.error("Chrome host manifest not written: \(error.localizedDescription)")
        }
    }

    // MARK: - Extension

    /// Copies the bundled extension to `installedExtensionURL` (replacing an older copy),
    /// writes the host manifest, puts the folder path on the clipboard and opens
    /// chrome://extensions in Chrome. Nothing is changed when a precondition fails.
    @discardableResult
    func installExtension() throws -> URL {
        guard let chromeApp = chromeAppURL() else { throw InstallError.chromeNotFound }
        try requireHostBinary()
        guard let source = bundledExtensionURL,
              FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw InstallError.extensionNotBundled
        }

        try copyExtension(from: source)
        try writeHostManifest()
        copyToPasteboard(installedExtensionURL.path)
        openInChrome(URL(string: "chrome://extensions")!, chromeApp)
        return installedExtensionURL
    }

    /// Deci's own page in chrome://extensions, where it can be pinned to the toolbar.
    static let extensionPageURL = URL(string: "chrome://extensions/?id=\(extensionID)")!

    /// Opens Deci's page in chrome://extensions. False, with nothing opened, when Chrome is not installed.
    @discardableResult
    func openExtensionPage() -> Bool {
        guard let chromeApp = chromeAppURL() else { return false }
        openInChrome(Self.extensionPageURL, chromeApp)
        return true
    }

    /// Copies into a staging folder first, then swaps it in, so a failed copy never leaves
    /// a half-written extension. Only Deci's own `ChromeExtension` folder is replaced.
    private func copyExtension(from source: URL) throws {
        let fm = FileManager.default
        let destination = installedExtensionURL
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".\(Self.bundledFolderName)-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: staging)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw InstallError.copyFailed(error.localizedDescription)
        }
    }
}
