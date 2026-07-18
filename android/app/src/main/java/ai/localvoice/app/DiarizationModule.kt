package ai.localvoice.app

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.k2fsa.sherpa.onnx.FastClusteringConfig
import com.k2fsa.sherpa.onnx.OfflineSpeakerDiarization
import com.k2fsa.sherpa.onnx.OfflineSpeakerDiarizationConfig
import com.k2fsa.sherpa.onnx.OfflineSpeakerSegmentationModelConfig
import com.k2fsa.sherpa.onnx.OfflineSpeakerSegmentationPyannoteModelConfig
import com.k2fsa.sherpa.onnx.SpeakerEmbeddingExtractorConfig
import java.io.RandomAccessFile

/**
 * On-device speaker diarization. Calls the official sherpa-onnx
 * OfflineSpeakerDiarization (pyannote segmentation + speaker-embedding +
 * clustering). The classes + libsherpa-onnx-jni.so already ship in the app via
 * react-native-sherpa-onnx; this module only needs them on the compile
 * classpath (compileOnly in app/build.gradle).
 */
class DiarizationModule(reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {

  private var sd: OfflineSpeakerDiarization? = null
  private var loadedKey: String? = null

  override fun getName(): String = "ScribeDiarizer"

  @ReactMethod
  fun isAvailable(promise: Promise) {
    promise.resolve(true)
  }

  @ReactMethod
  fun diarize(
    wavPath: String,
    segModel: String,
    embModel: String,
    numSpeakers: Int,
    threshold: Double,
    promise: Promise,
  ) {
    Thread {
      try {
        val key = "$segModel|$embModel"
        if (sd == null || loadedKey != key) {
          sd?.let { runCatching { it.release() } }
          val config = OfflineSpeakerDiarizationConfig(
            segmentation = OfflineSpeakerSegmentationModelConfig(
              pyannote = OfflineSpeakerSegmentationPyannoteModelConfig(model = clean(segModel)),
              numThreads = 2,
              debug = false,
              provider = "cpu",
            ),
            embedding = SpeakerEmbeddingExtractorConfig(
              model = clean(embModel),
              numThreads = 2,
              debug = false,
              provider = "cpu",
            ),
            clustering = FastClusteringConfig(
              numClusters = if (numSpeakers > 0) numSpeakers else -1,
              threshold = if (threshold > 0) threshold.toFloat() else 0.5f,
            ),
            minDurationOn = 0.3f,
            minDurationOff = 0.5f,
          )
          sd = OfflineSpeakerDiarization(null, config)
          loadedKey = key
        }
        val engine = sd!!
        val samples = readWav(clean(wavPath), engine.sampleRate())
        val segments = engine.process(samples)
        val arr = Arguments.createArray()
        for (s in segments) {
          arr.pushMap(
            Arguments.createMap().apply {
              putDouble("start", s.start.toDouble())
              putDouble("end", s.end.toDouble())
              putInt("speaker", s.speaker)
            }
          )
        }
        promise.resolve(arr)
      } catch (e: Throwable) {
        promise.reject("diarize_failed", e.message, e)
      }
    }.start()
  }

  private fun clean(path: String): String = path.removePrefix("file://")

  /** Reads a PCM-16 WAV into a mono float array at the target sample rate. */
  private fun readWav(path: String, targetRate: Int): FloatArray {
    RandomAccessFile(path, "r").use { f ->
      val header = ByteArray(12)
      f.readFully(header)
      var sampleRate = 16000
      var channels = 1
      var bits = 16
      var dataOffset = -1L
      var dataLen = 0L
      while (f.filePointer < f.length() - 8) {
        val id = ByteArray(4)
        f.readFully(id)
        val size = readU32(f)
        val chunk = String(id, Charsets.US_ASCII)
        if (chunk == "fmt ") {
          val fmt = ByteArray(size.toInt())
          f.readFully(fmt)
          channels = (fmt[2].toInt() and 0xff) or ((fmt[3].toInt() and 0xff) shl 8)
          sampleRate = le32(fmt, 4)
          bits = (fmt[14].toInt() and 0xff) or ((fmt[15].toInt() and 0xff) shl 8)
        } else if (chunk == "data") {
          dataOffset = f.filePointer
          dataLen = size
          break
        } else {
          f.seek(f.filePointer + size + (size and 1))
        }
      }
      if (dataOffset < 0) return FloatArray(0)
      f.seek(dataOffset)
      val bytesPerSample = bits / 8
      val frameBytes = bytesPerSample * channels
      val frames = (dataLen / frameBytes).toInt()
      val raw = ByteArray(dataLen.toInt())
      f.readFully(raw)
      val mono = FloatArray(frames)
      var p = 0
      for (i in 0 until frames) {
        var acc = 0.0
        for (c in 0 until channels) {
          val lo = raw[p].toInt() and 0xff
          val hi = raw[p + 1].toInt()
          val s = (hi shl 8) or lo
          acc += s / 32768.0
          p += bytesPerSample
        }
        mono[i] = (acc / channels).toFloat()
      }
      return if (sampleRate == targetRate) mono else resample(mono, sampleRate, targetRate)
    }
  }

  private fun resample(input: FloatArray, inRate: Int, outRate: Int): FloatArray {
    if (inRate == outRate || input.isEmpty()) return input
    val ratio = inRate.toDouble() / outRate
    val outLen = maxOf(1, (input.size / ratio).toInt())
    val out = FloatArray(outLen)
    for (i in 0 until outLen) {
      val pos = i * ratio
      val i0 = pos.toInt()
      val i1 = if (i0 + 1 < input.size) i0 + 1 else i0
      val frac = (pos - i0).toFloat()
      out[i] = input[i0] * (1 - frac) + input[i1] * frac
    }
    return out
  }

  private fun readU32(f: RandomAccessFile): Long {
    val b = ByteArray(4)
    f.readFully(b)
    return (b[0].toLong() and 0xff) or
      ((b[1].toLong() and 0xff) shl 8) or
      ((b[2].toLong() and 0xff) shl 16) or
      ((b[3].toLong() and 0xff) shl 24)
  }

  private fun le32(b: ByteArray, off: Int): Int =
    (b[off].toInt() and 0xff) or
      ((b[off + 1].toInt() and 0xff) shl 8) or
      ((b[off + 2].toInt() and 0xff) shl 16) or
      ((b[off + 3].toInt() and 0xff) shl 24)
}
