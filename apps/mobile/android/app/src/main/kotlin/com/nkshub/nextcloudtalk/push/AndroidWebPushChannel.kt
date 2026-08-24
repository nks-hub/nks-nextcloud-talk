package com.nkshub.nextcloudtalk.push

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.unifiedpush.android.connector.UnifiedPush

internal class AndroidWebPushChannel(context: Context) : MethodChannel.MethodCallHandler {
    private val applicationContext = context.applicationContext
    private val store = AndroidWebPushStore(applicationContext)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            if (call.method != "getAvailability") {
                reconcilePendingNativeUnregistrations()
            }
            when (call.method) {
                "getAvailability" -> result.success(getAvailability())
                "register" -> result.success(register(requireArguments(call)))
                "commitEndpoint" -> result.success(commitEndpoint(requireArguments(call)))
                "retireAfterServerRevocation" -> {
                    result.success(retireAfterServerRevocation(requireArguments(call)))
                }
                "pendingEventCount" -> result.success(pendingEventCount(requireArguments(call)))
                "drainEvents" -> result.success(drainEvents(requireArguments(call)))
                "acknowledge" -> result.success(acknowledge(requireArguments(call)))
                else -> result.notImplemented()
            }
        } catch (error: PushBridgeException) {
            result.error(error.code, "Android Web Push request was rejected.", null)
        } catch (error: PushStateException) {
            result.error(error.code, "Android Web Push state rejected the request.", null)
        } catch (error: PushStoreException) {
            result.error(error.code, "Android Web Push secure storage failed.", null)
        } catch (_: UnifiedPush.VapidNotValidException) {
            result.error("invalid_vapid", "The VAPID public key is invalid.", null)
        } catch (_: Throwable) {
            result.error(
                "android_web_push_failure",
                "Android Web Push operation failed.",
                null,
            )
        }
    }

    fun reconcilePendingNativeUnregistrations(): Int {
        return reconcileNativeUnregistrations(store.pendingNativeUnregistrations())
    }

    private fun getAvailability(): Map<String, Any> {
        val available = UnifiedPush.getDistributors(applicationContext)
            .contains(applicationContext.packageName)
        return mapOf(
            "available" to available,
            "playServicesAvailable" to available,
        )
    }

    private fun register(arguments: Map<*, *>): Map<String, Any> {
        val accountId = arguments.requiredAccountId()
        val generation = arguments.requiredGeneration()
        val vapid = arguments.requiredString("vapidPublicKey", MAX_VAPID_LENGTH)
        if (!VAPID_REGEX.matches(vapid)) {
            throw PushBridgeException("invalid_vapid")
        }
        ensureEmbeddedDistributor()

        val request = store.beginRegistration(
            accountId = accountId,
            generation = generation,
            instance = AndroidWebPushStore.newOpaqueInstance(),
        )
        synchronized(CONNECTOR_LOCK) {
            UnifiedPush.register(
                applicationContext,
                request.result.record.instance,
                DISTRIBUTOR_LABEL,
                vapid,
            )
        }
        reconcileNativeUnregistrations(request.pendingNativeUnregistrations)
        return mapOf(
            "generation" to generation,
            "status" to if (request.result.created) "created" else "reregistered",
        )
    }

    private fun commitEndpoint(arguments: Map<*, *>): Map<String, Any> {
        val accountId = arguments.requiredAccountId()
        val generation = arguments.requiredGeneration()
        val eventId = arguments.requiredString("eventId", MAX_EVENT_ID_LENGTH)
        val commit = store.commitEndpoint(accountId, generation, eventId)
        reconcileNativeUnregistrations(commit.nativeUnregisterInstances)
        return mapOf(
            "serverRevokeGenerations" to commit.serverRevokeGenerations,
        )
    }

    private fun retireAfterServerRevocation(arguments: Map<*, *>): Map<String, Any> {
        val accountId = arguments.requiredAccountId()
        val generation = arguments.requiredGeneration()
        val instances = store.retireAfterServerRevocation(accountId, generation)
        return mapOf("retiredCount" to reconcileNativeUnregistrations(instances))
    }

    private fun pendingEventCount(arguments: Map<*, *>): Map<String, Any> {
        val accountId = arguments.requiredAccountId()
        return mapOf("count" to store.pendingEventCount(accountId))
    }

    private fun drainEvents(arguments: Map<*, *>): List<Map<String, Any?>> {
        val accountId = arguments.requiredAccountId()
        val limit = arguments.requiredInt("limit")
        if (limit !in 1..MAX_DRAIN_EVENTS) {
            throw PushBridgeException("invalid_drain_limit")
        }
        return store.drain(accountId, limit)
    }

    private fun acknowledge(arguments: Map<*, *>): Map<String, Any> {
        val accountId = arguments.requiredAccountId()
        val ids = arguments["eventIds"] as? List<*>
            ?: throw PushBridgeException("invalid_event_ids")
        if (ids.isEmpty() || ids.size > MAX_ACK_EVENTS) {
            throw PushBridgeException("invalid_event_ids")
        }
        val eventIds = ids.map {
            val value = it as? String ?: throw PushBridgeException("invalid_event_ids")
            if (value.isBlank() || value.length > MAX_EVENT_ID_LENGTH) {
                throw PushBridgeException("invalid_event_ids")
            }
            value
        }.toSet()
        return mapOf("removedCount" to store.acknowledge(accountId, eventIds))
    }

    private fun ensureEmbeddedDistributor() {
        if (!UnifiedPush.getDistributors(applicationContext).contains(applicationContext.packageName)) {
            throw PushBridgeException("embedded_distributor_unavailable")
        }
        synchronized(CONNECTOR_LOCK) {
            when (val saved = UnifiedPush.getSavedDistributor(applicationContext)) {
                null -> UnifiedPush.saveDistributor(applicationContext, applicationContext.packageName)
                applicationContext.packageName -> Unit
                else -> throw PushBridgeException("distributor_conflict")
            }
        }
    }

    private fun reconcileNativeUnregistrations(instances: List<String>): Int {
        var retired = 0
        instances.distinct().forEach { instance ->
            synchronized(CONNECTOR_LOCK) {
                UnifiedPush.unregister(applicationContext, instance)
            }
            store.markRetired(instance)
            retired++
        }
        return retired
    }

    private fun requireArguments(call: MethodCall): Map<*, *> {
        return call.arguments as? Map<*, *> ?: throw PushBridgeException("invalid_arguments")
    }

    companion object {
        private val CONNECTOR_LOCK = Any()
        private val VAPID_REGEX = Regex("^[A-Za-z0-9_-]{87}$")

        private const val DISTRIBUTOR_LABEL = "NKS Talk"
        private const val MAX_VAPID_LENGTH = 87
        private const val MAX_EVENT_ID_LENGTH = 128
        private const val MAX_ACCOUNT_ID_LENGTH = 256
        private const val MAX_DRAIN_EVENTS = 100
        private const val MAX_ACK_EVENTS = 100

        private fun Map<*, *>.requiredAccountId(): String {
            return requiredString("accountId", MAX_ACCOUNT_ID_LENGTH)
        }

        private fun Map<*, *>.requiredGeneration(): Long {
            val generation = requiredLong("generation")
            if (generation <= 0) {
                throw PushBridgeException("invalid_generation")
            }
            return generation
        }

        private fun Map<*, *>.requiredString(key: String, maximumLength: Int): String {
            val value = this[key] as? String ?: throw PushBridgeException("invalid_$key")
            if (value.isBlank() || value.length > maximumLength) {
                throw PushBridgeException("invalid_$key")
            }
            return value
        }

        private fun Map<*, *>.requiredLong(key: String): Long {
            return when (val value = this[key]) {
                is Int -> value.toLong()
                is Long -> value
                else -> throw PushBridgeException("invalid_$key")
            }
        }

        private fun Map<*, *>.requiredInt(key: String): Int {
            return when (val value = this[key]) {
                is Int -> value
                is Long -> value.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()
                    ?: throw PushBridgeException("invalid_$key")
                else -> throw PushBridgeException("invalid_$key")
            }
        }
    }
}

internal class PushBridgeException(val code: String) : IllegalArgumentException(code)
