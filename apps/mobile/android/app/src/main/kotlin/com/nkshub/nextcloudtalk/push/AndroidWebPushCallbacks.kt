package com.nkshub.nextcloudtalk.push

import android.content.Context
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.MessagingReceiver
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

internal object AndroidWebPushEventSink {
    fun endpoint(context: Context, endpoint: PushEndpoint, instance: String) {
        val result = AndroidWebPushStore(context).storeEndpoint(
            instance = instance,
            url = endpoint.url,
            publicKey = endpoint.pubKeySet?.pubKey,
            authSecret = endpoint.pubKeySet?.auth,
            temporary = endpoint.temporary,
        )
        notifyIfStored(result)
    }

    fun message(context: Context, message: PushMessage, instance: String) {
        val store = AndroidWebPushStore(context)
        val payload = AndroidWebPushPayloadParser.parse(message.content, message.decrypted)
        val result = when (payload) {
            is AndroidWebPushPayload.Activation -> store.storeActivation(
                instance = instance,
                content = message.content,
                decrypted = message.decrypted,
            )
            AndroidWebPushPayload.Invalid -> store.storeInvalidMessage(instance)
            else -> store.storeMessage(
                instance = instance,
                content = message.content,
                decrypted = message.decrypted,
            )
        }
        if (result.stored) {
            store.accountIdForInstance(instance)?.let { accountId ->
                AndroidSystemNotifications.apply(context, accountId, payload)
            }
        }
        notifyIfStored(result)
    }

    fun registrationFailed(context: Context, reason: FailedReason, instance: String) {
        val result = AndroidWebPushStore(context).storeRegistrationFailed(instance, reason.name)
        notifyIfStored(result)
    }

    fun unregistered(context: Context, instance: String) {
        val result = AndroidWebPushStore(context).storeUnregistered(instance)
        notifyIfStored(result)
    }

    fun temporaryUnavailable(context: Context, instance: String) {
        val result = AndroidWebPushStore(context).storeTemporaryUnavailable(instance)
        notifyIfStored(result)
    }

    private fun notifyIfStored(result: StoredEventResult) {
        if (result.stored) {
            AndroidWebPushNotifier.publish(result.totalPendingCount)
        }
    }
}

@Suppress("DEPRECATION")
class AndroidWebPushReceiver : MessagingReceiver() {
    override fun onNewEndpoint(
        context: Context,
        endpoint: PushEndpoint,
        instance: String,
    ) = AndroidWebPushEventSink.endpoint(context, endpoint, instance)

    override fun onMessage(
        context: Context,
        message: PushMessage,
        instance: String,
    ) = AndroidWebPushEventSink.message(context, message, instance)

    override fun onRegistrationFailed(
        context: Context,
        reason: FailedReason,
        instance: String,
    ) = AndroidWebPushEventSink.registrationFailed(context, reason, instance)

    override fun onUnregistered(context: Context, instance: String) =
        AndroidWebPushEventSink.unregistered(context, instance)

    override fun onTempUnavailable(context: Context, instance: String) =
        AndroidWebPushEventSink.temporaryUnavailable(context, instance)
}

class AndroidWebPushService : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) =
        AndroidWebPushEventSink.endpoint(this, endpoint, instance)

    override fun onMessage(message: PushMessage, instance: String) =
        AndroidWebPushEventSink.message(this, message, instance)

    override fun onRegistrationFailed(reason: FailedReason, instance: String) =
        AndroidWebPushEventSink.registrationFailed(this, reason, instance)

    override fun onUnregistered(instance: String) =
        AndroidWebPushEventSink.unregistered(this, instance)

    override fun onTempUnavailable(instance: String) =
        AndroidWebPushEventSink.temporaryUnavailable(this, instance)
}
