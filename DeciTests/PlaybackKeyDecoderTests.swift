// DeciTests/PlaybackKeyDecoderTests.swift
// The play/pause, next and previous keys as the HID decoder sees them. <IOKit/hidsystem/ev_keymap.h> numbers them
// PLAY=16, NEXT=17, PREVIOUS=18, FAST=19, REWIND=20; the keyboard's F7, F8 and F9 send the first three, and a keyboard
// that labels them fast-forward and rewind sends the last two. Unlike the volume keys they are decoded on key-up and
// on auto-repeat too, so the monitor can swallow every event of a press it handled.
//
// data1 layout: keyType << 16 | state << 8 | repeat, with state 0x0A for down and 0x0B for up.

import Testing
@testable import Deci

/// The key types that mean a playback key, and the key each one is.
private nonisolated let playbackKeyCases: [(keyType: Int, key: PlaybackKey)] = [
    (16, .playPause), (17, .next), (18, .previous), (19, .next), (20, .previous),
]

@Suite("IOKitMediaKeyDecoder: playback keys")
struct PlaybackKeyDecoderTests {
    private let decoder = IOKitMediaKeyDecoder()

    private func data1(keyType: Int, state: Int, isRepeat: Bool = false) -> Int {
        (keyType << 16) | (state << 8) | (isRepeat ? 1 : 0)
    }

    @Test("A key-down decodes to the key and the down phase", arguments: playbackKeyCases)
    func keyDown(keyType: Int, key: PlaybackKey) {
        #expect(decoder.decode(data1: data1(keyType: keyType, state: 0x0A)) == .playback(key, .down))
    }

    @Test("An auto-repeat decodes to the key and the repeat phase", arguments: playbackKeyCases)
    func keyRepeat(keyType: Int, key: PlaybackKey) {
        #expect(decoder.decode(data1: data1(keyType: keyType, state: 0x0A, isRepeat: true)) == .playback(key, .autoRepeat))
    }

    @Test("A key-up decodes to the key and the up phase", arguments: playbackKeyCases)
    func keyUp(keyType: Int, key: PlaybackKey) {
        #expect(decoder.decode(data1: data1(keyType: keyType, state: 0x0B)) == .playback(key, .up))
    }

    @Test("A key-up that carries the repeat bit is still an up", arguments: playbackKeyCases)
    func keyUpWithRepeatBit(keyType: Int, key: PlaybackKey) {
        #expect(decoder.decode(data1: data1(keyType: keyType, state: 0x0B, isRepeat: true)) == .playback(key, .up))
    }

    @Test("A state that is neither down nor up decodes to nil, so the key passes through", arguments: playbackKeyCases)
    func unknownState(keyType: Int, key: PlaybackKey) {
        #expect(decoder.decode(data1: data1(keyType: keyType, state: 0x0C)) == nil)
        #expect(decoder.decode(data1: data1(keyType: keyType, state: 0x00)) == nil)
    }

    @Test("The key types next to the playback keys decode to nil")
    func neighbours() {
        // 2 and 3 are brightness, 8 is the up arrow, 15 is the video mirror key, 21 to 23 are keyboard illumination.
        for keyType in [2, 3, 8, 15, 21, 22, 23, 255] {
            #expect(decoder.decode(data1: data1(keyType: keyType, state: 0x0A)) == nil)
            #expect(decoder.decode(data1: data1(keyType: keyType, state: 0x0B)) == nil)
        }
    }

    @Test("The wire name of each key is what the extension's MEDIA_KEY command expects")
    func wireNames() {
        #expect(PlaybackKey.playPause.rawValue == "playPause")
        #expect(PlaybackKey.next.rawValue == "next")
        #expect(PlaybackKey.previous.rawValue == "previous")
    }

    // MARK: - Volume and mute are untouched

    @Test("Volume up, volume down and mute decode exactly as before")
    func volumeAndMuteUnchanged() {
        #expect(decoder.decode(data1: data1(keyType: 0, state: 0x0A)) == .volumeUp(isRepeat: false))
        #expect(decoder.decode(data1: data1(keyType: 0, state: 0x0A, isRepeat: true)) == .volumeUp(isRepeat: true))
        #expect(decoder.decode(data1: data1(keyType: 0, state: 0x0B)) == nil)
        #expect(decoder.decode(data1: data1(keyType: 1, state: 0x0A)) == .volumeDown(isRepeat: false))
        #expect(decoder.decode(data1: data1(keyType: 1, state: 0x0A, isRepeat: true)) == .volumeDown(isRepeat: true))
        #expect(decoder.decode(data1: data1(keyType: 1, state: 0x0B)) == nil)
        #expect(decoder.decode(data1: data1(keyType: 7, state: 0x0A)) == .muteToggle)
        #expect(decoder.decode(data1: data1(keyType: 7, state: 0x0A, isRepeat: true)) == nil)
        #expect(decoder.decode(data1: data1(keyType: 7, state: 0x0B)) == nil)
    }
}
