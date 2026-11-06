// DeciTests/Music/MusicDSPChainDeckTests.swift
// The hand-over between two decks: a standby item's tap prepares while the active item plays, and must never silence it
// or change the filters it uses. Every lease has its own filter state, so a standby renders the whole chain next to the
// owner from the moment it exists; armed just before its scheduled start it is also metered. A superseded or released
// lease is silent. No frame of an incoming item is ever silenced. Offline, on test buffers.

import Foundation
import AudioToolbox
import Testing
@testable import Deci

@MainActor
@Suite("MusicDSPChain decks")
struct MusicDSPChainDeckTests {
    private static let rate = 48_000.0

    private func lease(_ chain: MusicDSPChain, claims: Bool = true) -> MusicRenderLease {
        MusicRenderLease(chain: chain, sampleRate: Self.rate, maxFrames: 4_096, claims: claims)
    }

    @discardableResult
    private func render(_ lease: MusicRenderLease, value: Float = 0.5, frames: Int = 256) -> [Float] {
        let buffers = TestBufferList(channels: MusicTestSignal.constant(value, frames: frames), layout: .interleaved)
        lease.render(buffers.list, frames: frames)
        return buffers.samples(channel: 0)
    }

    private func isSilent(_ samples: [Float]) -> Bool { samples.allSatisfy { $0 == 0 } }
    private func isAudible(_ samples: [Float], _ value: Float = 0.5) -> Bool { abs(samples[samples.count - 1] - value) < 1e-3 }

    @Test("a standby lease that does not claim leaves the active deck rendering, and keeps its frames")
    func preparingTheStandbyDoesNotSilenceTheActiveDeck() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        chain.setTargetGain(0.5, snap: true)
        let active = lease(chain)
        let standby = lease(chain, claims: false)

