// DeciTests/ChromeAutoSwitchTests.swift
// The YouTube Music auto-Switch in Chrome pauses while Deci plays natively: the extension is told
// `setting && !nativeMusicPlaying`, the stored setting is never touched, and a change is sent once.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("ChromeExtensionManager auto-Switch")
struct ChromeAutoSwitchTests {
    private final class SentLog {
        var messages: [[String: Any]] = []

        /// The ytmAutoSwitch value of every SET_OPTIONS sent so far.
        var options: [Bool] {
            messages.filter { $0["type"] as? String == "SET_OPTIONS" }.compactMap { $0["ytmAutoSwitch"] as? Bool }
        }
        var types: [String] { messages.compactMap { $0["type"] as? String } }
        func clear() { messages.removeAll() }
    }

    private func makeManager() -> (manager: ChromeExtensionManager, sent: SentLog) {
        let manager = ChromeExtensionManager(observeHost: false)
        let sent = SentLog()
        manager.messageSink = { sent.messages.append($0) }
        return (manager, sent)
    }

    @Test("the effective value is the setting and not native playback")
    func effectiveValue() {
        let (manager, _) = makeManager()
        #expect(manager.effectiveYTMusicAutoSwitch)

        manager.setNativeMusicPlaying(true)
        #expect(manager.effectiveYTMusicAutoSwitch == false)

        manager.setNativeMusicPlaying(false)
        manager.setYTMusicAutoSwitch(false)
        #expect(manager.effectiveYTMusicAutoSwitch == false)
        manager.setNativeMusicPlaying(true)
        #expect(manager.effectiveYTMusicAutoSwitch == false)
    }

    @Test("native playback tells the extension to stop switching, and its end restores the setting")
    func nativeFlipSendsOptions() {
        let (manager, sent) = makeManager()
        manager.setNativeMusicPlaying(true)
        manager.flushMessages()
        #expect(sent.options == [false])

        sent.clear()
        manager.setNativeMusicPlaying(false)
        manager.flushMessages()
        #expect(sent.options == [true])
    }

    @Test("the stored setting is never written by native playback")
    func settingUntouched() {
        let (manager, _) = makeManager()
        manager.setNativeMusicPlaying(true)
        #expect(manager.ytMusicAutoSwitch == true)
        manager.setYTMusicAutoSwitch(false)
        manager.setNativeMusicPlaying(false)
        #expect(manager.ytMusicAutoSwitch == false)
    }

    @Test("repeating the same native state sends nothing")
    func sendsOnlyOnChange() {
        let (manager, sent) = makeManager()
        manager.setNativeMusicPlaying(false)
        manager.flushMessages()
        #expect(sent.messages.isEmpty)

        manager.setNativeMusicPlaying(true)
        manager.flushMessages()
        sent.clear()
        manager.setNativeMusicPlaying(true)
        manager.flushMessages()
        #expect(sent.messages.isEmpty)
    }

    @Test("a flip is sent even when the effective value stays off because the user switched it off")
    func flipWithSettingOff() {
        let (manager, sent) = makeManager()
        manager.setYTMusicAutoSwitch(false)
        manager.flushMessages()
        sent.clear()

        manager.setNativeMusicPlaying(true)
        manager.flushMessages()
        manager.setNativeMusicPlaying(false)
        manager.flushMessages()
        #expect(sent.options == [false, false])
    }

    @Test("toggling the setting during native playback keeps sending off")
    func toggleDuringNative() {
        let (manager, sent) = makeManager()
        manager.setNativeMusicPlaying(true)
        manager.flushMessages()
        sent.clear()

        manager.setYTMusicAutoSwitch(true)
        manager.flushMessages()
        #expect(sent.options == [false])
        #expect(manager.ytMusicAutoSwitch)
    }

    @Test("every tab request carries the effective value")
    func requestTabsCarriesEffectiveValue() {
        let (manager, sent) = makeManager()
        manager.requestTabs()
        manager.flushMessages()
        #expect(sent.options == [true])

        sent.clear()
        manager.setNativeMusicPlaying(true)
        manager.flushMessages()
        sent.clear()
        manager.requestTabs()
        manager.flushMessages()
        #expect(sent.options == [false])
        #expect(sent.types.contains("GET_TABS"))
    }

    @Test("only the boolean crosses to Chrome")
    func onlyTheBoolean() {
        let (manager, sent) = makeManager()
        manager.setNativeMusicPlaying(true)
        manager.flushMessages()
        let keys = Set(sent.messages.flatMap { $0.keys })
        #expect(keys == ["type", "ytmAutoSwitch"])
    }
}
