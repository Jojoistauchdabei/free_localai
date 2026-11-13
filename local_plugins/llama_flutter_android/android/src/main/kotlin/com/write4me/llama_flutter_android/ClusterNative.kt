package com.write4me.llama_flutter_android

import java.io.File

/** JNI entry points for the phone cluster (llama.cpp's RPC backend). */
object ClusterNative {
    init {
        System.loadLibrary("llama_jni")
    }

    /**
     * Sets the workers the next model load spreads its layers across. Each
     * worker gets a share of the offloaded layers by its weight (e.g. free
     * RAM); this phone keeps a share by [localWeight]. An empty list turns
     * cluster mode off. Every endpoint must already be reachable: llama.cpp
     * aborts the process if it can't connect.
     */
    external fun nativeSetCluster(endpoints: Array<String>, weights: FloatArray, localWeight: Float)

    /**
     * Serves this phone's CPU to a coordinator. Blocks for as long as the
     * server runs; returns why it stopped if it couldn't start.
     */
    external fun nativeServe(libDir: String, endpoint: String, cacheDir: String, nThreads: Long): String?

    /** "<buffer name>\t<MiB>" lines: where the last load put its weights. */
    external fun nativeLastLoadBuffers(): String

    /** Worker: the connected master's address, or null. */
    external fun nativeWorkerPeer(): String?

    /** Memory read speed in GB/s; ranks phones by how fast they generate. */
    external fun nativeMemBandwidth(threads: Int): Double

    /**
     * CPUs this process may run on. Use every CPU allowed to the app so the
     * master can make the final scheduling decision.
     */
    fun fastCoreCount(): Int {
        val allowed = File("/proc/self/status").readLines()
            .firstOrNull { it.startsWith("Cpus_allowed_list:") }
            ?.substringAfter(':')?.trim()
            ?.split(',')
            ?.flatMap { range ->
                val (a, b) = (range.split('-') + range).let { it[0] to it[1] }
                (a.trim().toInt()..b.trim().toInt()).toList()
            }
            ?: (0 until Runtime.getRuntime().availableProcessors()).toList()
        return allowed.size.coerceAtLeast(1)
    }
}