        #expect(isAudible(render(active), 0.25), "the standby's prepare must not take the chain")
        #expect(isAudible(render(standby), 0.25), "an unclaimed standby's frames are kept, with the volume applied")
        #expect(isAudible(render(active), 0.25))
    }

    @Test("a standby at another sample rate has its own processors, and claiming changes nobody's")
    func standbyAtAnotherRateKeepsItsOwnProcessors() {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setEQ(EQSettings(bandGains: [0, 0, 0, 0, 0, 12, 0, 0, 0, 0]))
        let owner = MusicRenderLease(chain: chain, sampleRate: 48_000, maxFrames: 4_096, claims: true)
        let standby = MusicRenderLease(chain: chain, sampleRate: 44_100, maxFrames: 4_096, claims: false)
        #expect(owner.processorSampleRate == 48_000)
        #expect(standby.processorSampleRate == 44_100)
        standby.arm()
        _ = render(standby)
        _ = render(owner)
        #expect(owner.debugCounters.fullFrames == 256)
        #expect(standby.debugCounters.fullFrames == 256, "the standby's primed frames get the whole chain")
        #expect(standby.debugCounters.gainOnlyFrames == 0)

        standby.claim()
        #expect(standby.processorSampleRate == 44_100, "nothing is rebuilt at the hand-over")
        _ = render(standby)
        #expect(standby.debugCounters.fullFrames == 512)
    }

    @Test("a standby renders the whole chain on its own state, and does not reach the meters until it is armed")
    func unclaimedStandbyRendersFullButIsNotMetered() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let standby = lease(chain, claims: false)
        _ = render(standby, value: 0.7)
        #expect(standby.debugCounters.fullFrames == 256)
        #expect(standby.debugCounters.gainOnlyFrames == 0)
        #expect(standby.debugCounters.silencedFrames == 0)
        #expect(chain.consumePeak() == 0)
    }

    @Test("a released lease is silent, and a lease that lost the chain to another claim is silent")
    func releasedAndSupersededAreSilent() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let old = lease(chain)
        let next = lease(chain, claims: false)
        next.claim()
        #expect(isSilent(render(old)))
        #expect(old.debugCounters.silencedFrames == 256)
        next.release()
        #expect(isSilent(render(next)))
    }

    @Test("an armed standby renders next to the active deck, so its first frames at the switch are kept")
    func armedStandbyRendersAlongside() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let active = lease(chain)
        let standby = lease(chain, claims: false)
        standby.arm()

        #expect(isAudible(render(active)), "arming leaves the active deck alone")
        #expect(isAudible(render(standby, value: 0.25), 0.25), "the armed standby is heard from its first frame")
    }

    @Test("claiming makes the standby the owner and silences the old deck, which is over by then")
    func claimHandsTheChainOver() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let old = lease(chain)
        let next = lease(chain, claims: false)
        next.arm()
        next.claim()

        #expect(isAudible(render(next)))
        #expect(isSilent(render(old)))
        old.release()
        #expect(isAudible(render(next)), "releasing the old lease takes nothing from the new owner")
    }

    @Test("disarming takes the standby out of the meters, and releasing the active deck does not silence it")
    func disarmAndRelease() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let active = lease(chain)
        let standby = lease(chain, claims: false)
        standby.arm()
        standby.disarm()
        _ = render(standby, value: 0.6)
        #expect(chain.consumePeak() == 0)

        active.release()
        #expect(isAudible(render(standby)), "an unclaimed standby keeps rendering after the owner is released")
        #expect(standby.debugCounters.silencedFrames == 0)
    }

    @Test("the meters see the active deck while a standby is prepared, and both once the standby is armed")
    func metersKeepWorking() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let active = lease(chain)
        let standby = lease(chain, claims: false)
        render(active, value: 0.4)
        render(standby, value: 0.9)
        #expect(abs(chain.consumePeak() - 0.4) < 1e-3, "an idle standby never reaches the meter")
        #expect(chain.consumeLevel() > 0.39)

        standby.arm()
        render(standby, value: 0.8)
        #expect(abs(chain.consumePeak() - 0.8) < 5e-3)
        #expect(chain.consumePeak() == 0, "reading resets it")
    }

    @Test("a deck handle claims at prepare when active, and waits for its turn when standby")
    func deckHandleRoles() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let activeDeck = MusicTapDeck(role: .active)
        let standbyDeck = MusicTapDeck(role: .standby)
        let active = lease(chain, claims: false)
        let standby = lease(chain, claims: false)
        activeDeck.attach(active)
        standbyDeck.attach(standby)

        #expect(isAudible(render(active)), "an active deck's lease claims as it is attached")
        #expect(standby.debugCounters.silencedFrames == 0)

        standbyDeck.arm()
        #expect(isAudible(render(standby)))
        standbyDeck.activate()
        activeDeck.retire()
        #expect(isAudible(render(standby)))
        #expect(isSilent(render(active)))
    }

    @Test("a standby deck that is activated before its tap has prepared claims the moment the lease arrives")
    func activateBeforePrepare() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let first = MusicTapDeck(role: .active)
        let firstLease = lease(chain, claims: false)
        first.attach(firstLease)

        let late = MusicTapDeck(role: .standby)
        late.activate()
        let lateLease = lease(chain, claims: false)
        late.attach(lateLease)
        #expect(isAudible(render(lateLease)))
        #expect(isSilent(render(firstLease)))
    }

    @Test("the owner and an armed standby rendering from two threads stay finite, with no race or crash")
    func ownerAndArmedStandbyStayFiniteUnderConcurrentRender() async {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let active = lease(chain)
        let standby = lease(chain, claims: false)
        standby.arm()
        let finite = await withTaskGroup(of: Bool.self) { group in
            for deck in [active, standby] {
                group.addTask {
                    var allFinite = true
                    for _ in 0..<200 {
                        let buffers = TestBufferList(
                            channels: MusicTestSignal.sine(frequency: 1_000, amplitude: 0.1, sampleRate: 48_000, frames: 512),
                            layout: .planar
                        )
                        deck.render(buffers.list, frames: buffers.frames)
                        allFinite = allFinite && buffers.samples(channel: 0).allSatisfy { $0.isFinite }
                    }
                    return allFinite
                }
            }
            var all = true
            for await ok in group { all = all && ok }
            return all
        }
        #expect(finite, "two eligible leases never race on the filters or corrupt the output")
    }

    @Test("a retired deck never arms or claims again, even when its tap prepares late")
    func retiredDeckStaysRetired() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let owner = lease(chain)
        let deck = MusicTapDeck(role: .standby)
        deck.retire()
        deck.activate()
        deck.arm()
        let late = lease(chain, claims: false)
        deck.attach(late)
        #expect(isAudible(render(owner)), "the late tap of a retired deck never takes the chain")
        #expect(isSilent(render(late)), "and it is silent, not gain-only")
        #expect(!chain.owns(late))
    }

    @Test("a disarm is never undone by an arm that was decided before it")
    func disarmWinsOverLateArm() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        _ = lease(chain)
        let deck = MusicTapDeck(role: .standby)
        let standby = lease(chain, claims: false)
        deck.attach(standby)
        deck.arm()
        deck.disarm()
        _ = render(standby, value: 0.9)
        #expect(chain.consumePeak() == 0, "disarmed means not metered")
        // An attach after a disarm does not arm either.
        let again = MusicTapDeck(role: .standby)
        again.arm()
        again.disarm()
        let late = lease(chain, claims: false)
        again.attach(late)
        _ = render(late, value: 0.9)
        #expect(chain.consumePeak() == 0)
    }
}
