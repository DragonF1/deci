// DeciTests/TapSourcePolicyTests.swift
//
// TapSourcePolicy picks a stereo mixdown tap for an app that plays only on the device it follows (a device-stream tap
// captures exact-zero holes there), and keeps the stream tap whenever a mixdown would capture different audio: the app
// also plays on another device, or the source has more than two output channels.

import Testing
@testable import Deci

@Suite("TapSourcePolicy")
struct TapSourcePolicyTests {
    private func kind(
        source: String? = "xm5",
        channels: UInt32? = 2,
        outputs: Set<String>? = ["xm5"]
    ) -> TapSourcePolicy.Kind {
        TapSourcePolicy.kind(sourceDeviceUID: source, sourceOutputChannels: channels, appOutputDeviceUIDs: outputs)
    }

    @Test("An app routed by Deci (no source device) always gets a mixdown")
    func noSourceIsMixdown() {
        #expect(kind(source: nil) == .mixdown)
        #expect(kind(source: nil, channels: 8, outputs: ["xm5", "speakers"]) == .mixdown)
        #expect(kind(source: nil, outputs: nil) == .mixdown)
    }

    @Test("An app playing only on its source device gets a mixdown")
    func sourceOnlyIsMixdown() {
        #expect(kind() == .mixdown)
    }

    @Test("An app not playing yet gets a mixdown")
    func notPlayingIsMixdown() {
        #expect(kind(outputs: []) == .mixdown)
    }

    @Test("An app also playing on another device keeps the stream tap (per-tab routing, Chrome Multi)")
    func otherDeviceIsStream() {
        #expect(kind(outputs: ["xm5", "speakers"]) == .stream)
        #expect(kind(outputs: ["speakers"]) == .stream)
    }

    @Test("A multichannel source keeps the stream tap, since a mixdown is stereo")
    func multichannelIsStream() {
        #expect(kind(channels: 6) == .stream)
        #expect(kind(channels: 3) == .stream)
        #expect(kind(channels: 1) == .mixdown)
    }

    @Test("An unread channel count counts as stereo")
    func unknownChannelsIsStereo() {
        #expect(kind(channels: nil) == .mixdown)
    }

    @Test("Unread app outputs keep the stream tap, the choice that never breaks routing")
    func unknownOutputsIsStream() {
        #expect(kind(outputs: nil) == .stream)
    }
}

@Suite("TapSourcePolicy: rebuild on device changes")
struct TapSourcePolicyRebuildTests {
    private func rebuild(
        running: TapSourcePolicy.Kind?,
        wanted: TapSourcePolicy.Kind,
        outputs: Set<String>? = ["xm5"]
    ) -> TapSourcePolicy.Rebuild {
        TapSourcePolicy.rebuild(running: running, wanted: wanted, appOutputDeviceUIDs: outputs)
    }

    @Test("No tap, nothing to rebuild")
    func noTap() {
        #expect(rebuild(running: nil, wanted: .stream, outputs: ["xm5", "speakers"]) == .none)
    }

    @Test("The running tap already fits")
    func fits() {
        #expect(rebuild(running: .mixdown, wanted: .mixdown) == .none)
        #expect(rebuild(running: .stream, wanted: .stream, outputs: ["xm5", "speakers"]) == .none)
    }

    @Test("A stream tap that fell back to a mixdown was built as stream, so it is not rebuilt again")
    func fallbackDoesNotLoop() {
        // The running kind is the pick the tap was built for, not what HAL handed back.
        #expect(rebuild(running: .stream, wanted: .stream, outputs: ["xm5", "speakers"]) == .none)
        #expect(rebuild(running: .stream, wanted: .stream, outputs: nil) == .none)
    }

    @Test("The app starts playing on another device: stream tap now")
    func toStreamNow() {
        #expect(rebuild(running: .mixdown, wanted: .stream, outputs: ["xm5", "speakers"]) == .now)
    }

    @Test("Unreadable outputs on a mixdown: stream tap now")
    func unreadableToStream() {
        #expect(rebuild(running: .mixdown, wanted: .stream, outputs: nil) == .now)
    }

    @Test("The app plays only on its source again: mixdown after the hold")
    func toMixdownAfterHold() {
        #expect(rebuild(running: .stream, wanted: .mixdown) == .afterHold)
    }

    @Test("An app playing nowhere keeps its tap")
    func idleKeeps() {
        #expect(rebuild(running: .stream, wanted: .mixdown, outputs: []) == .none)
    }
}

@Suite("ProcessTapController: drift for a source-only mixdown")
struct SourceMixdownDriftTests {
    @Test("A mixdown taken because the app plays only on the clock device shares its clock: OFF")
    func sourceMixdownOnClockIsOff() {
        let drift = ProcessTapController.tapNeedsDriftCompensation(
            tapDeviceUID: "speakers", clockDeviceUID: "speakers", clockIsBluetooth: false, tapSourceIsVirtual: false
        )
        #expect(drift == false)
    }

    @Test("A plain mixdown (routed app) can carry another clock: ON")
    func plainMixdownIsOn() {
        let drift = ProcessTapController.tapNeedsDriftCompensation(
            tapDeviceUID: nil, clockDeviceUID: "speakers", clockIsBluetooth: false, tapSourceIsVirtual: false
        )
        #expect(drift == true)
    }

    @Test("The decision log line marks a source-only mixdown with its device")
    func sourceMixdownLogLine() {
        let line = ProcessTapController.driftDecisionSummary(
            drift: false,
            tapDeviceUID: "speakers",
            tapIsMixdown: true,
            clockDeviceUID: "speakers",
            clockIsBluetooth: false,
            tapSourceIsVirtual: false
        )
        #expect(line == "drift=off src=mixdown:speakers clock=speakers clockBT=no virtualSource=no")
    }
}
