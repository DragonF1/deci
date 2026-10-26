// FineTune/Audio/Keys/MediaKeyEventDecoder.swift
import Foundation

/// A transport key. The raw value is the name the extension's MEDIA_KEY command takes.
nonisolated enum PlaybackKey: String, Equatable, Sendable {
    case playPause
    case next
    case previous
}

/// Which event of a key press this is. Only `.down` is acted on; the repeats and the key-up of a handled press are
/// decoded too, so the monitor can swallow all of them and macOS sees none of the press.
nonisolated enum PlaybackKeyPhase: Equatable, Sendable {
    case down
    case autoRepeat
    case up
}

nonisolated enum MediaKeyEvent: Equatable {
    case volumeUp(isRepeat: Bool)
    case volumeDown(isRepeat: Bool)
    case muteToggle
    case playback(PlaybackKey, PlaybackKeyPhase)
}

protocol MediaKeyEventDecoding: Sendable {
    func decode(data1: Int) -> MediaKeyEvent?
}

/// Decodes `NSSystemDefined.data1` using `<IOKit/hidsystem/ev_keymap.h>`
/// constants: NX_KEYTYPE_SOUND_UP=0, SOUND_DOWN=1, MUTE=7, PLAY=16, NEXT=17, PREVIOUS=18, FAST=19, REWIND=20.
/// FAST and REWIND are the next and previous keys of keyboards that label them so. Unknown subtypes → nil.
struct IOKitMediaKeyDecoder: MediaKeyEventDecoding {
    func decode(data1: Int) -> MediaKeyEvent? {
        let keyType = Int32((data1 & 0xFFFF0000) >> 16)
        let keyFlags = Int32(data1 & 0xFFFF)
        let keyState = (keyFlags & 0xFF00) >> 8
        let isDown = keyState == 0x0A
        let isRepeat = (keyFlags & 0xFF) != 0

        if let key = Self.playbackKey(forKeyType: keyType) {
            switch keyState {
            case 0x0A: return .playback(key, isRepeat ? .autoRepeat : .down)
            case 0x0B: return .playback(key, .up)
            default: return nil
            }
        }

        guard isDown else { return nil }

        switch keyType {
        case 0: return .volumeUp(isRepeat: isRepeat)
        case 1: return .volumeDown(isRepeat: isRepeat)
        case 7: return isRepeat ? nil : .muteToggle
        default: return nil
        }
    }

    private static func playbackKey(forKeyType keyType: Int32) -> PlaybackKey? {
        switch keyType {
        case 16: .playPause
        case 17, 19: .next
        case 18, 20: .previous
        default: nil
        }
    }
}
