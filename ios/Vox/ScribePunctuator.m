#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(ScribePunctuator, NSObject)

RCT_EXTERN_METHOD(isAvailable:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(addPunctuation:(NSString *)text
                  cnnBilstm:(NSString *)cnnBilstm
                  bpeVocab:(NSString *)bpeVocab
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end
