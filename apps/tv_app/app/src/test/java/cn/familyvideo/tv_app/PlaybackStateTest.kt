package cn.familyvideo.tv_app

import org.junit.Assert.*
import org.junit.Test

class PlaybackStateTest {
    private val a = Video("a", "A", "http://server/a")
    private val b = Video("b", "B", "http://server/b")
    private val c = Video("c", "C", "http://server/c")

    @Test fun remoteSwitchingWrapsAndUsesCollectionOrder() {
        val queue = PlaybackQueue()
        queue.catalog = Catalog(listOf(a, b, c), listOf(Channel("songs", "儿歌", listOf(c, a))))
        assertEquals(a, queue.next(0))
        assertEquals(c, queue.next(-1))
        assertEquals(a, queue.next(1))
        queue.channelId = "songs"
        assertEquals(c, queue.next(1))
        assertEquals(a, queue.next(1))
    }

    @Test fun allBrokenVideosStopInsteadOfLooping() {
        val queue = PlaybackQueue()
        queue.catalog = Catalog(listOf(a, b), emptyList())
        queue.failed += "a"
        assertEquals(b, queue.next(1))
        queue.failed += "b"
        assertNull(queue.next(1))
    }

    @Test fun skippingFailedCurrentKeepsForwardOrder() {
        val queue = PlaybackQueue()
        queue.catalog = Catalog(listOf(a, b, c), emptyList())
        queue.currentId = "b"
        queue.failed += "b"
        assertEquals(c, queue.next(1))
        queue.currentId = "b"
        assertEquals(a, queue.next(-1))
    }

    @Test fun pausedBufferingAndSeekingTimeAreExcluded() {
        val ledger = WatchLedger()
        ledger.start("a", 1000)
        ledger.sample(1000, 0, true)
        assertEquals(1000L, ledger.sample(2000, 1000, true))
        assertEquals(0L, ledger.sample(3000, 1000, false)) // buffering
        assertEquals(0L, ledger.sample(4000, 1000, true))
        assertEquals(0L, ledger.sample(5000, 60000, true)) // seek
        assertEquals(1000L, ledger.sample(6000, 61000, false))
        assertEquals(0L, ledger.sample(7000, 61000, false))
        ledger.seal()
        assertEquals(2000L, ledger.batch().sumOf { it.watchedMs })
        assertEquals(1, ledger.batch().count { it.played })
    }

    @Test fun retriesRetainEventIdsAndAcknowledgementCannotDeleteNewEvents() {
        val ledger = WatchLedger()
        ledger.start("a", 0)
        ledger.sample(0, 0, true)
        ledger.sample(1000, 1000, true)
        ledger.seal()
        val sent = ledger.batch()
        assertEquals(sent, ledger.batch())
        ledger.sample(2000, 2000, true)
        ledger.seal(completed = true)
        ledger.acknowledge(sent.map { it.id }.toSet())
        assertEquals(1, ledger.batch().size)
        assertFalse(ledger.batch().single().played)
        assertTrue(ledger.batch().single().completed)
    }

    @Test fun switchingAttributesTimeToPreviousVideo() {
        val ledger = WatchLedger()
        ledger.start("a", 0)
        ledger.sample(0, 0, true)
        ledger.sample(1000, 1000, true)
        ledger.start("b", 1000)
        ledger.sample(1000, 0, true)
        ledger.sample(2000, 1000, true)
        ledger.seal()
        assertEquals(listOf("a", "b"), ledger.batch().map { it.videoId })
        assertEquals(listOf(1000L, 1000L), ledger.batch().map { it.watchedMs })
    }

    @Test fun reconnectingSameSessionDoesNotCountAnotherPlay() {
        val ledger = WatchLedger()
        ledger.start("a", 0)
        ledger.sample(0, 0, true)
        ledger.sample(1000, 1000, true)
        ledger.seal()
        ledger.rebase(10000, 1000)
        ledger.sample(10000, 1000, true)
        ledger.sample(11000, 2000, true)
        ledger.seal()
        assertEquals(2000L, ledger.batch().sumOf { it.watchedMs })
        assertEquals(1, ledger.batch().count { it.played })
    }

    @Test fun outageQueueIsBoundedAndIgnoresLongSuspendedIntervals() {
        val ledger = WatchLedger()
        ledger.start("a", 0)
        ledger.sample(0, 0, true)
        assertEquals(0L, ledger.sample(10000, 10000, true))
        for (index in 11..610) {
            ledger.sample(index * 1000L, index * 1000L, true)
            ledger.seal()
        }
        var count = 0
        while (ledger.batch().isNotEmpty()) {
            val events = ledger.batch()
            count += events.size
            ledger.acknowledge(events.map { it.id }.toSet())
        }
        assertEquals(512, count)
    }

    @Test fun completedVideosAreHiddenFromAllVideosButKeptInCuratedChannels() {
        val done = Video("b", "B", "http://server/b", completed = true)
        val queue = PlaybackQueue()
        queue.applyCatalog(Catalog(listOf(a, done, c), listOf(Channel("ch", "合集", listOf(done, a)))))
        assertEquals(setOf("a", "c"), queue.items().map { it.id }.toSet())
        queue.channelId = "ch"
        assertEquals(listOf("b", "a"), queue.items().map { it.id })
    }
}
