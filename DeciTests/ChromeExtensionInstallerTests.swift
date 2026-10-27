// DeciTests/ChromeExtensionInstallerTests.swift
// The guided Chrome install: native messaging host manifest, extension copy, clipboard and
// "open Chrome". Everything runs against a temp home folder and a fake app bundle.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("ChromeExtensionInstaller")
struct ChromeExtensionInstallerTests {

    /// A throwaway home folder, fake Deci.app and fake bundled extension, plus what the
    /// installer did to the clipboard and to Chrome. The fake app sits in the fixture's own
    /// stand-in for /Applications unless `appPath` (relative to the fixture root) says otherwise.
    private final class Fixture {
        let root: URL
        let home: URL
        let systemApplications: URL
        let appBundle: URL
        let bundledExtension: URL
        let chromeApp = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        var chromeInstalled = true
        var copied: [String] = []
        var opened: [(url: URL, app: URL)] = []

        var hostBinary: URL { appBundle.appendingPathComponent("Contents/MacOS/DeciHost") }
        var manifestURL: URL {
            home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/com.abraham.deci.json")
        }
        var installedExtension: URL {
            home.appendingPathComponent("Library/Application Support/Deci/ChromeExtension")
        }

        init(hostBinary: Bool = true, bundledExtension: Bool = true, appPath: String = "Applications/Deci.app") throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("deci-installer-\(UUID().uuidString)")
            home = root.appendingPathComponent("home")
            systemApplications = root.appendingPathComponent("Applications", isDirectory: true)
            appBundle = root.appendingPathComponent(appPath)
            self.bundledExtension = root.appendingPathComponent("bundle/ChromeExtension")
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            try fm.createDirectory(
                at: appBundle.appendingPathComponent("Contents/MacOS"),
                withIntermediateDirectories: true
            )
            if hostBinary {
                try Data("#!/bin/sh\n".utf8).write(to: self.hostBinary)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.hostBinary.path)
            }
            if bundledExtension {
                let icons = self.bundledExtension.appendingPathComponent("icons")
                try fm.createDirectory(at: icons, withIntermediateDirectories: true)
                try Data(#"{"manifest_version":3}"#.utf8)
                    .write(to: self.bundledExtension.appendingPathComponent("manifest.json"))
                try Data("// background".utf8)
                    .write(to: self.bundledExtension.appendingPathComponent("background.js"))
                try Data([0x89, 0x50, 0x4E, 0x47])
                    .write(to: icons.appendingPathComponent("icon16.png"))
                try Data([0x89, 0x50, 0x4E, 0x47, 0x01])
                    .write(to: icons.appendingPathComponent("icon128.png"))
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        func makeInstaller() -> ChromeExtensionInstaller {
            ChromeExtensionInstaller(
                homeDirectory: home,
                bundledExtensionURL: bundledExtension,
                appBundleURL: appBundle,
                copyToPasteboard: { [self] in copied.append($0) },
                chromeAppURL: { [self] in chromeInstalled ? chromeApp : nil },
                openInChrome: { [self] url, app in opened.append((url, app)) },
                systemApplicationsURL: systemApplications
            )
        }

        /// Chrome's per-user folders, which Deci must not create on its own without Chrome.
        var chromeSupportFolder: URL {
            home.appendingPathComponent("Library/Application Support/Google")
        }

        func readManifest() throws -> [String: Any] {
            let data = try Data(contentsOf: manifestURL)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    // MARK: - host manifest

    @Test("writeHostManifest writes the native messaging manifest pointing at the bundled DeciHost")
    func writesManifest() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }

        try fx.makeInstaller().writeHostManifest()

        let json = try fx.readManifest()
        #expect(json["name"] as? String == "com.abraham.deci")
        #expect(json["description"] as? String == "Deci Audio Control Host")
        #expect(json["type"] as? String == "stdio")
        #expect(json["path"] as? String == fx.hostBinary.path)
        #expect(json["allowed_origins"] as? [String] == ["chrome-extension://dhnhdhfcagmpfdoocppooomgljoldhjf/"])
        #expect(json.count == 5)
    }

    @Test("writeHostManifest creates the missing Chrome folders and replaces an old manifest")
    func writesManifestOverOldOne() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }
        try FileManager.default.createDirectory(
            at: fx.manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: fx.manifestURL)

