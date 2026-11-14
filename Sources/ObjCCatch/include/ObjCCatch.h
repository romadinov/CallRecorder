#import <Foundation/Foundation.h>

/// Runs `block`; returns NO and fills `error` if it raised an Objective-C exception (AVAudioEngine reports some failures
/// that way, and Swift can't catch them).
BOOL CRCatchException(void (NS_NOESCAPE ^_Nonnull block)(void), NSError * _Nullable * _Nullable error);
