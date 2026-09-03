package com.nkshub.nextcloudtalk.shortcuts

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import androidx.annotation.RequiresApi
import com.nkshub.nextcloudtalk.R
import com.nkshub.nextcloudtalk.push.AndroidWebPushActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Publishes recently active conversations as launcher shortcuts.
 *
 * A shortcut carries nothing but the room's own `https` deep link, so opening
 * one walks the same account-scoped resolution path as a link tapped in a
 * browser. The launcher never holds an account id, a token or a credential of
 * its own, and a shortcut left behind after a sign-out resolves to no account
 * and opens nothing.
 */
class ConversationShortcuts(private val context: Context) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "publish") {
            result.notImplemented()
            return
        }
        val entries = call.argument<List<Map<String, Any?>>>("shortcuts") ?: emptyList()
        result.success(publish(entries))
    }

    /** Replaces the whole dynamic set and reports how many shortcuts stuck. */
    private fun publish(entries: List<Map<String, Any?>>): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) {
            return 0
        }
        val manager = context.getSystemService(ShortcutManager::class.java) ?: return 0
        val limit = manager.maxShortcutCountPerActivity.coerceAtLeast(0)
        val shortcuts = entries.mapNotNull(::shortcut).take(limit)
        // The system rate-limits a background app rather than throwing, so the
        // returned count is what actually reached the launcher, not what was
        // asked for.
        return runCatching {
            if (manager.setDynamicShortcuts(shortcuts)) shortcuts.size else 0
        }.getOrDefault(0)
    }

    @RequiresApi(Build.VERSION_CODES.N_MR1)
    private fun shortcut(entry: Map<String, Any?>): ShortcutInfo? {
        val id = (entry["id"] as? String)?.takeIf { it.isNotBlank() } ?: return null
        val label = (entry["label"] as? String)?.takeIf { it.isNotBlank() } ?: return null
        val uri = (entry["uri"] as? String)?.takeIf { it.isNotBlank() } ?: return null
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri))
            .setClass(context, AndroidWebPushActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return ShortcutInfo.Builder(context, id)
            .setShortLabel(label.take(MAX_SHORT_LABEL))
            .setLongLabel(label.take(MAX_LONG_LABEL))
            .setIcon(Icon.createWithResource(context, R.mipmap.ic_launcher))
            .setIntent(intent)
            .build()
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/shortcuts"

        // Launchers truncate long names themselves; these caps only keep a
        // pathological room name from being handed to the system verbatim.
        private const val MAX_SHORT_LABEL = 32
        private const val MAX_LONG_LABEL = 96
    }
}