        try fx.makeInstaller().writeHostManifest()

        #expect(try fx.readManifest()["name"] as? String == "com.abraham.deci")
    }

    @Test("writeHostManifest names the missing DeciHost and writes nothing")
    func writeManifestWithoutHost() throws {
        let fx = try Fixture(hostBinary: false)
        defer { fx.cleanUp() }

        #expect(throws: ChromeExtensionInstaller.InstallError.hostMissing) {
            try fx.makeInstaller().writeHostManifest()
        }
        #expect(!FileManager.default.fileExists(atPath: fx.manifestURL.path))
    }

    @Test("ensureHostManifest writes a missing manifest")
    func ensureWritesWhenMissing() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }

        let wrote = try fx.makeInstaller().ensureHostManifest()

        #expect(wrote == true)
        #expect(try fx.readManifest()["path"] as? String == fx.hostBinary.path)
    }

    @Test("ensureHostManifest leaves an equivalent manifest alone, whatever its formatting")
    func ensureLeavesSameManifest() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }
        try FileManager.default.createDirectory(
            at: fx.manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // The shape scripts/install-chrome-host.sh writes, with its own whitespace.
        let handWritten = """
        {
          "name": "com.abraham.deci",
          "description": "Deci Audio Control Host",
          "path": "\(fx.hostBinary.path)",
          "type": "stdio",
          "allowed_origins": [
            "chrome-extension://dhnhdhfcagmpfdoocppooomgljoldhjf/"
          ]
        }
        """
        try Data(handWritten.utf8).write(to: fx.manifestURL)

        let wrote = try fx.makeInstaller().ensureHostManifest()

        #expect(wrote == false)
        #expect(try String(contentsOf: fx.manifestURL, encoding: .utf8) == handWritten)
    }

    @Test("ensureHostManifest rewrites a manifest that points somewhere else or is unreadable")
    func ensureRewritesWhenDifferent() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }
        let installer = fx.makeInstaller()
        try installer.writeHostManifest()

        // Points at another Deci.app.
        var json = try fx.readManifest()
        json["path"] = "/Somewhere/Else/DeciHost"
        try JSONSerialization.data(withJSONObject: json).write(to: fx.manifestURL)
        #expect(try installer.ensureHostManifest() == true)
        #expect(try fx.readManifest()["path"] as? String == fx.hostBinary.path)

        // Another extension ID is allowed.
        json = try fx.readManifest()
        json["allowed_origins"] = ["chrome-extension://other/"]
        try JSONSerialization.data(withJSONObject: json).write(to: fx.manifestURL)
        #expect(try installer.ensureHostManifest() == true)
        #expect(try fx.readManifest()["allowed_origins"] as? [String] == ["chrome-extension://dhnhdhfcagmpfdoocppooomgljoldhjf/"])

        // Garbage.
        try Data("not json".utf8).write(to: fx.manifestURL)
        #expect(try installer.ensureHostManifest() == true)
        #expect(try fx.readManifest()["name"] as? String == "com.abraham.deci")

        // And now it is right, so nothing more to do.
        #expect(try installer.ensureHostManifest() == false)
    }

    @Test("ensureHostManifest throws when DeciHost is not in the app and leaves an existing manifest alone")
    func ensureWithoutHost() throws {
        let fx = try Fixture(hostBinary: false)
        defer { fx.cleanUp() }
        try FileManager.default.createDirectory(
            at: fx.manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: fx.manifestURL)

        #expect(throws: ChromeExtensionInstaller.InstallError.hostMissing) {
            try fx.makeInstaller().ensureHostManifest()
        }
        #expect(try String(contentsOf: fx.manifestURL, encoding: .utf8) == "keep")
    }

    // MARK: - automatic ensure (launch and toggle)

    @Test("the automatic ensure writes the manifest when Deci runs from /Applications and Chrome is installed")
    func autoWritesFromApplications() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }

        fx.makeInstaller().ensureHostManifestLoggingErrors()

        #expect(try fx.readManifest()["path"] as? String == fx.hostBinary.path)
    }

    @Test("the automatic ensure writes the manifest when Deci runs from ~/Applications")
    func autoWritesFromHomeApplications() throws {
        let fx = try Fixture(appPath: "home/Applications/Deci.app")
        defer { fx.cleanUp() }

        fx.makeInstaller().ensureHostManifestLoggingErrors()

        #expect(try fx.readManifest()["path"] as? String == fx.hostBinary.path)
    }

    @Test("the automatic ensure skips a Deci running from a mounted disk image")
    func autoSkipsFromVolumes() throws {
        let fx = try Fixture(appPath: "Volumes/Deci 1.0/Deci.app")
        defer { fx.cleanUp() }

        fx.makeInstaller().ensureHostManifestLoggingErrors()

        #expect(!FileManager.default.fileExists(atPath: fx.manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: fx.chromeSupportFolder.path))
    }

    @Test("the automatic ensure skips a translocated Deci")
    func autoSkipsFromTranslocation() throws {
        let fx = try Fixture(appPath: "private/var/folders/ab/xyz/T/AppTranslocation/6A1F-77/d/Deci.app")
        defer { fx.cleanUp() }

        fx.makeInstaller().ensureHostManifestLoggingErrors()

        #expect(!FileManager.default.fileExists(atPath: fx.manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: fx.chromeSupportFolder.path))
    }

    @Test("the automatic ensure skips when Chrome is not installed and creates no Chrome folders")
    func autoSkipsWithoutChrome() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }
        fx.chromeInstalled = false

        fx.makeInstaller().ensureHostManifestLoggingErrors()

        #expect(!FileManager.default.fileExists(atPath: fx.manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: fx.chromeSupportFolder.path))
    }

    @Test("a skipped automatic ensure leaves a manifest from a working install alone")
    func autoSkipKeepsExistingManifest() throws {
        let fx = try Fixture(appPath: "Volumes/Deci 1.0/Deci.app")
        defer { fx.cleanUp() }
        try FileManager.default.createDirectory(
            at: fx.manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("from /Applications".utf8).write(to: fx.manifestURL)

        fx.makeInstaller().ensureHostManifestLoggingErrors()

        #expect(try String(contentsOf: fx.manifestURL, encoding: .utf8) == "from /Applications")
    }

    @Test("folders that only look like Applications do not count")
    func autoSkipsLookalikeFolders() throws {
        for appPath in [
            "ApplicationsOld/Deci.app",
            "Volumes/Backup/Applications/Deci.app",
            "home/Applications-Old/Deci.app",
        ] {
            let fx = try Fixture(appPath: appPath)
            defer { fx.cleanUp() }

            fx.makeInstaller().ensureHostManifestLoggingErrors()

            #expect(!FileManager.default.fileExists(atPath: fx.manifestURL.path), "\(appPath)")
        }
    }

    @Test("the Install button still writes the manifest from any location")
    func installFromVolumesStillWrites() throws {
        let fx = try Fixture(appPath: "Volumes/Deci 1.0/Deci.app")
        defer { fx.cleanUp() }

        _ = try fx.makeInstaller().installExtension()

        #expect(try fx.readManifest()["path"] as? String == fx.hostBinary.path)
    }

    @Test("the Applications check looks at the real /Applications and the given home folder")
    func applicationsFolderCheck() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }
        func installer(at path: String) -> ChromeExtensionInstaller {
            ChromeExtensionInstaller(
                homeDirectory: fx.home,
                bundledExtensionURL: nil,
                appBundleURL: URL(fileURLWithPath: path),
                copyToPasteboard: { _ in },
                chromeAppURL: { fx.chromeApp },
                openInChrome: { _, _ in }
            )
        }

        #expect(installer(at: "/Applications/Deci.app").runsFromApplicationsFolder)
        #expect(installer(at: "/Applications/Utilities/Deci.app").runsFromApplicationsFolder)
        #expect(installer(at: fx.home.appendingPathComponent("Applications/Deci.app").path).runsFromApplicationsFolder)
        #expect(!installer(at: "/Volumes/Deci/Deci.app").runsFromApplicationsFolder)
        #expect(!installer(at: "/private/var/folders/ab/T/AppTranslocation/6A1F/d/Deci.app").runsFromApplicationsFolder)
        #expect(!installer(at: "/Applications/../Volumes/Deci/Deci.app").runsFromApplicationsFolder)
        #expect(!installer(at: "/Users/someone/Applications/Deci.app").runsFromApplicationsFolder)
        #expect(!installer(at: "/Applications").runsFromApplicationsFolder)
    }

    // MARK: - installExtension

    @Test("installExtension copies the extension with its icons, writes the manifest, copies the path and opens Chrome")
    func installHappyPath() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }

        let destination = try fx.makeInstaller().installExtension()

        #expect(destination.path == fx.installedExtension.path)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: fx.installedExtension.appendingPathComponent("manifest.json").path))
        #expect(fm.fileExists(atPath: fx.installedExtension.appendingPathComponent("background.js").path))
        let icon = fx.installedExtension.appendingPathComponent("icons/icon128.png")
        #expect(try Data(contentsOf: icon) == Data([0x89, 0x50, 0x4E, 0x47, 0x01]))
        #expect(fm.fileExists(atPath: fx.installedExtension.appendingPathComponent("icons/icon16.png").path))

        #expect(try fx.readManifest()["path"] as? String == fx.hostBinary.path)
        #expect(fx.copied == [fx.installedExtension.path])
        #expect(fx.opened.count == 1)
        #expect(fx.opened[0].url.absoluteString == "chrome://extensions")
        #expect(fx.opened[0].app == fx.chromeApp)
    }

    @Test("installExtension replaces an older copy and touches nothing else of Deci's")
    func installReplacesOldCopy() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }
        let fm = FileManager.default
        try fm.createDirectory(
            at: fx.installedExtension.appendingPathComponent("icons"), withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: fx.installedExtension.appendingPathComponent("removed-in-new-version.js"))
        try Data("old".utf8).write(to: fx.installedExtension.appendingPathComponent("background.js"))
        let settings = fx.installedExtension.deletingLastPathComponent().appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: settings)

        _ = try fx.makeInstaller().installExtension()

        #expect(!fm.fileExists(atPath: fx.installedExtension.appendingPathComponent("removed-in-new-version.js").path))
        #expect(try String(contentsOf: fx.installedExtension.appendingPathComponent("background.js"), encoding: .utf8) == "// background")
        #expect(try String(contentsOf: settings, encoding: .utf8) == "{}")
        // No staging leftovers next to the installed copy.
        let siblings = try fm.contentsOfDirectory(atPath: fx.installedExtension.deletingLastPathComponent().path)
        #expect(siblings.sorted() == ["ChromeExtension", "settings.json"])
    }

    @Test("installing twice in a row works")
    func installTwice() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }
        let installer = fx.makeInstaller()

        _ = try installer.installExtension()
        _ = try installer.installExtension()

        #expect(FileManager.default.fileExists(atPath: fx.installedExtension.appendingPathComponent("manifest.json").path))
        #expect(fx.opened.count == 2)
    }

    @Test("installExtension reports Chrome as missing before changing anything")
    func installWithoutChrome() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }
        fx.chromeInstalled = false

        #expect(throws: ChromeExtensionInstaller.InstallError.chromeNotFound) {
            try fx.makeInstaller().installExtension()
        }

        #expect(!FileManager.default.fileExists(atPath: fx.installedExtension.path))
        #expect(!FileManager.default.fileExists(atPath: fx.manifestURL.path))
        #expect(fx.copied.isEmpty)
        #expect(fx.opened.isEmpty)
    }

    @Test("installExtension reports a missing DeciHost before changing anything")
    func installWithoutHost() throws {
        let fx = try Fixture(hostBinary: false)
        defer { fx.cleanUp() }

        #expect(throws: ChromeExtensionInstaller.InstallError.hostMissing) {
            try fx.makeInstaller().installExtension()
        }

        #expect(!FileManager.default.fileExists(atPath: fx.installedExtension.path))
        #expect(fx.copied.isEmpty)
        #expect(fx.opened.isEmpty)
    }

    @Test("installExtension reports an app without the bundled extension and keeps the installed copy")
    func installWithoutBundledExtension() throws {
        let fx = try Fixture(bundledExtension: false)
        defer { fx.cleanUp() }
        let fm = FileManager.default
        try fm.createDirectory(at: fx.installedExtension, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: fx.installedExtension.appendingPathComponent("manifest.json"))

        #expect(throws: ChromeExtensionInstaller.InstallError.extensionNotBundled) {
            try fx.makeInstaller().installExtension()
        }

        #expect(try String(contentsOf: fx.installedExtension.appendingPathComponent("manifest.json"), encoding: .utf8) == "keep")
        #expect(fx.copied.isEmpty)
        #expect(fx.opened.isEmpty)

        // A nil resource URL (no Resources folder at all) is the same problem.
        let installer = ChromeExtensionInstaller(
            homeDirectory: fx.home,
            bundledExtensionURL: nil,
            appBundleURL: fx.appBundle,
            copyToPasteboard: { _ in },
            chromeAppURL: { fx.chromeApp },
            openInChrome: { _, _ in }
        )
        #expect(throws: ChromeExtensionInstaller.InstallError.extensionNotBundled) {
            try installer.installExtension()
        }
    }

    // MARK: - messages

    @Test("every error reads as a short plain sentence")
    func errorMessages() {
        let all: [ChromeExtensionInstaller.InstallError] = [
            .hostMissing, .extensionNotBundled, .chromeNotFound, .copyFailed("disk full"),
        ]
        for error in all {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty)
            #expect(!text.contains("\u{2014}"))
        }
        #expect(ChromeExtensionInstaller.InstallError.chromeNotFound.errorDescription == "Google Chrome not found.")
    }

    // MARK: - extension page

    @Test("openExtensionPage opens Deci's page in chrome://extensions in Chrome")
    func openExtensionPage() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }

        #expect(fx.makeInstaller().openExtensionPage())

        #expect(fx.opened.count == 1)
        #expect(fx.opened[0].url.absoluteString == "chrome://extensions/?id=dhnhdhfcagmpfdoocppooomgljoldhjf")
        #expect(fx.opened[0].app == fx.chromeApp)
        #expect(fx.copied.isEmpty)
    }

    @Test("openExtensionPage opens nothing without Chrome")
    func openExtensionPageWithoutChrome() throws {
        let fx = try Fixture()
        defer { fx.cleanUp() }
        fx.chromeInstalled = false

        #expect(!fx.makeInstaller().openExtensionPage())
        #expect(fx.opened.isEmpty)
    }

    // MARK: - live wiring

    @Test("the live installer points at the real home folder and bundle")
    func liveWiring() {
        let installer = ChromeExtensionInstaller.live()
        #expect(installer.homeDirectory.path == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(installer.appBundleURL.path == Bundle.main.bundleURL.path)
        #expect(installer.bundledExtensionURL?.lastPathComponent == "ChromeExtension")
        #expect(installer.systemApplicationsURL.path == "/Applications")
    }
}
