// DeciTests/ChromeAutoSwitchTests.swift
// The YouTube Music auto-Switch in Chrome pauses while Deci plays natively: the extension is told
// `setting && !nativeMusicPlaying`, the stored setting is never touched, and it is sent only when that value changes.

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

    @Test("a flip that leaves the effective value off sends nothing")
    func flipWithSettingOff() {
        let (manager, sent) = makeManager()
        manager.setYTMusicAutoSwitch(false)
        manager.flushMessages()
        #expect(sent.options == [false])
        sent.clear()

        manager.setNativeMusicPlaying(true)
        manager.flushMessages()
        manager.setNativeMusicPlaying(false)
        manager.flushMessages()
        #expect(sent.messages.isEmpty)
        #expect(manager.nativeMusicPlaying == false)
        #expect(manager.effectiveYTMusicAutoSwitch == false)
    }

    @Test("toggling the setting during native playback sends nothing but still stores it")
    func toggleDuringNative() {
        let (manager, sent) = makeManager()
        manager.setNativeMusicPlaying(true)
        manager.flushMessages()
        sent.clear()

        manager.setYTMusicAutoSwitch(true)
        manager.flushMessages()
        #expect(sent.messages.isEmpty)
        #expect(manager.ytMusicAutoSwitch)
        #expect(manager.effectiveYTMusicAutoSwitch == false)
    }

    @Test("changing the setting sends once per real change and the stored value follows every call")
    func settingSendsOnlyOnChange() {
        let (manager, sent) = makeManager()
        manager.setYTMusicAutoSwitch(true)
        manager.flushMessages()
        #expect(sent.messages.isEmpty)

        manager.setYTMusicAutoSwitch(false)
        manager.flushMessages()
        manager.setYTMusicAutoSwitch(false)
        manager.flushMessages()
        #expect(sent.options == [false])
        #expect(manager.ytMusicAutoSwitch == false)

        manager.setYTMusicAutoSwitch(true)
        manager.flushMessages()
        #expect(sent.options == [false, true])
        #expect(manager.ytMusicAutoSwitch)
    }

    @Test("pausing native playback with the setting on sends the restored value, with the setting off it sends nothing")
    func pauseRestoresOnlyWhenOn() {
        let (on, sentOn) = makeManager()
        on.setNativeMusicPlaying(true)
        on.setNativeMusicPlaying(false)
        on.flushMessages()
        #expect(sentOn.options == [true])

        let (off, sentOff) = makeManager()
        off.setYTMusicAutoSwitch(false)
        off.flushMessages()
        sentOff.clear()
        off.setNativeMusicPlaying(true)
        off.setNativeMusicPlaying(false)
        off.flushMessages()
        #expect(sentOff.messages.isEmpty)
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
