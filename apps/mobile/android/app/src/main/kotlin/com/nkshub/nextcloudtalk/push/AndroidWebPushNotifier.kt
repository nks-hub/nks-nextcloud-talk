package com.nkshub.nextcloudtalk.push

internal object AndroidWebPushNotifier {
    private var listener: ((Int) -> Unit)? = null

    @Synchronized
    fun attach(newListener: (Int) -> Unit) {
        listener = newListener
    }

    @Synchronized
    fun detach(attachedListener: (Int) -> Unit) {
        if (listener === attachedListener) {
            listener = null
        }
    }

    fun publish(count: Int) {
        val current = synchronized(this) { listener }
        current?.invoke(count)
    }
}
