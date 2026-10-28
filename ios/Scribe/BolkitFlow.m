#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(BolkitFlow, NSObject)

RCT_EXTERN_METHOD(end)

RCT_EXTERN_METHOD(status:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end
