package dev.waal.hadaq

import android.content.ComponentName
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.Settings
import android.telephony.SmsManager
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hadaq/native")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "sendSms" -> {
                    val numbers = call.argument<List<String>>("numbers") ?: emptyList()
                    val text = call.argument<String>("text") ?: ""
                    try {
                        @Suppress("DEPRECATION")
                        val sms: SmsManager =
                            if (Build.VERSION.SDK_INT >= 31) getSystemService(SmsManager::class.java)
                            else SmsManager.getDefault()
                        var sent = 0
                        for (n in numbers) {
                            val parts = sms.divideMessage(text)
                            sms.sendMultipartTextMessage(n, null, parts, null, null)
                            sent++
                        }
                        result.success(sent)
                    } catch (e: Exception) {
                        result.error("SMS_FAILED", e.message, null)
                    }
                }
                "call" -> {
                    val number = call.argument<String>("number") ?: ""
                    try {
                        val i = Intent(Intent.ACTION_CALL, Uri.parse("tel:" + number))
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(i)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "adjustVolume" -> {
                    val up = call.argument<Boolean>("up") ?: true
                    val am = getSystemService(AUDIO_SERVICE) as AudioManager
                    am.adjustStreamVolume(
                        AudioManager.STREAM_MUSIC,
                        if (up) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER,
                        0
                    )
                    // Two steps feel like a real change.
                    am.adjustStreamVolume(
                        AudioManager.STREAM_MUSIC,
                        if (up) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER,
                        0
                    )
                    result.success(true)
                }
                "listApps" -> {
                    // Launchable apps: label as shown on the phone + package name.
                    val pm = packageManager
                    val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    val apps = pm.queryIntentActivities(main, 0)
                        .map { mapOf("label" to it.loadLabel(pm).toString(), "package" to it.activityInfo.packageName) }
                        .distinctBy { it["package"] }
                    result.success(apps)
                }
                "openApp" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    val i = packageManager.getLaunchIntentForPackage(pkg)
                    if (i == null) {
                        result.success(false)
                    } else {
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(i)
                        result.success(true)
                    }
                }
                "waNumber" -> {
                    // WhatsApp registers each contact that has an account in the phonebook with its exact
                    // international number (the JID). Use it so the right chat opens whatever the stored format.
                    val name = call.argument<String>("name") ?: ""
                    val digits = (call.argument<String>("number") ?: "").filter { it.isDigit() }
                    val tail = if (digits.length >= 7) digits.takeLast(7) else digits
                    var byNumber: String? = null
                    var byName: String? = null
                    try {
                        val c = contentResolver.query(
                            ContactsContract.Data.CONTENT_URI,
                            arrayOf(ContactsContract.Data.DISPLAY_NAME, ContactsContract.Data.DATA1, ContactsContract.Data.DATA3),
                            "${ContactsContract.Data.MIMETYPE} IN (?, ?)",
                            arrayOf("vnd.android.cursor.item/vnd.com.whatsapp.profile", "vnd.android.cursor.item/vnd.com.whatsapp.w4b.profile"),
                            null
                        )
                        c?.use {
                            while (it.moveToNext() && byNumber == null) {
                                val dn = it.getString(0) ?: ""
                                val jid = (it.getString(1) ?: "").substringBefore("@").filter { ch -> ch.isDigit() }
                                val d3 = (it.getString(2) ?: "").filter { ch -> ch.isDigit() }
                                if (jid.isEmpty()) continue
                                if (tail.isNotEmpty() && (jid.endsWith(tail) || d3.endsWith(tail))) byNumber = jid
                                else if (byName == null && dn == name) byName = jid
                            }
                        }
                    } catch (e: Exception) {}
                    result.success(byNumber ?: byName)
                }
                "a11yEnabled" -> result.success(isA11yEnabled())
                "openA11ySettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                }
                "sendWhatsApp" -> {
                    // Opens the chat with the confirmed text; if the service is on, it presses send.
                    val phone = call.argument<String>("phone") ?: ""
                    val text = call.argument<String>("text") ?: ""
                    val auto = call.argument<Boolean>("auto") ?: false
                    val pkg = listOf("com.whatsapp", "com.whatsapp.w4b").firstOrNull { isInstalled(it) }
                    if (pkg == null) {
                        result.success("not_installed")
                    } else {
                        // mode "link": international number known -> chat opens with the text typed.
                        // mode "contact": number as saved in the phonebook (local format) -> WhatsApp matches it
                        // against the phone's contacts itself; the service then types the text.
                        val mode = call.argument<String>("mode") ?: "link"
                        val i = if (mode == "contact") {
                            Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + Uri.encode(phone))).setPackage(pkg)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        } else {
                            val uri = Uri.parse("https://api.whatsapp.com/send?phone=$phone&text=" + Uri.encode(text))
                            Intent(Intent.ACTION_VIEW, uri).setPackage(pkg).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        HadaqAccessibilityService.pendingText = if (mode == "contact") text else null
                        if (auto && isA11yEnabled()) HadaqAccessibilityService.armedUntil = System.currentTimeMillis() + 15000
                        try {
                            startActivity(i)
                            result.success(if (auto && isA11yEnabled()) "armed" else "opened")
                        } catch (e: Exception) {
                            HadaqAccessibilityService.armedUntil = 0L
                            result.success("failed")
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        current = this
    }

    override fun onDestroy() {
        if (current === this) current = null
        super.onDestroy()
    }

    private fun isInstalled(pkg: String): Boolean = try {
        packageManager.getPackageInfo(pkg, 0); true
    } catch (e: Exception) {
        false
    }

    private fun isA11yEnabled(): Boolean {
        val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val me = ComponentName(this, HadaqAccessibilityService::class.java).flattenToString()
        return enabled.split(':').any { it.equals(me, ignoreCase = true) }
    }

    companion object {
        private var current: MainActivity? = null

        /** Called by the accessibility service after it pressed WhatsApp's send button. */
        fun reportWhatsAppSent(ok: Boolean) {
            current?.runOnUiThread { current?.channel?.invokeMethod("whatsappSent", ok) }
        }
    }

    // Volume-up = talk (design: "زر رفع الصوت = تحدّث"). Consumed so the volume doesn't change.
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP && (event?.repeatCount ?: 0) == 0) {
            channel?.invokeMethod("volumeUp", null)
            return true
        }
        return super.onKeyDown(keyCode, event)
    }
}
