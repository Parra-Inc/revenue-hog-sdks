package com.revenuehog.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RequestQueueTest {
    @Test
    fun `append and load round-trip in FIFO order`() {
        val queue = RequestQueue(MemoryStore())
        queue.append(PendingRequest("/a", "1"))
        queue.append(PendingRequest("/b", "2"))

        assertEquals(
            listOf(PendingRequest("/a", "1"), PendingRequest("/b", "2")),
            queue.load(),
        )
    }

    @Test
    fun `persists through the shared store`() {
        val store = MemoryStore()
        RequestQueue(store).append(PendingRequest("/a", "1"))

        assertEquals(listOf(PendingRequest("/a", "1")), RequestQueue(store).load())
    }

    @Test
    fun `caps at maxCount dropping the oldest`() {
        val queue = RequestQueue(MemoryStore(), maxCount = 3)
        for (i in 1..5) queue.append(PendingRequest("/$i", ""))

        assertEquals(listOf("/3", "/4", "/5"), queue.load().map { it.path })
    }

    @Test
    fun `corrupt stored data loads as empty`() {
        val store = MemoryStore()
        store.put("rh_queue", "not json")

        assertEquals(emptyList<PendingRequest>(), RequestQueue(store).load())
    }

    @Test
    fun `clear removes the key entirely`() {
        val store = MemoryStore()
        val queue = RequestQueue(store)
        queue.append(PendingRequest("/a", "1"))
        queue.clear()

        assertEquals(emptyList<PendingRequest>(), queue.load())
        assertNull(store.get("rh_queue"))
    }
}
