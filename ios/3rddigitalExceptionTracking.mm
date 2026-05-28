#import "3rddigitalExceptionTracking.h"

@implementation 3rddigitalExceptionTracking
- (NSNumber *)multiply:(double)a b:(double)b {
    NSNumber *result = @(a * b);

    return result;
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::Native3rddigitalExceptionTrackingSpecJSI>(params);
}

+ (NSString *)moduleName
{
  return @"3rddigitalExceptionTracking";
}

@end
