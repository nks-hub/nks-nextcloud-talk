package com.nkshub.nextcloudtalk.push

import com.google.android.gms.tasks.TaskCompletionSource
import com.google.android.gms.tasks.Tasks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidFcmFirstInstallResetTest {
    @Test
    fun firstInstallDeletesBeforePersistingTheCompletionMarker() {
        var complete = false
        var deletes = 0
        val reset = FirstInstallFcmTokenReset(
            isFirstInstall = { true },
            isComplete = { complete },
            deleteToken = {
                deletes++
                Tasks.forResult(null)
            },
            markComplete = {
                complete = true
                true
            },
        )

        assertTrue(reset.beforeGetToken().isSuccessful)
        assertEquals(1, deletes)
        assertTrue(complete)
        assertTrue(reset.beforeGetToken().isSuccessful)
        assertEquals(1, deletes)
    }

    @Test
    fun failedDeletionStaysRetryableAndNeverMarksCompletion() {
        var complete = false
        var deletes = 0
        val reset = FirstInstallFcmTokenReset(
            isFirstInstall = { true },
            isComplete = { complete },
            deleteToken = {
                deletes++
                Tasks.forException(IllegalStateException("provider rejected deletion"))
            },
            markComplete = {
                complete = true
                true
            },
        )

        assertFalse(reset.beforeGetToken().isSuccessful)
        assertFalse(complete)
        assertFalse(reset.beforeGetToken().isSuccessful)
        assertEquals(2, deletes)
    }

    @Test
    fun updatesAndCompletedFirstInstallsNeverRotateTheToken() {
        var deletes = 0
        fun reset(firstInstall: Boolean, complete: Boolean) = FirstInstallFcmTokenReset(
            isFirstInstall = { firstInstall },
            isComplete = { complete },
            deleteToken = {
                deletes++
                Tasks.forResult(null)
            },
            markComplete = { true },
        )

        assertTrue(reset(firstInstall = false, complete = false).beforeGetToken().isSuccessful)
        assertTrue(reset(firstInstall = true, complete = true).beforeGetToken().isSuccessful)
        assertEquals(0, deletes)
    }

    @Test
    fun concurrentRequestsAcrossInstancesShareOneProviderDeletion() {
        val provider = TaskCompletionSource<Void>()
        var deletes = 0
        var complete = false
        fun reset() = FirstInstallFcmTokenReset(
            isFirstInstall = { true },
            isComplete = { complete },
            deleteToken = {
                deletes++
                provider.task
            },
            markComplete = {
                complete = true
                true
            },
        )

        val first = reset().beforeGetToken()
        val second = reset().beforeGetToken()
        assertSame(first, second)
        assertEquals(1, deletes)

        provider.setResult(null)
        assertTrue(first.isSuccessful)
        assertTrue(complete)
    }

    @Test
    fun synchronousProviderFailureIsReturnedAsAFailedTask() {
        val reset = FirstInstallFcmTokenReset(
            isFirstInstall = { true },
            isComplete = { false },
            deleteToken = { throw IllegalStateException("provider unavailable") },
            markComplete = { true },
        )

        val task = reset.beforeGetToken()

        assertTrue(task.isComplete)
        assertFalse(task.isSuccessful)
        assertEquals("provider unavailable", task.exception?.message)
    }

    @Test
    fun synchronousPackageInfoFailureIsReturnedAsAFailedTask() {
        val reset = FirstInstallFcmTokenReset(
            isFirstInstall = { throw IllegalStateException("package info unavailable") },
            isComplete = { false },
            deleteToken = { Tasks.forResult(null) },
            markComplete = { true },
        )

        val task = reset.beforeGetToken()

        assertTrue(task.isComplete)
        assertFalse(task.isSuccessful)
        assertEquals("package info unavailable", task.exception?.message)
    }

    @Test
    fun tokenRefreshDuringResetIsSuppressedUntilFreshTokenIsAvailable() {
        val provider = TaskCompletionSource<Void>()
        var complete = false
        var providerToken = "cached-token"
        val forwarded = mutableListOf<String>()
        val reset = FirstInstallFcmTokenReset(
            isFirstInstall = { true },
            isComplete = { complete },
            deleteToken = { provider.task },
            markComplete = {
                complete = true
                true
            },
            currentToken = { Tasks.forResult(providerToken) },
        )

        val task = reset.beforeGetToken()
        reset.forwardTokenRefresh("cached-token", forwarded::add)
        provider.setResult(null)
        assertTrue(task.isSuccessful)
        providerToken = "fresh-token"
        assertTrue(reset.establishCurrentToken().isSuccessful)
        reset.forwardTokenRefresh("cached-token", forwarded::add)
        reset.forwardTokenRefresh("fresh-token", forwarded::add)
        providerToken = "rotated-token"
        reset.forwardTokenRefresh("rotated-token", forwarded::add)

        assertEquals(listOf("rotated-token"), forwarded)
    }

    @Test
    fun updatesAndCompletedInstallsForwardTokenRefreshesImmediately() {
        val forwarded = mutableListOf<String>()
        fun reset(
            firstInstall: Boolean,
            complete: Boolean,
            token: String,
        ) = FirstInstallFcmTokenReset(
            isFirstInstall = { firstInstall },
            isComplete = { complete },
            deleteToken = { Tasks.forResult(null) },
            markComplete = { true },
            currentToken = { Tasks.forResult(token) },
        )

        reset(firstInstall = false, complete = false, token = "update-token")
            .forwardTokenRefresh("update-token", forwarded::add)
        reset(firstInstall = true, complete = true, token = "completed-token")
            .forwardTokenRefresh("completed-token", forwarded::add)

        assertEquals(listOf("update-token", "completed-token"), forwarded)
    }

    @Test
    fun onlyNewestOutOfOrderProviderComparisonMayForward() {
        val lookups = mutableListOf<TaskCompletionSource<String>>()
        val forwarded = mutableListOf<String>()
        val reset = FirstInstallFcmTokenReset(
            isFirstInstall = { false },
            isComplete = { false },
            deleteToken = { Tasks.forResult(null) },
            markComplete = { true },
            currentToken = {
                TaskCompletionSource<String>().also(lookups::add).task
            },
        )

        reset.forwardTokenRefresh("token-b", forwarded::add)
        reset.forwardTokenRefresh("token-c", forwarded::add)
        assertEquals(2, lookups.size)

        lookups[1].setResult("token-c")
        lookups[0].setResult("token-b")

        assertEquals(listOf("token-c"), forwarded)
    }

    @Test
    fun callbackDuringExplicitEstablishIsReconciledAgainstCurrentProviderToken() {
        val deletion = TaskCompletionSource<Void>()
        val lookups = mutableListOf<TaskCompletionSource<String>>()
        val forwarded = mutableListOf<String>()
        var complete = false
        val reset = FirstInstallFcmTokenReset(
            isFirstInstall = { true },
            isComplete = { complete },
            deleteToken = { deletion.task },
            markComplete = {
                complete = true
                true
            },
            currentToken = {
                TaskCompletionSource<String>().also(lookups::add).task
            },
        )

        val resetTask = reset.beforeGetToken()
        deletion.setResult(null)
        assertTrue(resetTask.isSuccessful)
        val establish = reset.establishCurrentToken()
        assertEquals(1, lookups.size)

        reset.forwardTokenRefresh("token-c", forwarded::add)
        lookups[0].setResult("token-b")
        assertTrue(establish.isSuccessful)
        assertEquals(2, lookups.size)
        lookups[1].setResult("token-c")

        assertEquals(listOf("token-c"), forwarded)
    }
}
