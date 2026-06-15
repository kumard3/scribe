#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block, returning the NSException if one is raised (Swift cannot
/// catch ObjC exceptions, e.g. from AVAudioEngine installTap).
NSException * _Nullable ScribeTryCatch(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
