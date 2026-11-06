// DeciTests/Music/MusicDSPChainDeckTests.swift
// The hand-over between two decks: a standby item's tap prepares while the active item plays, and must never silence it
// or change the filters it uses. A standby renders gain-only (no shared state) until it claims the chain; armed just
// before its scheduled start it also renders through the shared filters next to the owner. No frame of an incoming item
// is ever silenced. Offline, on test buffers.

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

    @Test("a standby lease that does not claim leaves the active deck rendering, and keeps its frames (gain only)")
    func preparingTheStandbyDoesNotSilenceTheActiveDeck() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        chain.setTargetGain(0.5, snap: true)
        let active = lease(chain)
        let standby = lease(chain, claims: false)

        #expect(isAudible(render(active), 0.25), "the standby's prepare must not take the chain")
        #expect(isAudible(render(standby), 0.25), "an unclaimed standby's frames are kept, with the volume applied")
        #expect(isAudible(render(active), 0.25))
    }

    @Test("a standby at another sample rate never rebuilds the owner's processors, and the owner keeps them")
    func standbyAtAnotherRateLeavesTheOwnersProcessors() async {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let owner = MusicRenderLease(chain: chain, sampleRate: 48_000, maxFrames: 4_096, claims: true)
        let standby = MusicRenderLease(chain: chain, sampleRate: 44_100, maxFrames: 4_096, claims: false)
        standby.arm()
        // Let any rebuild queued on the main queue run.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(chain.processorSampleRate == 48_000, "a non-claiming lease never asks for a rebuild")
        _ = render(standby)
        _ = render(owner)
        #expect(chain.processorSampleRate == 48_000)
        #expect(owner.debugCounters.fullFrames > 0)
        #expect(chain.processorsReady(for: owner), "the owner keeps EQ, AutoEQ and loudness")

        standby.claim()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(chain.processorSampleRate == 44_100, "the rebuild is requested when the standby claims")
        #expect(chain.processorsReady(for: standby))
    }

    @Test("a standby never changes the processors while it renders: its frames are gain-only and not metered")
    func unclaimedStandbyRendersGainOnly() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let standby = lease(chain, claims: false)
        _ = render(standby, value: 0.7)
        #expect(standby.debugCounters.gainOnlyFrames == 256)
        #expect(standby.debugCounters.silencedFrames == 0)
        #expect(standby.debugCounters.fullFrames == 0)
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

    @Test("an owner that loses the render race while a standby is armed still plays: gain only, never silence")
    func contentionKeepsTheAudio() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        chain.setTargetGain(0.5, snap: true)
        let active = lease(chain)
        let standby = lease(chain, claims: false)
        standby.arm()
        var activeOut: [Float] = []
        var standbyOut: [Float] = []
        chain.holdingRenderLock {
            activeOut = render(active)
            standbyOut = render(standby)
        }
        #expect(isAudible(activeOut, 0.25), "the owner's frame is kept with the volume applied")
        #expect(isAudible(standbyOut, 0.25), "so is the standby's")
        #expect(active.debugCounters.silencedFrames == 0)
        #expect(active.debugCounters.gainOnlyFrames == 256)
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

    @Test("disarming puts the standby back to gain-only, and releasing the active deck does not make it the owner")
    func disarmAndRelease() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let active = lease(chain)
        let standby = lease(chain, claims: false)
        standby.arm()
        standby.disarm()
        _ = render(standby)
        #expect(standby.debugCounters.fullFrames == 0)

        active.release()
        _ = render(standby)
        #expect(standby.debugCounters.fullFrames == 0, "an unclaimed standby never renders through the chain by itself")
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
        #expect(abs(chain.consumePeak() - 0.8) < 1e-3)
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
        #expect(standby.debugCounters.fullFrames == 0, "an unarmed standby does not render through the chain")

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
        _ = render(standby)
        #expect(standby.debugCounters.fullFrames == 0)
        // An attach after a disarm does not arm either.
        let again = MusicTapDeck(role: .standby)
        again.arm()
        again.disarm()
        let late = lease(chain, claims: false)
        again.attach(late)
        _ = render(late)
        #expect(late.debugCounters.fullFrames == 0)
    }
}
