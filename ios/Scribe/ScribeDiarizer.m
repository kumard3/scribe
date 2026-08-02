#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(ScribeDiarizer, NSObject)

RCT_EXTERN_METHOD(isAvailable:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(diarize:(NSString *)wavPath
                  segModel:(NSString *)segModel
                  embModel:(NSString *)embModel
                  numSpeakers:(double)numSpeakers
                  threshold:(double)threshold
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end
