package com.revenuehog.android

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** Minimal HTTP seam so tests run without a network. */
internal interface Transport {
    /**
     * POSTs [body] and returns the HTTP status code. Throws [IOException]
     * on transport (network) failure only — HTTP error statuses are
     * returned, not thrown.
     */
    @Throws(IOException::class)
    fun post(url: String, body: String, headers: Map<String, String>): Int
}

/** Plain HttpURLConnection — ships with the platform, zero dependencies. */
internal class HttpUrlConnectionTransport : Transport {
    override fun post(url: String, body: String, headers: Map<String, String>): Int {
        val connection = URL(url).openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.doOutput = true
            for ((field, value) in headers) connection.setRequestProperty(field, value)
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            connection.responseCode
        } finally {
            connection.disconnect()
        }
    }
}
