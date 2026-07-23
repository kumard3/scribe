import Foundation
import React

@objc(ScribePunctuator)
class ScribePunctuator: NSObject {
  private var punct: OpaquePointer?
  private var loadedModel: String?

  @objc static func requiresMainQueueSetup() -> Bool { return false }

  @objc(isAvailable:rejecter:)
  func isAvailable(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
    resolve(true)
  }

  @objc(addPunctuation:cnnBilstm:bpeVocab:resolver:rejecter:)
  func addPunctuation(
    _ text: String,
    cnnBilstm: String,
    bpeVocab: String,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let out = try self.run(text, self.clean(cnnBilstm), self.clean(bpeVocab))
        resolve(out)
      } catch {
        reject("punctuate_failed", error.localizedDescription, error)
      }
    }
  }

  private func run(_ text: String, _ cnnBilstm: String, _ bpeVocab: String) throws -> String {
    if punct == nil || loadedModel != cnnBilstm {
      if let old = punct { SherpaOnnxDestroyOnlinePunctuation(old); punct = nil }
      let modelC = strdup(cnnBilstm)
      let vocabC = strdup(bpeVocab)
      let provC = strdup("cpu")
      defer { free(modelC); free(vocabC); free(provC) }

      var config = SherpaOnnxOnlinePunctuationConfig()
      config.model.cnn_bilstm = UnsafePointer(modelC)
      config.model.bpe_vocab = UnsafePointer(vocabC)
      config.model.num_threads = 1
      config.model.debug = 0
      config.model.provider = UnsafePointer(provC)

      guard let p = SherpaOnnxCreateOnlinePunctuation(&config) else {
        throw NSError(domain: "ScribePunctuator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not load punctuation model"])
      }
      punct = p
      loadedModel = cnnBilstm
    }

    guard let p = punct else { return text }
    guard let out = SherpaOnnxOnlinePunctuationAddPunct(p, text) else { return text }
    defer { SherpaOnnxOnlinePunctuationFreeText(out) }
    return String(cString: out)
  }

  private func clean(_ path: String) -> String {
    return path.hasPrefix("file://") ? String(path.dropFirst(7)) : path
  }
}
