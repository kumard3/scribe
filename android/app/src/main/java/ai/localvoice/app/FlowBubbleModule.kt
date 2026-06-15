package ai.localvoice.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.text.TextUtils
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod

/**
 * JS control surface for the Flow Bubble: permission checks/prompts and
 * start/stop of the overlay service.
 */
class FlowBubbleModule(private val reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {

  override fun getName(): String = "FlowBubble"

  @ReactMethod
  fun isOverlayGranted(promise: Promise) {
    promise.resolve(Settings.canDrawOverlays(reactContext))
  }

  @ReactMethod
  fun requestOverlayPermission(promise: Promise) {
    try {
      val intent = Intent(
        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
        Uri.parse("package:${reactContext.packageName}"),
      ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      reactContext.startActivity(intent)
      promise.resolve(true)
    } catch (e: Throwable) {
      promise.reject("overlay_request_failed", e.message, e)
    }
  }

  @ReactMethod
  fun isAccessibilityEnabled(promise: Promise) {
    promise.resolve(isAccessibilityServiceEnabled())
  }

  @ReactMethod
  fun openAccessibilitySettings(promise: Promise) {
    try {
      reactContext.startActivity(
        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
          .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      )
      promise.resolve(true)
    } catch (e: Throwable) {
      promise.reject("accessibility_open_failed", e.message, e)
    }
  }

  @ReactMethod
  fun isRunning(promise: Promise) {
    promise.resolve(FlowBubbleService.running)
  }

  @ReactMethod
  fun start(promise: Promise) {
    if (!Settings.canDrawOverlays(reactContext)) {
      promise.reject("no_overlay", "Display-over-other-apps permission not granted")
      return
    }
    try {
      val intent = Intent(reactContext, FlowBubbleService::class.java)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        reactContext.startForegroundService(intent)
      } else {
        reactContext.startService(intent)
      }
      promise.resolve(true)
    } catch (e: Throwable) {
      promise.reject("start_failed", e.message, e)
    }
  }

  @ReactMethod
  fun stop(promise: Promise) {
    try {
      reactContext.stopService(Intent(reactContext, FlowBubbleService::class.java))
      promise.resolve(true)
    } catch (e: Throwable) {
      promise.reject("stop_failed", e.message, e)
    }
  }

  private fun isAccessibilityServiceEnabled(): Boolean {
    val expected = "${reactContext.packageName}/${FlowBubbleAccessibilityService::class.java.name}"
    val enabled = Settings.Secure.getString(
      reactContext.contentResolver,
      Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
    ) ?: return false
    val splitter = TextUtils.SimpleStringSplitter(':')
    splitter.setString(enabled)
    for (component in splitter) {
      if (component.equals(expected, ignoreCase = true)) return true
    }
    return false
  }
}
