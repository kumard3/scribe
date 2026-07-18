package ai.localvoice.app

import android.content.Intent
import android.os.Build
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.modules.core.DeviceEventManagerModule

/**
 * JS control surface for the long-form background recorder (RecorderService).
 * Emits "ScribeRecorderLevel" { rms } so the waveform animates while recording.
 */
class RecorderModule(private val reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {

  init {
    instance = this
  }

  override fun getName(): String = "ScribeRecorder"

  override fun invalidate() {
    if (instance === this) instance = null
    super.invalidate()
  }

  @ReactMethod
  fun start(promise: Promise) {
    try {
      val intent = Intent(reactContext, RecorderService::class.java)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        reactContext.startForegroundService(intent)
      } else {
        reactContext.startService(intent)
      }
      promise.resolve(true)
    } catch (e: Throwable) {
      promise.reject("record_start_failed", e.message, e)
    }
  }

  @ReactMethod
  fun pause(promise: Promise) {
    RecorderService.instance?.setPaused(true)
    promise.resolve(true)
  }

  @ReactMethod
  fun resume(promise: Promise) {
    RecorderService.instance?.setPaused(false)
    promise.resolve(true)
  }

  @ReactMethod
  fun stop(promise: Promise) {
    val svc = RecorderService.instance
    if (svc == null) {
      promise.resolve(null)
      return
    }
    Thread {
      val path = runCatching { svc.stopAndFinalize() }.getOrNull()
      runCatching { reactContext.stopService(Intent(reactContext, RecorderService::class.java)) }
      if (path != null) promise.resolve("file://$path")
      else promise.reject("record_no_audio", "No audio was captured")
    }.start()
  }

  @ReactMethod
  fun cancel(promise: Promise) {
    RecorderService.instance?.cancelCapture()
    runCatching { reactContext.stopService(Intent(reactContext, RecorderService::class.java)) }
    promise.resolve(null)
  }

  @ReactMethod
  fun isRecording(promise: Promise) {
    promise.resolve(RecorderService.active)
  }

  @ReactMethod
  fun addListener(eventName: String) {}

  @ReactMethod
  fun removeListeners(count: Double) {}

  companion object {
    @Volatile
    private var instance: RecorderModule? = null

    fun emitLevel(rms: Double) {
      val m = instance ?: return
      if (!m.reactContext.hasActiveReactInstance()) return
      val payload = Arguments.createMap().apply { putDouble("rms", rms) }
      runCatching {
        m.reactContext
          .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
          .emit("ScribeRecorderLevel", payload)
      }
    }
  }
}
