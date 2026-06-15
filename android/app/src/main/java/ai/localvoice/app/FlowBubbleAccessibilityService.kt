package ai.localvoice.app

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Toast

/**
 * Inserts dictated text into whatever editable field is focused in any app.
 * The Flow Bubble talks to this service through a static instance. Without it
 * granted, dictation falls back to copying the text to the clipboard.
 */
class FlowBubbleAccessibilityService : AccessibilityService() {

  override fun onServiceConnected() {
    super.onServiceConnected()
    instance = this
    syncBubble()
  }

  override fun onDestroy() {
    if (instance === this) instance = null
    super.onDestroy()
  }

  // Show the bubble only while an editable field is focused; recompute whenever
  // focus, selection, or the foreground window changes.
  override fun onAccessibilityEvent(event: AccessibilityEvent?) {
    when (event?.eventType) {
      AccessibilityEvent.TYPE_VIEW_FOCUSED,
      AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED,
      AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> syncBubble()
    }
  }

  override fun onInterrupt() {}

  /** Tell the bubble whether an editable field is currently focused. */
  fun syncBubble() {
    FlowBubbleService.instance?.setBubbleVisible(findFocusedEditable() != null)
  }

  /** Inserts [text] at the cursor of the focused field. Returns true on success. */
  fun insertText(text: String): Boolean {
    if (text.isEmpty()) return true
    val focused = findFocusedEditable()
    if (focused == null) {
      copyToClipboard(text)
      Toast.makeText(this, "Copied — tap a text field and paste", Toast.LENGTH_SHORT).show()
      return false
    }
    // Prefer paste (inserts at cursor, keeps surrounding text). Fall back to
    // replacing the field with existing + new text if paste isn't supported.
    copyToClipboard(text)
    if (focused.performAction(AccessibilityNodeInfo.ACTION_PASTE)) return true

    val existing = focused.text?.toString() ?: ""
    val joined = if (existing.isEmpty()) text else "$existing $text"
    val args = Bundle().apply {
      putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, joined)
    }
    val ok = focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    if (ok) {
      val end = joined.length
      val sel = Bundle().apply {
        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, end)
        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
      }
      focused.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, sel)
    }
    return ok
  }

  private fun findFocusedEditable(): AccessibilityNodeInfo? {
    val root = rootInActiveWindow ?: return null
    val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
    return if (focused != null && focused.isEditable) focused else null
  }

  private fun copyToClipboard(text: String) {
    val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText("dictation", text))
  }

  companion object {
    @Volatile
    var instance: FlowBubbleAccessibilityService? = null

    fun isReady(): Boolean = instance != null
  }
}
