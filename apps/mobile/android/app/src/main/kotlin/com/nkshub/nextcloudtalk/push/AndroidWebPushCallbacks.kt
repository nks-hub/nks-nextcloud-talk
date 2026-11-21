package com.nkshub.nextcloudtalk.push

import android.content.Context
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.MessagingReceiver
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage
import com.nkshub.nextcloudtalk.attachments.AttachmentTransferService
import com.nkshub.nextcloudtalk.background.BackgroundDrain

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
        val diagnostics = AndroidPushDeliveryDiagnosticsStore(context)
        diagnostics.recordReceived(PushDeliveryTransport.WEB_PUSH)
        val payload = AndroidWebPushPayloadParser.parse(message.content, message.decrypted)
        val accountId = store.accountIdForInstance(instance)
        if (!AndroidSystemNotifications.wakesTalk(payload)) {
            accountId?.let {
                if (message.decrypted) {
                    diagnostics.recordDecrypted(PushDeliveryTransport.WEB_PUSH, it)
                }
                diagnostics.recordDisplay(
                    PushDeliveryTransport.WEB_PUSH,
                    it,
                    PushDisplayOutcome.FILTERED_OTHER_APP,
                )
            }
            return
        }
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
        if (accountId != null) {
            if (message.decrypted) {
                diagnostics.recordDecrypted(PushDeliveryTransport.WEB_PUSH, accountId)
            } else {
                diagnostics.recordFailure(
                    PushDeliveryTransport.WEB_PUSH,
                    "not-decrypted",
                    accountId = accountId,
                )
            }
        }
        if (result.stored) {
            accountId?.let {
                val displayOutcome = try {
                    AndroidSystemNotifications.apply(context, it, payload)
                } catch (error: Throwable) {
                    diagnostics.recordFailure(
                        PushDeliveryTransport.WEB_PUSH,
                        "display-failed",
                        accountId = it,
                    )
                    throw error
                }
                displayOutcome?.let { outcome ->
                    diagnostics.recordDisplay(PushDeliveryTransport.WEB_PUSH, it, outcome)
                }
                if (payload == AndroidWebPushPayload.Invalid) {
                    diagnostics.recordFailure(
                        PushDeliveryTransport.WEB_PUSH,
                        "invalid-payload",
                        accountId = it,
                    )
                }
            }
        }
        if (AttachmentTransferService.unsentWaiting(context)) {
            BackgroundDrain.scheduleForPush(context)
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
