package ai.localvoice.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import androidx.core.app.NotificationCompat
import kotlin.math.abs

/**
 * A draggable floating "Flow Bubble" overlay (Wispr-style). Tap it to dictate
 * into whatever app is in front; the recognized text is inserted via
 * FlowBubbleAccessibilityService (clipboard fallback if that isn't granted).
 *
 * Runs as a foreground service (microphone type) so dictation keeps working
 * while another app is focused.
 */
class FlowBubbleService : Service(), RecognitionListener {

  private lateinit var windowManager: WindowManager
  private var bubble: TextView? = null
  private var params: WindowManager.LayoutParams? = null
  private var recognizer: SpeechRecognizer? = null
  private var listening = false

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    instance = this
    windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
    startForegroundNotification()
    addBubble()
    // Only float when a text field is focused. If Accessibility is on it drives
    // visibility; otherwise (no focus signal) the bubble stays visible.
    bubble?.visibility =
      if (FlowBubbleAccessibilityService.isReady()) View.GONE else View.VISIBLE
    FlowBubbleAccessibilityService.instance?.syncBubble()
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (intent?.action == ACTION_STOP) {
      stopSelf()
      return START_NOT_STICKY
    }
    return START_STICKY
  }

  override fun onDestroy() {
    stopListening()
    bubble?.let { runCatching { windowManager.removeView(it) } }
    bubble = null
    running = false
    if (instance === this) instance = null
    super.onDestroy()
  }

  /** Shows the bubble only while an editable field is focused (driven by the
   *  AccessibilityService). Stays put while actively dictating. */
  fun setBubbleVisible(visible: Boolean) {
    val b = bubble ?: return
    if (!visible && listening) return
    b.post { b.visibility = if (visible) View.VISIBLE else View.GONE }
  }

  // MARK: overlay

  private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

  private fun addBubble() {
    val size = dp(56)
    val view = TextView(this).apply {
      text = "🎤"
      textSize = 22f
      gravity = Gravity.CENTER
      setTextColor(Color.WHITE)
      background = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(Color.parseColor("#000000"))
        setStroke(dp(2), Color.parseColor("#2A2A2E"))
      }
    }
    val lp = WindowManager.LayoutParams(
      size,
      size,
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
      else
        @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
      WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
      PixelFormat.TRANSLUCENT,
    ).apply {
      gravity = Gravity.TOP or Gravity.START
      x = dp(16)
      y = dp(200)
    }

    attachDrag(view, lp)
    windowManager.addView(view, lp)
    bubble = view
    params = lp
    running = true
  }

  private fun attachDrag(view: View, lp: WindowManager.LayoutParams) {
    var startX = 0
    var startY = 0
    var touchX = 0f
    var touchY = 0f
    var moved = false
    view.setOnTouchListener { _, event ->
      when (event.action) {
        MotionEvent.ACTION_DOWN -> {
          startX = lp.x
          startY = lp.y
          touchX = event.rawX
          touchY = event.rawY
          moved = false
          true
        }
        MotionEvent.ACTION_MOVE -> {
          val dx = (event.rawX - touchX).toInt()
          val dy = (event.rawY - touchY).toInt()
          if (abs(dx) > dp(6) || abs(dy) > dp(6)) moved = true
          lp.x = startX + dx
          lp.y = startY + dy
          runCatching { windowManager.updateViewLayout(view, lp) }
          true
        }
        MotionEvent.ACTION_UP -> {
          if (!moved) toggle()
          true
        }
        else -> false
      }
    }
  }

  private fun setBubbleListening(on: Boolean) {
    bubble?.apply {
      text = if (on) "●" else "🎤"
      (background as? GradientDrawable)?.setColor(
        Color.parseColor(if (on) "#FF453A" else "#000000")
      )
    }
  }

  // MARK: dictation

  private fun toggle() {
    if (listening) stopListening() else startListening()
  }

  private fun startListening() {
    if (!SpeechRecognizer.isRecognitionAvailable(this)) return
    val onDevice = Build.VERSION.SDK_INT >= 33 &&
      SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
    recognizer?.destroy()
    recognizer = if (onDevice && Build.VERSION.SDK_INT >= 31) {
      SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
    } else {
      SpeechRecognizer.createSpeechRecognizer(this)
    }
    recognizer?.setRecognitionListener(this)
    listening = true
    setBubbleListening(true)
    recognizer?.startListening(recognizeIntent())
  }

  private fun stopListening() {
    listening = false
    setBubbleListening(false)
    recognizer?.stopListening()
    recognizer?.destroy()
    recognizer = null
  }

  private fun recognizeIntent(): Intent =
    Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
      putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
      putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
      putExtra(RecognizerIntent.EXTRA_LANGUAGE, resources.configuration.locales[0].toLanguageTag())
      if (Build.VERSION.SDK_INT >= 33 &&
        SpeechRecognizer.isOnDeviceRecognitionAvailable(this@FlowBubbleService)
      ) {
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
      }
    }

  override fun onResults(results: Bundle) {
    val text = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
    if (!text.isNullOrBlank()) {
      FlowBubbleAccessibilityService.instance?.insertText(text)
        ?: copyOnly(text)
    }
    // keep going until the user taps to stop
    if (listening) recognizer?.startListening(recognizeIntent())
  }

  override fun onError(error: Int) {
    when (error) {
      SpeechRecognizer.ERROR_NO_MATCH,
      SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
        if (listening) recognizer?.startListening(recognizeIntent())
      else -> if (listening) stopListening()
    }
  }

  private fun copyOnly(text: String) {
    val cm = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
    cm.setPrimaryClip(android.content.ClipData.newPlainText("dictation", text))
  }

  override fun onReadyForSpeech(params: Bundle?) {}
  override fun onBeginningOfSpeech() {}
  override fun onRmsChanged(rmsdB: Float) {}
  override fun onBufferReceived(buffer: ByteArray?) {}
  override fun onEndOfSpeech() {}
  override fun onPartialResults(partialResults: Bundle) {}
  override fun onEvent(eventType: Int, params: Bundle?) {}

  // MARK: foreground notification

  private fun startForegroundNotification() {
    val channelId = "flow_bubble"
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
      if (nm.getNotificationChannel(channelId) == null) {
        nm.createNotificationChannel(
          NotificationChannel(channelId, "Flow Bubble", NotificationManager.IMPORTANCE_LOW)
        )
      }
    }
    val notification = NotificationCompat.Builder(this, channelId)
      .setContentTitle("Scribe Flow Bubble")
      .setContentText("Tap the bubble to dictate into any app")
      .setSmallIcon(android.R.drawable.ic_btn_speak_now)
      .setOngoing(true)
      .build()

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
    } else {
      startForeground(NOTIF_ID, notification)
    }
  }

  companion object {
    const val ACTION_STOP = "ai.localvoice.app.FLOW_BUBBLE_STOP"
    private const val NOTIF_ID = 4201

    @Volatile
    var running = false

    @Volatile
    var instance: FlowBubbleService? = null
  }
}
