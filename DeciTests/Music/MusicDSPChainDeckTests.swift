// DeciTests/Music/MusicDSPChainDeckTests.swift
// The hand-over between two decks: a standby item's tap prepares while the active item plays, and must never silence it.
// The standby is armed just before its scheduled start (both render for the few milliseconds of the switch) and claims
// the chain once it is the active deck. Offline, on test buffers.

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

    @Test("a standby lease that does not claim leaves the active deck rendering, and is silent itself")
    func preparingTheStandbyDoesNotSilenceTheActiveDeck() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let active = lease(chain)
        let standby = lease(chain, claims: false)

        #expect(isAudible(render(active)), "the standby's prepare must not take the chain")
        #expect(isSilent(render(standby)), "a standby that is not armed makes no sound")
        #expect(isAudible(render(active)))
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

    @Test("disarming puts the standby back to silence, and releasing the active deck does not wake it")
    func disarmAndRelease() {
        let chain = MusicDSPChain(sampleRate: Self.rate)
        let active = lease(chain)
        let standby = lease(chain, claims: false)
        standby.arm()
        standby.disarm()
        #expect(isSilent(render(standby)))

        active.release()
        #expect(isSilent(render(standby)), "an unarmed standby stays silent when the owner leaves")
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
        #expect(isSilent(render(standby)))

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

    @Test("the active deck and an armed standby rendering from two threads stay finite and never crash")
    func armedAndActiveRenderConcurrently() async {
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
}
