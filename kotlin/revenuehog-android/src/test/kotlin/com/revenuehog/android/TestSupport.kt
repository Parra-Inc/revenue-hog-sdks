package com.revenuehog.android

import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.Executor

internal class MemoryStore : KeyValueStore {
    private val values = mutableMapOf<String, String>()

    override fun get(key: String): String? = values[key]

    override fun put(key: String, value: String?) {
        if (value == null) values.remove(key) else values[key] = value
    }
}

internal data class Recorded(
    val url: String,
    val body: String,
    val headers: Map<String, String>,
) {
    val json: JSONObject get() = JSONObject(body)
}

/**
 * Scriptable transport. Responses are consumed in order; once the script
 * runs dry every request succeeds with 200. Negative values simulate a
 * network error (IOException).
 */
internal class FakeTransport(vararg script: Int) : Transport {
    private val script = script.toMutableList()
    val requests = mutableListOf<Recorded>()

    override fun post(url: String, body: String, headers: Map<String, String>): Int {
        requests.add(Recorded(url, body, headers))
        val next = if (script.isEmpty()) 200 else script.removeAt(0)
        if (next < 0) throw IOException("network down")
        return next
    }
}

internal object TestSupport {
    const val NETWORK_ERROR = -1

    fun makeClient(
        transport: FakeTransport,
        store: KeyValueStore = MemoryStore(),
    ): HogClient = HogClient(
        options = Options(baseUrl = "https://example.test", logLevel = LogLevel.SILENT),
        device = DeviceInfo(
            bundleId = "com.example.app",
            platform = "android",
            osVersion = "14",
            deviceModel = "Pixel 8",
            locale = "en_US",
        ),
        store = store,
        transport = transport,
        executor = Executor { it.run() }, // synchronous for deterministic tests
        backoffMs = { 0 },
        sleep = { },
        logSink = { },
    )
}
