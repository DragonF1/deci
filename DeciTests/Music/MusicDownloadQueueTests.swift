// DeciTests/Music/MusicDownloadQueueTests.swift
// The order downloads run in, with no disk, no network and no clock: collection listings first, then songs asked for on
// their own in the order asked, then collection songs in page order. A song waits in the queue once, however many
// collections list it. Plain values in, plain values out.

import Foundation
import Testing
@testable import Deci

@Suite("MusicDownloadQueue")
struct MusicDownloadQueueTests {
    private func track(_ number: Int) -> MusicTrack { DownloadSamples.track(DownloadSamples.id(number)) }

    /// Everything the queue would run, in order.
    private func drain(_ queue: inout MusicDownloadQueue) -> [String] {
        var order: [String] = []
        while let job = queue.next() {
            switch job {
            case .collection(let browseId): order.append("collection:\(browseId)")
            case .song(let track): order.append(track.videoId)
            }
        }
        return order
    }

    private func ids(_ numbers: [Int]) -> [String] { numbers.map(DownloadSamples.id) }

    @Test("an empty queue has nothing to run")
    func empty() {
        var queue = MusicDownloadQueue()

        #expect(queue.isEmpty)
        let next0 = queue.next()
        #expect(next0 == nil)
        #expect(queue.songCount == 0)
    }

    @Test("collection songs run in the order they were queued, which is page order")
    func listedInOrder() {
        var queue = MusicDownloadQueue()
        for number in [5, 1, 9, 3] {
            let queued = queue.enqueueListed(track(number))
            #expect(queued)
        }

        #expect(queue.songCount == 4)
        let order1 = drain(&queue)
        #expect(order1 == ids([5, 1, 9, 3]))
        #expect(queue.isEmpty)
    }

    @Test("a song asked for on its own runs ahead of every collection song waiting, and standalone songs keep their order")
    func standaloneJumpsAhead() {
        var queue = MusicDownloadQueue()
        for number in 1...4 { queue.enqueueListed(track(number)) }
        queue.enqueueStandalone(track(20))
        queue.enqueueStandalone(track(21))

        let order2 = drain(&queue)
        #expect(order2 == ids([20, 21, 1, 2, 3, 4]))
    }

    @Test("a standalone song asked for after the queue started still goes next")
    func standaloneAfterStart() {
        var queue = MusicDownloadQueue()
        for number in 1...4 { queue.enqueueListed(track(number)) }
        let next3 = queue.next()
        #expect(next3 == .song(track(1)))

        queue.enqueueStandalone(track(20))

        let order4 = drain(&queue)
        #expect(order4 == ids([20, 2, 3, 4]))
    }

    @Test("collection listings run before any song")
    func listingsFirst() {
        var queue = MusicDownloadQueue()
        queue.enqueueStandalone(track(1))
        queue.enqueueListed(track(2))
        queue.enqueueCollection("VLone")
        queue.enqueueCollection("VLtwo")

        let order5 = drain(&queue)
        #expect(order5 == ["collection:VLone", "collection:VLtwo"] + ids([1, 2]))
    }

    @Test("a collection is queued once")
    func collectionOnce() {
        var queue = MusicDownloadQueue()
        queue.enqueueCollection("VLone")
        queue.enqueueCollection("VLone")

        #expect(queue.hasCollection("VLone"))
        let order6 = drain(&queue)
        #expect(order6 == ["collection:VLone"])
        #expect(!queue.hasCollection("VLone"))
    }

    @Test("a song two collections list waits once, at the place of the first")
    func sharedSongOnce() {
        var queue = MusicDownloadQueue()
        let queued7 = queue.enqueueListed(track(1))
        #expect(queued7)
        let queued8 = queue.enqueueListed(track(2))
        #expect(queued8)
        let queued9 = queue.enqueueListed(track(2))
        #expect(!queued9)
        let queued10 = queue.enqueueListed(track(3))
        #expect(queued10)

        #expect(queue.songCount == 3)
        let order11 = drain(&queue)
        #expect(order11 == ids([1, 2, 3]))
    }

