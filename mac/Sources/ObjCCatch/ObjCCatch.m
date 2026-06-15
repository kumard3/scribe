#import "include/ObjCCatch.h"

NSException * _Nullable ScribeTryCatch(void (NS_NOESCAPE ^block)(void)) {
  @try {
    block();
  } @catch (NSException *e) {
    return e;
  }
  return nil;
}
