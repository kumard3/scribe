package ai.localvoice.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Long-form recorder for Record Mode. Runs as a foreground service (microphone
 * type) so capture survives the screen turning off / the app going to the
 * background. PCM is streamed straight to a 16 kHz mono WAV file on disk so a
 * long meeting can't run the JS heap out of memory the way the in-RAM
 * useAudioStream path does.
 */
class RecorderService : Service() {

  private var thread: Thread? = null
  @Volatile private var capturing = false
  @Volatile private var paused = false
  private var raf: RandomAccessFile? = null
  private var outFile: File? = null
  private var dataBytes = 0L

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    instance = this
    startForegroundNotification()
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (intent?.action == ACTION_STOP) {
      stopSelf()
      return START_NOT_STICKY
    }
    if (!capturing) startCapture()
    return START_STICKY
  }

  override fun onDestroy() {
    finalizeFile()
    if (instance === this) instance = null
    active = false
    super.onDestroy()
  }

  fun setPaused(value: Boolean) {
    paused = value
  }

  /** Stops capture, patches the WAV header sizes, returns the file path. */
  fun stopAndFinalize(): String? {
    val path = outFile?.absolutePath
    finalizeFile()
    return path
  }

  fun cancelCapture() {
    capturing = false
    thread?.let { runCatching { it.join(2000) } }
    thread = null
    runCatching { raf?.close() }
    raf = null
    outFile?.let { runCatching { it.delete() } }
    outFile = null
  }

  private fun startCapture() {
    val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
    val bufSize = max(minBuf, SAMPLE_RATE) // ~0.5s of int16
    val recorder = AudioRecord(
      MediaRecorder.AudioSource.VOICE_RECOGNITION,
      SAMPLE_RATE,
      AudioFormat.CHANNEL_IN_MONO,
      AudioFormat.ENCODING_PCM_16BIT,
      bufSize,
    )
    if (recorder.state != AudioRecord.STATE_INITIALIZED) {
      recorder.release()
      return
    }

    val dir = File(cacheDir, "rec").apply { mkdirs() }
    val file = File(dir, "scribe-record-${System.currentTimeMillis()}.wav")
    val r = RandomAccessFile(file, "rw")
    r.setLength(0)
    r.write(wavHeader(0))
    dataBytes = 0
    raf = r
    outFile = file
    capturing = true
    active = true
    paused = false

    recorder.startRecording()
    thread = Thread {
      val buf = ShortArray(bufSize)
      val bytes = ByteArray(bufSize * 2)
      while (capturing) {
        if (paused) {
          Thread.sleep(40)
          continue
        }
        val n = recorder.read(buf, 0, buf.size)
        if (n <= 0) continue
        var sum = 0.0
        for (i in 0 until n) {
          val s = buf[i].toInt()
          bytes[i * 2] = (s and 0xff).toByte()
          bytes[i * 2 + 1] = ((s shr 8) and 0xff).toByte()
          val f = s / 32768.0
          sum += f * f
        }
        runCatching {
          raf?.write(bytes, 0, n * 2)
          dataBytes += n * 2
        }
        RecorderModule.emitLevel(sqrt(sum / n))
      }
      runCatching {
        recorder.stop()
        recorder.release()
      }
    }
    thread!!.start()
  }

  private fun finalizeFile() {
    capturing = false
    thread?.let { runCatching { it.join(2500) } }
    thread = null
    raf?.let { r ->
      runCatching {
        r.seek(0)
        r.write(wavHeader(dataBytes))
        r.close()
      }
    }
    raf = null
    active = false
  }

  private fun wavHeader(dataLen: Long): ByteArray {
    val byteRate = SAMPLE_RATE * 1 * 16 / 8
    val out = ByteArray(44)
    fun str(off: Int, s: String) { for (i in s.indices) out[off + i] = s[i].code.toByte() }
    fun u32(off: Int, v: Long) {
      out[off] = (v and 0xff).toByte()
      out[off + 1] = ((v shr 8) and 0xff).toByte()
      out[off + 2] = ((v shr 16) and 0xff).toByte()
      out[off + 3] = ((v shr 24) and 0xff).toByte()
    }
    fun u16(off: Int, v: Int) {
      out[off] = (v and 0xff).toByte()
      out[off + 1] = ((v shr 8) and 0xff).toByte()
    }
    str(0, "RIFF"); u32(4, 36 + dataLen); str(8, "WAVE")
    str(12, "fmt "); u32(16, 16); u16(20, 1); u16(22, 1)
    u32(24, SAMPLE_RATE.toLong()); u32(28, byteRate.toLong()); u16(32, 2); u16(34, 16)
    str(36, "data"); u32(40, dataLen)
    return out
  }

  private fun startForegroundNotification() {
    val channelId = "scribe_record"
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
      if (nm.getNotificationChannel(channelId) == null) {
        nm.createNotificationChannel(
          NotificationChannel(channelId, "Recording", NotificationManager.IMPORTANCE_LOW)
        )
      }
    }
    val tapIntent = packageManager.getLaunchIntentForPackage(packageName)
    val pi = tapIntent?.let {
      PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }
    val notification = NotificationCompat.Builder(this, channelId)
      .setContentTitle("Scribe is recording")
      .setContentText("Recording continues in the background. Tap to return.")
      .setSmallIcon(android.R.drawable.ic_btn_speak_now)
      .setOngoing(true)
      .also { if (pi != null) it.setContentIntent(pi) }
      .build()

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
    } else {
      startForeground(NOTIF_ID, notification)
    }
  }

  companion object {
    const val ACTION_STOP = "ai.localvoice.app.RECORDER_STOP"
    private const val NOTIF_ID = 4301
    private const val SAMPLE_RATE = 16000

    @Volatile
    var active = false

    @Volatile
    var instance: RecorderService? = null
  }
}