    @Test("asking for a queued collection song on its own moves it ahead of the collection songs, behind earlier standalone ones")
    func promote() {
        var queue = MusicDownloadQueue()
        for number in 1...4 { queue.enqueueListed(track(number)) }
        queue.enqueueStandalone(track(20))

        queue.enqueueStandalone(track(3))

        #expect(queue.isStandalone(DownloadSamples.id(3)))
        #expect(queue.songCount == 5)
        let order12 = drain(&queue)
        #expect(order12 == ids([20, 3, 1, 2, 4]))
    }

    @Test("asking again for a standalone song that is queued changes nothing")
    func standaloneTwice() {
        var queue = MusicDownloadQueue()
        queue.enqueueStandalone(track(1))
        queue.enqueueStandalone(track(2))
        queue.enqueueStandalone(track(1))

        let order13 = drain(&queue)
        #expect(order13 == ids([1, 2]))
    }

    @Test("a collection listing a song already queued on its own leaves it where it is")
    func listedAfterStandalone() {
        var queue = MusicDownloadQueue()
        queue.enqueueStandalone(track(1))

        let queued14 = queue.enqueueListed(track(1))
        #expect(!queued14)
        #expect(queue.isStandalone(DownloadSamples.id(1)))
        let order15 = drain(&queue)
        #expect(order15 == ids([1]))
    }

    @Test("demoting a queued standalone song returns it to its page position among the collection songs")
    func demote() {
        var queue = MusicDownloadQueue()
        for number in 1...4 { queue.enqueueListed(track(number)) }
        queue.enqueueStandalone(track(3))

        queue.demote(DownloadSamples.id(3))

        #expect(!queue.isStandalone(DownloadSamples.id(3)))
        let order16 = drain(&queue)
        #expect(order16 == ids([1, 2, 3, 4]))
    }

    @Test("demoting a song that is not queued, or not standalone, changes nothing")
    func demoteNothing() {
        var queue = MusicDownloadQueue()
        queue.enqueueListed(track(1))

        queue.demote(DownloadSamples.id(1))
        queue.demote(DownloadSamples.id(9))

        let order17 = drain(&queue)
        #expect(order17 == ids([1]))
    }

    @Test("removing a song takes it out wherever it waits, and asking again puts it at the end")
    func removeSong() {
        var queue = MusicDownloadQueue()
        for number in 1...4 { queue.enqueueListed(track(number)) }
        queue.enqueueStandalone(track(20))

        queue.removeSong(DownloadSamples.id(2))
        queue.removeSong(DownloadSamples.id(20))
        queue.removeSong(DownloadSamples.id(99))
        #expect(!queue.contains(DownloadSamples.id(2)))
        #expect(queue.songCount == 3)
        queue.enqueueListed(track(2))

        let order18 = drain(&queue)
        #expect(order18 == ids([1, 3, 4, 2]))
    }

    @Test("removing a collection takes its listing out and leaves the songs")
    func removeCollection() {
        var queue = MusicDownloadQueue()
        queue.enqueueCollection("VLone")
        queue.enqueueCollection("VLtwo")
        queue.enqueueListed(track(1))

        queue.removeCollection("VLone")

        let order19 = drain(&queue)
        #expect(order19 == ["collection:VLtwo"] + ids([1]))
    }

    @Test("contains says whether a song waits, and stops saying so once it has run")
    func contains() {
        var queue = MusicDownloadQueue()
        queue.enqueueListed(track(1))
        queue.enqueueListed(track(2))

        #expect(queue.contains(DownloadSamples.id(1)))
        let next20 = queue.next()
        #expect(next20 == .song(track(1)))
        #expect(!queue.contains(DownloadSamples.id(1)))
        #expect(queue.contains(DownloadSamples.id(2)))
        #expect(!queue.contains(DownloadSamples.id(3)))
    }

    @Test("ten thousand songs come out in order, and quickly")
    func largeQueue() {
        var queue = MusicDownloadQueue()
        for number in 1...10_000 { queue.enqueueListed(track(number)) }
        queue.enqueueStandalone(track(20_000))

        var order: [String] = []
        order.reserveCapacity(10_001)
        while case .song(let next)? = queue.next() { order.append(next.videoId) }

        #expect(order.count == 10_001)
        #expect(order.first == DownloadSamples.id(20_000))
        #expect(Array(order.dropFirst()) == (1...10_000).map(DownloadSamples.id))
        #expect(queue.isEmpty)
    }
}
