#ifdef RCT_NEW_ARCH_ENABLED
  #import <ThirdDigitalExceptionTrackingSpec/ThirdDigitalExceptionTrackingSpec.h>
#else
  #import <React/RCTBridgeModule.h>
#endif

#ifdef RCT_NEW_ARCH_ENABLED
@interface ThirdDigitalExceptionTracking : NSObject <NativeReactNativeExceptionHandlerSpec>
#else
@interface ThirdDigitalExceptionTracking : NSObject <RCTBridgeModule>
#endif

@end
