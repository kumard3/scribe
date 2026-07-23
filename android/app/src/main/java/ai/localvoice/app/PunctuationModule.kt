package ai.localvoice.app

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.k2fsa.sherpa.onnx.OnlinePunctuation
import com.k2fsa.sherpa.onnx.OnlinePunctuationConfig
import com.k2fsa.sherpa.onnx.OnlinePunctuationModelConfig

/**
 * On-device punctuation restoration for engines that emit unpunctuated text
 * (CTC/streaming: Parakeet-CTC, Zipformer, Moonshine, the system engine). Wraps
 * the sherpa-onnx OnlinePunctuation CT-CNN-BiLSTM model. Classes ship via
 * react-native-sherpa-onnx (compileOnly here, same as DiarizationModule).
 */
class PunctuationModule(reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {

  private var punct: OnlinePunctuation? = null
  private var loadedModel: String? = null

  override fun getName(): String = "ScribePunctuator"

  @ReactMethod
  fun isAvailable(promise: Promise) {
    promise.resolve(true)
  }

  @ReactMethod
  fun addPunctuation(text: String, cnnBilstm: String, bpeVocab: String, promise: Promise) {
    Thread {
      try {
        if (punct == null || loadedModel != cnnBilstm) {
          punct?.let { runCatching { it.release() } }
          val config = OnlinePunctuationConfig(
            model = OnlinePunctuationModelConfig(
              cnnBilstm = clean(cnnBilstm),
              bpeVocab = clean(bpeVocab),
              numThreads = 1,
              debug = false,
              provider = "cpu",
            )
          )
          punct = OnlinePunctuation(null, config)
          loadedModel = cnnBilstm
        }
        promise.resolve(punct!!.addPunctuation(text))
      } catch (e: Throwable) {
        promise.reject("punctuate_failed", e.message, e)
      }
    }.start()
  }

  private fun clean(path: String): String = path.removePrefix("file://")
}
