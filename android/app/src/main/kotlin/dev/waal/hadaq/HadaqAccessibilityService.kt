package dev.waal.hadaq

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Presses WhatsApp's send button for a message the user dictated and confirmed in Hadaq.
 *
 * It only acts while Hadaq has "armed" it (a few seconds after opening a chat with the
 * prepared text), only inside WhatsApp, and only on the send button. Nothing is read
 * or stored from other apps.
 */
class HadaqAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile var armedUntil: Long = 0L
        /** Text to type into the chat first (when the chat was opened without it). */
        @Volatile var pendingText: String? = null
        private val ENTRY_IDS = listOf("com.whatsapp:id/entry", "com.whatsapp.w4b:id/entry")
        @Volatile var instance: HadaqAccessibilityService? = null
        private val SEND_IDS = listOf("com.whatsapp:id/send", "com.whatsapp.w4b:id/send")
        private val SEND_LABELS = listOf("Send", "إرسال", "ارسال")
    }

    private val main = Handler(Looper.getMainLooper())

    override fun onServiceConnected() {
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (System.currentTimeMillis() > armedUntil) return
        val pkg = event?.packageName?.toString() ?: return
        if (pkg != "com.whatsapp" && pkg != "com.whatsapp.w4b") return
        val root = rootInActiveWindow ?: return
        val text = pendingText
        if (text != null) {
            val entry = ENTRY_IDS.firstNotNullOfOrNull { id -> root.findAccessibilityNodeInfosByViewId(id)?.firstOrNull() } ?: return
            val args = android.os.Bundle()
            args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
            if (!entry.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) return
            pendingText = null
            return // the send button appears once the field has text; the next event presses it
        }
        val button = findSend(root) ?: return
        if (!button.isEnabled) return
        armedUntil = 0L
        val clicked = button.performAction(AccessibilityNodeInfo.ACTION_CLICK) ||
            (button.parent?.performAction(AccessibilityNodeInfo.ACTION_CLICK) ?: false)
        // Give WhatsApp a moment to send, then bring Hadaq back and report.
        main.postDelayed({
            MainActivity.reportWhatsAppSent(clicked)
            val back = Intent(this, MainActivity::class.java)
            back.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            startActivity(back)
        }, 900)
    }

    private fun findSend(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        for (id in SEND_IDS) {
            val nodes = root.findAccessibilityNodeInfosByViewId(id)
            if (!nodes.isNullOrEmpty()) return nodes[0]
        }
        for (label in SEND_LABELS) {
            val nodes = root.findAccessibilityNodeInfosByText(label)
            val n = nodes?.firstOrNull { it.isClickable && (it.contentDescription?.toString() == label) }
            if (n != null) return n
        }
        return null
    }
}
