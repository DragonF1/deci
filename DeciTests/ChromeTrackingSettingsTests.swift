// DeciTests/ChromeTrackingSettingsTests.swift
// The two Chrome tracking switches in AppSettings: defaults, upgrade decoding, persistence
// and the SettingsManager hook that tells the Chrome bridge when they change.

import Foundation
import Testing
@testable import Deci

@Suite("AppSettings: Chrome tracking")
struct ChromeTrackingSettingsTests {

    @Test("Chrome tabs default to on, incognito tabs default to off")
    func defaultsAreTabsOnIncognitoOff() {
        let settings = AppSettings()
        #expect(settings.chromeTabsEnabled == true)
        #expect(settings.chromeIncognitoEnabled == false)
    }

    @Test("Decoding settings saved before the Chrome section uses the defaults")
    func missingKeysDecodeToDefaults() throws {
        let json = """
        {
          "launchAtLogin": false,
          "menuBarIconStyle": "Default",
          "defaultNewAppVolume": 1.0,
          "lockInputDevice": true,
          "showDeviceDisconnectAlerts": true
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.chromeTabsEnabled == true)
        #expect(decoded.chromeIncognitoEnabled == false)
    }

    @Test("Both switches round-trip through JSON when turned off")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.chromeTabsEnabled = false
        settings.chromeIncognitoEnabled = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.chromeTabsEnabled == false)
        #expect(decoded.chromeIncognitoEnabled == false)
    }

    @Test("The switches are independent in saved data")
    func switchesAreIndependent() throws {
        let json = #"{"chromeTabsEnabled": true, "chromeIncognitoEnabled": false}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.chromeTabsEnabled == true)
        #expect(decoded.chromeIncognitoEnabled == false)
    }
}

@Suite("SettingsManager: Chrome tracking hook")
@MainActor
struct ChromeTrackingHookTests {

    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }

    private final class Calls {
        var values: [(tabs: Bool, incognito: Bool)] = []
    }

    @Test("Changing a Chrome switch reports the new pair")
    func reportsChanges() {
        let manager = makeManager()
        let calls = Calls()
        manager.onChromeTrackingChange = { calls.values.append(($0, $1)) }

        manager.appSettings.chromeIncognitoEnabled = true
        manager.appSettings.chromeTabsEnabled = false

        #expect(calls.values.count == 2)
        #expect(calls.values[0] == (true, true))
        #expect(calls.values[1] == (false, true))
    }

    @Test("Changing an unrelated setting does not report")
    func ignoresUnrelatedChanges() {
        let manager = makeManager()
        let calls = Calls()
        manager.onChromeTrackingChange = { calls.values.append(($0, $1)) }

        manager.appSettings.showDeviceDisconnectAlerts = false
        manager.appSettings.chromeTabsEnabled = true

        #expect(calls.values.isEmpty)
    }

    @Test("Resetting all settings reports when the switches were off, and not when they were default")
    func reportsReset() {
        let manager = makeManager()
        let calls = Calls()

        manager.resetAllSettings()
        manager.onChromeTrackingChange = { calls.values.append(($0, $1)) }
        manager.resetAllSettings()
        #expect(calls.values.isEmpty)

        manager.appSettings.chromeTabsEnabled = false
        manager.appSettings.chromeIncognitoEnabled = true
        calls.values.removeAll()

        manager.resetAllSettings()

        #expect(calls.values.count == 1)
        #expect(calls.values[0] == (true, false))
        #expect(manager.appSettings.chromeTabsEnabled == true)
        #expect(manager.appSettings.chromeIncognitoEnabled == false)
    }
}
