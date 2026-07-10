package com.revenuehog.android

/** How chatty the SDK is. Errors are always swallowed — never thrown. */
enum class LogLevel { DEBUG, INFO, WARN, ERROR, SILENT }

/**
 * Optional knobs for [RevenueHog.configure].
 *
 * @property baseUrl API host — override for self-hosted deployments or dev.
 * @property logLevel defaults to [LogLevel.WARN].
 */
data class Options(
    val baseUrl: String = "https://revenuehog.dev",
    val logLevel: LogLevel = LogLevel.WARN,
)

internal class Logger(
    private val level: LogLevel,
    private val sink: (String) -> Unit = { println("[revenuehog] $it") },
) {
    fun debug(message: String) = emit(LogLevel.DEBUG, message)
    fun info(message: String) = emit(LogLevel.INFO, message)
    fun warn(message: String) = emit(LogLevel.WARN, message)
    fun error(message: String) = emit(LogLevel.ERROR, message)

    private fun emit(at: LogLevel, message: String) {
        if (level == LogLevel.SILENT || at.ordinal < level.ordinal) return
        try {
            sink(message)
        } catch (_: Throwable) {
            // even logging must never crash the host app
        }
    }
}
