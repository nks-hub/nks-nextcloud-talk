package com.nkshub.nextcloudtalk.push

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.android.gms.tasks.Tasks
import com.google.firebase.messaging.FirebaseMessaging
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class AndroidFcmFirstInstallResetRuntimeTest {
    @Test
    fun firstInstallResetReplacesAStaleProviderToken() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences(
            "android_fcm_accounts",
            Context.MODE_PRIVATE,
        )
        preferences.edit()
            .remove(AndroidFcmChannel.FIRST_INSTALL_RESET_COMPLETE)
            .commit()
        val messaging = FirebaseMessaging.getInstance()
        val before = Tasks.await(messaging.token, 30, TimeUnit.SECONDS)
        val reset = FirstInstallFcmTokenReset(
            isFirstInstall = { true },
            isComplete = {
                preferences.getBoolean(
                    AndroidFcmChannel.FIRST_INSTALL_RESET_COMPLETE,
                    false,
                )
            },
            deleteToken = messaging::deleteToken,
            markComplete = {
                preferences.edit()
                    .putBoolean(AndroidFcmChannel.FIRST_INSTALL_RESET_COMPLETE, true)
                    .commit()
            },
        )

        Tasks.await(reset.beforeGetToken(), 30, TimeUnit.SECONDS)
        val after = Tasks.await(messaging.token, 30, TimeUnit.SECONDS)

        assertNotEquals(before, after)
        assertTrue(
            preferences.getBoolean(
                AndroidFcmChannel.FIRST_INSTALL_RESET_COMPLETE,
                false,
            ),
        )
    }
}
