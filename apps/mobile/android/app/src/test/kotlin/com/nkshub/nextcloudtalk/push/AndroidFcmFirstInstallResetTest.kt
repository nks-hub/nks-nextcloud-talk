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
    fun concurrentRequestsShareOneProviderDeletion() {
        val provider = TaskCompletionSource<Void>()
        var deletes = 0
        var complete = false
        val reset = FirstInstallFcmTokenReset(
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

        val first = reset.beforeGetToken()
        val second = reset.beforeGetToken()
        assertSame(first, second)
        assertEquals(1, deletes)

        provider.setResult(null)
        assertTrue(first.isSuccessful)
        assertTrue(complete)
    }
}
