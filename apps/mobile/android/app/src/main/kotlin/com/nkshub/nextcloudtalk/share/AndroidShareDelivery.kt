package com.nkshub.nextcloudtalk.share

import java.util.ArrayDeque

internal class AndroidShareDelivery(
    private val deliver: (Map<String, Any?>) -> Unit,
) {
    private val pending = ArrayDeque<AndroidIncomingShare>()
    private val queuedIds = mutableSetOf<String>()
    private var ready = false

    fun opened(share: AndroidIncomingShare) {
        val liveShare = synchronized(this) {
            if (!queuedIds.add(share.id)) {
                return
            }
            if (!ready) {
                pending.addLast(share)
                null
            } else {
                share
            }
        }
        liveShare?.let { deliver(it.asMap()) }
    }

    fun markReadyAndTakeLaunch(): Map<String, Any?>? {
        val callbacks = mutableListOf<AndroidIncomingShare>()
        val launch = synchronized(this) {
            if (ready) return null
            ready = true
            val first = pending.pollFirst()
            while (pending.isNotEmpty()) callbacks.add(pending.removeFirst())
            first
        }
        callbacks.forEach { deliver(it.asMap()) }
        return launch?.asMap()
    }
}
