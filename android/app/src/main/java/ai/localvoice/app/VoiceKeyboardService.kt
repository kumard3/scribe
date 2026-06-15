package ai.localvoice.app

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PorterDuff
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * On-screen keyboard styled to match Gboard's dark theme (key-borders on):
 * boxed keys with dim corner hints, taller keys with generous spacing, an emoji
 * layer, a slim toolbar carrying a standard mic on the right. The mic dictates
 * via SpeechRecognizer.
 */
class VoiceKeyboardService : InputMethodService(), RecognitionListener {
  private var recognizer: SpeechRecognizer? = null
  private var listening = false

  private lateinit var micButton: ImageButton
  private lateinit var status: TextView
  private lateinit var keys: LinearLayout

  private var shift = 0 // 0 = off, 1 = one-shot, 2 = caps lock
  private var symbols = false
  private var emoji = false

  private val letterRows = listOf(
    listOf("q", "w", "e", "r", "t", "y", "u", "i", "o", "p"),
    listOf("a", "s", "d", "f", "g", "h", "j", "k", "l"),
    listOf("z", "x", "c", "v", "b", "n", "m"),
  )
  private val symbolRows = listOf(
    listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "0"),
    listOf("@", "#", "$", "_", "&", "-", "+", "(", ")", "/"),
    listOf("*", "\"", "'", ":", ";", "!", "?"),
  )
  private val emojiSet = listOf(
    "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣",
    "😊", "🙂", "😉", "😍", "🥰", "😘", "😎", "🤔",
    "😴", "😭", "😡", "🥺", "😱", "🤯", "😏", "😋",
    "👍", "👎", "👌", "🙏", "👏", "💪", "🔥", "❤️",
  )

  // Gboard-dark palette (borders on): keyboard surface darker than the key
  // boxes; letter keys lighter than the function keys.
  private val bg = Color.parseColor("#202024")
  private val charBox = Color.parseColor("#3E3E44")
  private val funcBox = Color.parseColor("#2C2C32")
  private val caps = Color.parseColor("#5A5A62")
  private val pressed = Color.parseColor("#55555E")
  private val keyText = Color.parseColor("#F1F1F3")
  private val hintText = Color.parseColor("#9A9AA0")
  private val dim = Color.parseColor("#B0B0B6")
  private val recording = Color.parseColor("#FF453A")

  private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

  override fun onCreateInputView(): View {
    val root = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      layoutParams = ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
      )
      setBackgroundColor(bg)
      setPadding(dp(4), dp(5), dp(4), dp(10) + navBarHeight())
    }
    root.addView(buildToolbar())

    keys = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    root.addView(keys)
    renderKeys()

    // Keep the keys clear of the gesture-nav strip so the bottom row doesn't
    // overflow into the system hide/switch buttons.
    root.setOnApplyWindowInsetsListener { v, insets ->
      val nav = if (Build.VERSION.SDK_INT >= 30) {
        insets.getInsets(WindowInsets.Type.navigationBars()).bottom
      } else {
        @Suppress("DEPRECATION") insets.systemWindowInsetBottom
      }
      v.setPadding(dp(4), dp(5), dp(4), dp(10) + maxOf(nav, dp(8)))
      insets
    }
    return root
  }

  private fun navBarHeight(): Int {
    val id = resources.getIdentifier("navigation_bar_height", "dimen", "android")
    return if (id > 0) resources.getDimensionPixelSize(id) else dp(28)
  }

  override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
    super.onStartInputView(info, restarting)
    shift = 0
    symbols = false
    emoji = false
    renderKeys()
  }

  // Slim toolbar: language switch on the left, partial dictation text in the
  // middle, a standard mic icon on the right — both icons monochrome.
  private fun buildToolbar(): View {
    val bar = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }

    val globe = ImageButton(this).apply {
      setImageResource(R.drawable.ic_globe)
      setColorFilter(dim, PorterDuff.Mode.SRC_IN)
      setBackgroundColor(Color.TRANSPARENT)
      scaleType = ImageView.ScaleType.CENTER_INSIDE
      setPadding(dp(9), dp(9), dp(9), dp(9))
      setOnClickListener { showKeyboardPicker() }
      layoutParams = LinearLayout.LayoutParams(dp(46), dp(44))
    }
    bar.addView(globe)

    status = TextView(this).apply {
      text = ""
      setTextColor(dim)
      textSize = 13f
      gravity = Gravity.CENTER_VERTICAL
      maxLines = 1
      ellipsize = android.text.TextUtils.TruncateAt.END
      layoutParams = LinearLayout.LayoutParams(0, dp(44), 1f).apply { marginStart = dp(6) }
    }
    bar.addView(status)

    micButton = ImageButton(this).apply {
      setImageResource(R.drawable.ic_mic)
      setColorFilter(dim, PorterDuff.Mode.SRC_IN)
      setBackgroundColor(Color.TRANSPARENT)
      scaleType = ImageView.ScaleType.CENTER_INSIDE
      setPadding(dp(9), dp(9), dp(9), dp(9))
      setOnClickListener { toggle() }
      layoutParams = LinearLayout.LayoutParams(dp(48), dp(44))
    }
    bar.addView(micButton)
    return bar
  }

  private fun renderKeys() {
    keys.removeAllViews()
    if (emoji) { renderEmojis(); return }

    val rows = if (symbols) symbolRows else letterRows
    val hints = if (symbols) listOf<List<String>?>(null, null, null) else symbolRows

    keys.addView(rowOf(rows[0].mapIndexed { i, c -> charKey(c, hints[0]?.getOrNull(i)) }))

    val mid = ArrayList<View>()
    mid.add(spacer(0.5f))
    rows[1].forEachIndexed { i, c -> mid.add(charKey(c, hints[1]?.getOrNull(i))) }
    mid.add(spacer(0.5f))
    keys.addView(rowOf(mid))

    val low = ArrayList<View>()
    if (symbols) low.add(spacer(1.5f)) else low.add(shiftKey())
    rows[2].forEachIndexed { i, c -> low.add(charKey(c, hints[2]?.getOrNull(i))) }
    low.add(funcKey("⌫", 1.5f) { backspace() })
    keys.addView(rowOf(low))

    val bottom = ArrayList<View>()
    bottom.add(funcKey(if (symbols) "ABC" else "?123", 1.5f) { symbols = !symbols; renderKeys() })
    bottom.add(punctKey(","))
    bottom.add(funcKey("☺", 1f) { emoji = true; renderKeys() })
    bottom.add(spaceKey(4f))
    bottom.add(punctKey("."))
    bottom.add(funcKey("⏎", 1.5f) { onEnter() })
    keys.addView(rowOf(bottom))
  }

  private fun renderEmojis() {
    emojiSet.chunked(8).forEach { row ->
      keys.addView(rowOf(row.map { emojiKey(it) }))
    }
    val ctrl = ArrayList<View>()
    ctrl.add(funcKey("ABC", 1.5f) { emoji = false; renderKeys() })
    ctrl.add(spaceKey(5f))
    ctrl.add(funcKey("⌫", 1.5f) { backspace() })
    keys.addView(rowOf(ctrl))
  }

  private fun rowOf(children: List<View>): LinearLayout =
    LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      children.forEach { addView(it) }
    }

  private fun rounded(color: Int): GradientDrawable =
    GradientDrawable().apply { cornerRadius = dp(9).toFloat(); setColor(color) }

  private fun keyBackground(normal: Int): StateListDrawable =
    StateListDrawable().apply {
      addState(intArrayOf(android.R.attr.state_pressed), rounded(pressed))
      addState(intArrayOf(), rounded(normal))
    }

  private fun cell(
    label: String,
    weight: Float,
    fill: Int,
    textColor: Int,
    hint: String? = null,
    textSizeSp: Float? = null,
    onTap: () -> Unit,
    onLong: (() -> Unit)? = null,
  ): View {
    val frame = FrameLayout(this).apply {
      background = keyBackground(fill)
      isClickable = true
      isFocusable = true
      layoutParams = LinearLayout.LayoutParams(0, dp(56), weight).apply {
        marginStart = dp(3); marginEnd = dp(3); topMargin = dp(7)
      }
      setOnClickListener { onTap() }
      if (onLong != null) setOnLongClickListener { onLong(); true }
    }
    frame.addView(TextView(this).apply {
      text = label
      setTextColor(textColor)
      textSize = textSizeSp ?: if (label.length > 1) 14f else 22f
      typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
      gravity = Gravity.CENTER
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      )
    })
    if (hint != null) {
      frame.addView(TextView(this).apply {
        text = hint
        setTextColor(hintText)
        textSize = 10f
        layoutParams = FrameLayout.LayoutParams(
          FrameLayout.LayoutParams.WRAP_CONTENT,
          FrameLayout.LayoutParams.WRAP_CONTENT,
        ).apply { gravity = Gravity.TOP or Gravity.END; topMargin = dp(4); marginEnd = dp(8) }
      })
    }
    return frame
  }

  private fun charKey(base: String, hint: String?): View {
    val display = if (!symbols && shift > 0) base.uppercase() else base
    return cell(
      display, 1f, charBox, keyText, hint = hint,
      onTap = {
        commit(if (!symbols && shift > 0) base.uppercase() else base)
        if (!symbols && shift == 1) { shift = 0; renderKeys() }
      },
      onLong = if (hint != null) ({ commit(hint) }) else null,
    )
  }

  private fun punctKey(ch: String): View =
    cell(ch, 1f, charBox, keyText, onTap = { commit(ch) })

  private fun emojiKey(e: String): View =
    cell(e, 1f, charBox, keyText, textSizeSp = 21f, onTap = { commit(e) })

  private fun spaceKey(weight: Float): View =
    cell("", weight, charBox, dim, onTap = { commit(" ") })

  private fun funcKey(label: String, weight: Float, onTap: () -> Unit): View =
    cell(label, weight, funcBox, keyText, onTap = onTap)

  // Shift stays a calm dark key (never a solid white block): the glyph brightens
  // when active and the fill lifts slightly for caps-lock.
  private fun shiftKey(): View {
    val glyph = if (shift == 2) "⇪" else "⇧"
    val color = if (shift > 0) keyText else dim
    val fill = if (shift == 2) caps else funcBox
    return cell(glyph, 1.5f, fill, color, onTap = { toggleShift() })
  }

  private fun spacer(weight: Float): View =
    View(this).apply { layoutParams = LinearLayout.LayoutParams(0, dp(56), weight) }

  private fun toggleShift() {
    shift = when (shift) { 0 -> 1; 1 -> 2; else -> 0 }
    renderKeys()
  }

  private fun onEnter() {
    val info = currentInputEditorInfo
    val action = (info?.imeOptions ?: 0) and EditorInfo.IME_MASK_ACTION
    val noAction = ((info?.imeOptions ?: 0) and EditorInfo.IME_FLAG_NO_ENTER_ACTION) != 0
    if (!noAction && action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED) {
      sendDefaultEditorAction(true)
    } else {
      commit("\n")
    }
  }

  // MARK: dictation

  private fun toggle() {
    if (listening) stopListening() else startListening()
  }

  private fun startListening() {
    if (!SpeechRecognizer.isRecognitionAvailable(this)) {
      status.text = "Speech recognition unavailable on this device"
      return
    }
    val onDevice = Build.VERSION.SDK_INT >= 33 && SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
    recognizer?.destroy()
    recognizer = if (onDevice && Build.VERSION.SDK_INT >= 31) {
      SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
    } else {
      SpeechRecognizer.createSpeechRecognizer(this)
    }
    recognizer?.setRecognitionListener(this)
    listening = true
    micButton.setColorFilter(recording, PorterDuff.Mode.SRC_IN)
    status.text = if (onDevice) "Listening · on-device" else "Listening"
    recognizer?.startListening(recognizeIntent())
  }

  private fun stopListening() {
    listening = false
    micButton.setColorFilter(dim, PorterDuff.Mode.SRC_IN)
    status.text = ""
    recognizer?.stopListening()
    recognizer?.destroy()
    recognizer = null
  }

  private fun commit(text: String) {
    currentInputConnection?.commitText(text, 1)
  }

  private fun backspace() {
    val selected = currentInputConnection?.getSelectedText(0)
    if (!selected.isNullOrEmpty()) currentInputConnection?.commitText("", 1)
    else currentInputConnection?.deleteSurroundingText(1, 0)
  }

  private fun showKeyboardPicker() {
    (getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager)?.showInputMethodPicker()
  }

  override fun onFinishInput() {
    super.onFinishInput()
    if (listening) stopListening()
  }

  override fun onDestroy() {
    recognizer?.destroy()
    recognizer = null
    super.onDestroy()
  }

  override fun onResults(results: Bundle) {
    val text = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
    if (!text.isNullOrBlank()) commit(needsLeadingSpace(text))
    if (listening) recognizer?.startListening(recognizeIntent())
  }

  override fun onPartialResults(partialResults: Bundle) {
    val text = partialResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
    if (!text.isNullOrBlank()) status.text = text
  }

  override fun onError(error: Int) {
    when (error) {
      SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
        listening = false
        micButton.setColorFilter(dim, PorterDuff.Mode.SRC_IN)
        status.text = "Open the Scribe app and allow the microphone"
      }
      SpeechRecognizer.ERROR_NO_MATCH,
      SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> {
        if (listening) recognizer?.startListening(recognizeIntent())
      }
      else -> {
        if (listening) stopListening()
      }
    }
  }

  private fun recognizeIntent(): Intent =
    Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
      putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
      putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
      putExtra(RecognizerIntent.EXTRA_LANGUAGE, resources.configuration.locales[0].toLanguageTag())
      if (Build.VERSION.SDK_INT >= 33 && SpeechRecognizer.isOnDeviceRecognitionAvailable(this@VoiceKeyboardService)) {
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
      }
    }

  private fun needsLeadingSpace(text: String): String {
    val before = currentInputConnection?.getTextBeforeCursor(1, 0)
    val needsSpace = !before.isNullOrEmpty() && before.last() != ' ' && before.last() != '\n'
    return if (needsSpace) " $text" else text
  }

  override fun onReadyForSpeech(params: Bundle?) {}
  override fun onBeginningOfSpeech() {}
  override fun onRmsChanged(rmsdB: Float) {}
  override fun onBufferReceived(buffer: ByteArray?) {}
  override fun onEndOfSpeech() {}
  override fun onEvent(eventType: Int, params: Bundle?) {}
}
