#import "ThirdDigitalExceptionTracking.h"
#import <React/RCTAssert.h>
#import <UIKit/UIKit.h>
#import <execinfo.h>
#import <signal.h>
#import <stdatomic.h>
#import <unistd.h>

static NSString * const RNUncaughtExceptionHandlerSignalExceptionName = @"RNUncaughtExceptionHandlerSignalExceptionName";
static NSString * const RNUncaughtExceptionHandlerSignalKey = @"RNUncaughtExceptionHandlerSignalKey";
static NSString * const RNUncaughtExceptionHandlerAddressesKey = @"RNUncaughtExceptionHandlerAddressesKey";
static NSString * const RNPrefsName = @"react_native_exception_handler";
static NSString * const RNPendingPayloadKey = @"react_native_exception_handler.pendingPayloadJson";
static atomic_int RNUncaughtExceptionCount = 0;
static const int32_t RNUncaughtExceptionMaximum = 10;
static const NSInteger RNUncaughtExceptionHandlerSkipAddressCount = 4;
static const NSInteger RNUncaughtExceptionHandlerReportAddressCount = 5;
static const NSTimeInterval RNUncaughtExceptionHandlerHoldTimeout = 5.0;

static void HandleException(NSException *exception);
static void SignalHandler(int signal);
static void ReportExceptionOnMainThread(NSException *exception);
static NSDictionary *BuildPayload(NSException *exception);
static NSString *StackTraceString(NSException *exception);
static BOOL PostException(NSDictionary *payload);
static BOOL PostExceptionSync(NSDictionary *payload);
static void PersistConfiguration(void);
static void RestoreConfiguration(void);
static void PersistPendingException(NSDictionary *payload);
static void ClearPendingException(void);
static void UploadPendingException(void);
static NSString *IsoTimestamp(void);
static void RemovePrivateFields(NSMutableDictionary *dictionary);
static NSDictionary *BuildMemoryInfo(void);
static NSDictionary *BuildStorageInfo(void);
static NSDictionary *BuildBatteryInfo(void);

@implementation ThirdDigitalExceptionTracking

- (instancetype)init
{
    self = [super init];
    if (self) {
        RestoreConfiguration();
    }
    return self;
}

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}

static NSUncaughtExceptionHandler* previousNativeErrorCallbackBlock;
static RCTFatalHandler previousRCTFatalHandler;
static RCTFatalExceptionHandler previousRCTFatalExceptionHandler;
static BOOL callPreviousNativeErrorCallbackBlock = false;
static void (^jsErrorCallbackBlock)(NSException *exception, NSString *readeableException, NSDictionary *payload, BOOL uploadedByNative);
static BOOL releaseNativeExceptionHold = YES;
static BOOL nativeFallbackEnabled = YES;
static BOOL forceApplicationToQuitAfterHandling = NO;
static NSString *ingestUrl;
static NSString *apiKey;
static NSString *projectKey;
static NSDictionary *headers;
static NSDictionary *basePayload;
static void *lastReportedExceptionPointer;
static BOOL pendingUploadScheduled = NO;
static BOOL nativeHandlersInstalled = NO;
static NSArray<NSString *> *privatePayloadKeys;

RCT_EXPORT_MODULE(ThirdDigitalExceptionTracking);

#ifdef RCT_NEW_ARCH_ENABLED
RCT_EXPORT_METHOD(configureNativeExceptionHandler:(JS::NativeReactNativeExceptionHandler::NativeExceptionHandlerOptions &)options)
{
    if ([options.url() isKindOfClass:[NSString class]]) {
        ingestUrl = options.url();
    }
    if ([options.apiKey() isKindOfClass:[NSString class]]) {
        apiKey = options.apiKey();
    }
    if ([options.projectKey() isKindOfClass:[NSString class]]) {
        projectKey = options.projectKey();
    }
    id headersOption = options.headers();
    if ([headersOption isKindOfClass:[NSDictionary class]]) {
        headers = (NSDictionary *)headersOption;
    }
    id basePayloadOption = options.basePayload();
    if ([basePayloadOption isKindOfClass:[NSDictionary class]]) {
        basePayload = (NSDictionary *)basePayloadOption;
    }
    if (options.executeOriginalHandler().has_value()) {
        callPreviousNativeErrorCallbackBlock = options.executeOriginalHandler().value();
    }
    if (options.nativeFallbackEnabled().has_value()) {
        nativeFallbackEnabled = options.nativeFallbackEnabled().value();
    }
    if (options.forceToQuit().has_value()) {
        forceApplicationToQuitAfterHandling = options.forceToQuit().value();
    }

    PersistConfiguration();
    UploadPendingException();
}
#else
RCT_EXPORT_METHOD(configureNativeExceptionHandler:(NSDictionary *)options)
{
    if ([options[@"url"] isKindOfClass:[NSString class]]) {
        ingestUrl = options[@"url"];
    }
    if ([options[@"apiKey"] isKindOfClass:[NSString class]]) {
        apiKey = options[@"apiKey"];
    }
    if ([options[@"projectKey"] isKindOfClass:[NSString class]]) {
        projectKey = options[@"projectKey"];
    }
    if ([options[@"headers"] isKindOfClass:[NSDictionary class]]) {
        headers = options[@"headers"];
    }
    if ([options[@"basePayload"] isKindOfClass:[NSDictionary class]]) {
        basePayload = options[@"basePayload"];
    }
    if ([options[@"executeOriginalHandler"] isKindOfClass:[NSNumber class]]) {
        callPreviousNativeErrorCallbackBlock = [options[@"executeOriginalHandler"] boolValue];
    }
    if ([options[@"nativeFallbackEnabled"] isKindOfClass:[NSNumber class]]) {
        nativeFallbackEnabled = [options[@"nativeFallbackEnabled"] boolValue];
    }
    if ([options[@"forceToQuit"] isKindOfClass:[NSNumber class]]) {
        forceApplicationToQuitAfterHandling = [options[@"forceToQuit"] boolValue];
    }

    PersistConfiguration();
    UploadPendingException();
}
#endif

RCT_EXPORT_METHOD(setHandlerforNativeException:(BOOL)callPreviouslyDefinedHandler
                  forceApplicationToQuit:(BOOL)forceApplicationToQuit
                  callback:(RCTResponseSenderBlock)callback)
{
    [self setNativeExceptionCallback:callback];

    [self installNativeExceptionHandler:callPreviouslyDefinedHandler
                 forceApplicationToQuit:forceApplicationToQuit];
}

RCT_EXPORT_METHOD(setHandlerforNativeExceptionIOS:(BOOL)callPreviouslyDefinedHandler
                  callback:(RCTResponseSenderBlock)callback)
{
    [self setNativeExceptionCallback:callback];

    [self installNativeExceptionHandler:callPreviouslyDefinedHandler
                 forceApplicationToQuit:NO];
}

RCT_EXPORT_METHOD(setNativeExceptionCallback:(RCTResponseSenderBlock)callback)
{
    jsErrorCallbackBlock = ^(NSException *exception, NSString *readeableException, NSDictionary *payload, BOOL uploadedByNative){
        callback(@[readeableException ?: @"", payload ?: @{}, @(uploadedByNative)]);
    };
}

RCT_EXPORT_METHOD(installNativeExceptionHandler:(BOOL)callPreviouslyDefinedHandler
                  forceApplicationToQuit:(BOOL)forceApplicationToQuit)
{
    callPreviousNativeErrorCallbackBlock = callPreviouslyDefinedHandler;
    forceApplicationToQuitAfterHandling = forceApplicationToQuit;

    if (nativeHandlersInstalled) {
        return;
    }

    previousNativeErrorCallbackBlock = NSGetUncaughtExceptionHandler();
    previousRCTFatalHandler = RCTGetFatalHandler();
    previousRCTFatalExceptionHandler = RCTGetFatalExceptionHandler();
    nativeHandlersInstalled = YES;

    NSSetUncaughtExceptionHandler(&HandleException);
    RCTSetFatalHandler(^(NSError *error) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithDictionary:error.userInfo ?: @{}];
        NSArray *callStack = [ThirdDigitalExceptionTracking backtrace];
        [userInfo setObject:callStack forKey:RNUncaughtExceptionHandlerAddressesKey];

        NSString *reason = error.localizedDescription ?: @"React Native fatal error";
        ReportExceptionOnMainThread([NSException exceptionWithName:RCTFatalExceptionName
                                                            reason:reason
                                                          userInfo:userInfo]);

        if (callPreviousNativeErrorCallbackBlock && previousRCTFatalHandler) {
            previousRCTFatalHandler(error);
        } else if (forceApplicationToQuitAfterHandling) {
            abort();
        }
    });
    RCTSetFatalExceptionHandler(^(NSException *exception) {
        ReportExceptionOnMainThread(exception);

        if (callPreviousNativeErrorCallbackBlock && previousRCTFatalExceptionHandler) {
            previousRCTFatalExceptionHandler(exception);
        } else if (forceApplicationToQuitAfterHandling) {
            abort();
        }
    });
    signal(SIGABRT, SignalHandler);
    signal(SIGILL, SignalHandler);
    signal(SIGSEGV, SignalHandler);
    signal(SIGFPE, SignalHandler);
    signal(SIGBUS, SignalHandler);
    signal(SIGPIPE, SignalHandler);
    signal(SIGTRAP, SignalHandler);
    NSLog(@"REGISTERED RN EXCEPTION HANDLER");
}

RCT_EXPORT_METHOD(releaseExceptionHold:(BOOL)handled)
{
    releaseNativeExceptionHold = YES;
    if (handled) {
        ClearPendingException();
    }
}

- (void)handleException:(NSException *)exception
{
    NSDictionary *payload = BuildPayload(exception);
    PersistPendingException(payload);

    BOOL uploadedByNative = NO;
    if (nativeFallbackEnabled) {
        uploadedByNative = PostException(payload);
        if (uploadedByNative) {
            ClearPendingException();
        }
    }

    NSString *readeableError = [NSString stringWithFormat:NSLocalizedString(@"%@\n%@", nil),
                                [exception reason],
                                [[exception userInfo] objectForKey:RNUncaughtExceptionHandlerAddressesKey]];
    releaseNativeExceptionHold = NO;

    if (jsErrorCallbackBlock != nil) {
        jsErrorCallbackBlock(exception, readeableError, payload, uploadedByNative);
    } else {
        releaseNativeExceptionHold = YES;
    }

    NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:RNUncaughtExceptionHandlerHoldTimeout];
    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    CFArrayRef allModes = CFRunLoopCopyAllModes(runLoop);

    while (!releaseNativeExceptionHold && [timeoutDate timeIntervalSinceNow] > 0)
    {
        long count = CFArrayGetCount(allModes);
        long i = 0;
        while(i < count){
            NSString *mode = (__bridge NSString *)CFArrayGetValueAtIndex(allModes, i);
            if(![mode isEqualToString:@"kCFRunLoopCommonModes"]){
                CFRunLoopRunInMode((CFStringRef)mode, 0.001, false);
            }
            i++;
        }
    }

    CFRelease(allModes);

    if (callPreviousNativeErrorCallbackBlock && previousNativeErrorCallbackBlock) {
        previousNativeErrorCallbackBlock(exception);
        return;
    }

    NSSetUncaughtExceptionHandler(NULL);
    RCTSetFatalHandler(previousRCTFatalHandler);
    RCTSetFatalExceptionHandler(previousRCTFatalExceptionHandler);
    signal(SIGABRT, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGSEGV, SIG_DFL);
    signal(SIGFPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGTRAP, SIG_DFL);

    NSNumber *signalValue = [[exception userInfo] objectForKey:RNUncaughtExceptionHandlerSignalKey];
    if (signalValue != nil) {
        kill(getpid(), [signalValue intValue]);
    } else {
        [exception raise];
    }
}

static void HandleException(NSException *exception)
{
    int32_t exceptionCount = atomic_fetch_add_explicit(&RNUncaughtExceptionCount, 1, memory_order_relaxed) + 1;
    if (exceptionCount > RNUncaughtExceptionMaximum)
    {
        return;
    }

    if (lastReportedExceptionPointer == (__bridge void *)exception) {
        return;
    }
    lastReportedExceptionPointer = (__bridge void *)exception;

    NSArray *callStack = [ThirdDigitalExceptionTracking backtrace];
    NSMutableDictionary *userInfo =
    [NSMutableDictionary dictionaryWithDictionary:[exception userInfo] ?: @{}];
    [userInfo
     setObject:callStack
     forKey:RNUncaughtExceptionHandlerAddressesKey];

    ReportExceptionOnMainThread([NSException
                                 exceptionWithName:[exception name]
                                 reason:[exception reason]
                                 userInfo:userInfo]);
}

static void SignalHandler(int signal)
{
    int32_t exceptionCount = atomic_fetch_add_explicit(&RNUncaughtExceptionCount, 1, memory_order_relaxed) + 1;
    if (exceptionCount > RNUncaughtExceptionMaximum)
    {
        return;
    }

    NSMutableDictionary *userInfo =
    [NSMutableDictionary
     dictionaryWithObject:[NSNumber numberWithInt:signal]
     forKey:RNUncaughtExceptionHandlerSignalKey];

    NSArray *callStack = [ThirdDigitalExceptionTracking backtrace];
    [userInfo
     setObject:callStack
     forKey:RNUncaughtExceptionHandlerAddressesKey];

    ReportExceptionOnMainThread([NSException
                                 exceptionWithName:RNUncaughtExceptionHandlerSignalExceptionName
                                 reason:
                                 [NSString stringWithFormat:
                                  NSLocalizedString(@"Signal %d was raised.", nil),
                                  signal]
                                 userInfo:userInfo]);
}

static void ReportExceptionOnMainThread(NSException *exception)
{
    ThirdDigitalExceptionTracking *handler = [[ThirdDigitalExceptionTracking alloc] init];
    if ([NSThread isMainThread]) {
        [handler handleException:exception];
        return;
    }

    [handler performSelectorOnMainThread:@selector(handleException:)
                              withObject:exception
                           waitUntilDone:YES];
}

+ (NSArray *)backtrace
{
    void* callstack[128];
    int frames = backtrace(callstack, 128);
    char **strs = backtrace_symbols(callstack, frames);

    NSMutableArray *backtrace = [NSMutableArray arrayWithCapacity:frames];
    int start = MIN((int)RNUncaughtExceptionHandlerSkipAddressCount, frames);
    int end = MIN(start + (int)RNUncaughtExceptionHandlerReportAddressCount, frames);
    for (int i = start; i < end; i++)
    {
        [backtrace addObject:[NSString stringWithUTF8String:strs[i]]];
    }
    free(strs);

    return backtrace;
}

static NSDictionary *BuildPayload(NSException *exception)
{
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:basePayload ?: @{}];
    RemovePrivateFields(payload);

    NSMutableDictionary *metadata = [NSMutableDictionary dictionaryWithDictionary:payload[@"metadata"] ?: @{}];
    metadata[@"isNativeFallbackCandidate"] = @YES;
    metadata[@"framework"] = @"react-native";
    metadata[@"exceptionName"] = exception.name;
    metadata[@"exceptionSource"] = @"native";
    metadata[@"stackSource"] = @"native";
    RemovePrivateFields(metadata);

    payload[@"source"] = @"react-native";
    payload[@"exceptionSource"] = @"native";
    payload[@"stackSource"] = @"native";
    payload[@"platform"] = @"ios";
    payload[@"title"] = exception.name;
    payload[@"message"] = exception.reason ?: exception.name;
    payload[@"stackTrace"] = StackTraceString(exception);
    payload[@"timestamp"] = IsoTimestamp();
    payload[@"reportedAt"] = payload[@"timestamp"];
    if (![payload[@"screenName"] isKindOfClass:[NSString class]]) {
        payload[@"screenName"] = @"";
    }
    payload[@"metadata"] = metadata;

    NSMutableDictionary *exceptionData = [NSMutableDictionary dictionaryWithDictionary:payload[@"exceptionData"] ?: @{}];
    exceptionData[@"exceptionSource"] = @"native";
    exceptionData[@"exceptionName"] = exception.name;
    exceptionData[@"reason"] = exception.reason ?: @"";
    exceptionData[@"platform"] = @"ios";
    exceptionData[@"framework"] = @"react-native";
    exceptionData[@"stackSource"] = @"native";
    RemovePrivateFields(exceptionData);
    payload[@"exceptionData"] = exceptionData;

    NSDictionary *bundleInfo = NSBundle.mainBundle.infoDictionary ?: @{};
    NSString *appVersion = bundleInfo[@"CFBundleShortVersionString"];
    NSString *buildNumber = bundleInfo[(NSString *)kCFBundleVersionKey];
    NSString *bundleId = NSBundle.mainBundle.bundleIdentifier;
    NSString *uniqueId = UIDevice.currentDevice.identifierForVendor.UUIDString;

    if (appVersion.length > 0) {
        payload[@"appVersion"] = appVersion;
    }
    if (buildNumber.length > 0) {
        payload[@"buildNumber"] = buildNumber;
    }
    if (appVersion.length > 0 || buildNumber.length > 0) {
        payload[@"readableVersion"] = [NSString stringWithFormat:@"%@%@%@",
                                       appVersion ?: @"",
                                       appVersion.length > 0 && buildNumber.length > 0 ? @" " : @"",
                                       buildNumber.length > 0 ? [NSString stringWithFormat:@"(%@)", buildNumber] : @""];
    }
    if (bundleId.length > 0) {
        payload[@"bundleId"] = bundleId;
    }
    if (uniqueId.length > 0) {
        payload[@"deviceId"] = uniqueId;
        payload[@"installationId"] = uniqueId;
    }

    NSMutableDictionary *osInfo = [NSMutableDictionary dictionaryWithDictionary:payload[@"osInfo"] ?: @{}];
    osInfo[@"osName"] = @"ios";
    osInfo[@"osVersion"] = UIDevice.currentDevice.systemVersion;
    osInfo[@"platform"] = UIDevice.currentDevice.systemName;
    payload[@"osInfo"] = osInfo;

    NSMutableDictionary *deviceInfo = [NSMutableDictionary dictionaryWithDictionary:payload[@"deviceInfo"] ?: @{}];
    deviceInfo[@"brand"] = @"Apple";
    deviceInfo[@"manufacturer"] = @"Apple";
    deviceInfo[@"model"] = UIDevice.currentDevice.model;
    deviceInfo[@"deviceId"] = UIDevice.currentDevice.model;
    deviceInfo[@"deviceName"] = UIDevice.currentDevice.name;
    deviceInfo[@"systemName"] = UIDevice.currentDevice.systemName;
    deviceInfo[@"systemVersion"] = UIDevice.currentDevice.systemVersion;
    deviceInfo[@"isTablet"] = @(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);
    deviceInfo[@"deviceType"] = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"Tablet" : @"Handset";
    deviceInfo[@"hasNotch"] = @NO;
    if (uniqueId.length > 0) {
        deviceInfo[@"uniqueId"] = uniqueId;
    }
    payload[@"deviceInfo"] = deviceInfo;
    payload[@"memoryInfo"] = BuildMemoryInfo();
    payload[@"storageInfo"] = BuildStorageInfo();
    payload[@"batteryInfo"] = BuildBatteryInfo();
    if (![payload[@"userInfo"] isKindOfClass:[NSDictionary class]]) {
        payload[@"userInfo"] = @{};
    }

    NSMutableDictionary *otherDetails = [NSMutableDictionary dictionaryWithDictionary:payload[@"otherDetails"] ?: @{}];
    otherDetails[@"exceptionSource"] = @"native";
    otherDetails[@"platform"] = @"ios";
    otherDetails[@"framework"] = @"react-native";
    RemovePrivateFields(otherDetails);
    payload[@"otherDetails"] = otherDetails;

    NSMutableDictionary *extraData = [NSMutableDictionary dictionaryWithDictionary:payload[@"extraData"] ?: otherDetails];
    RemovePrivateFields(extraData);
    payload[@"extraData"] = extraData;

    RemovePrivateFields(payload);

    return payload;
}

static void RemovePrivateFields(NSMutableDictionary *dictionary)
{
    if (privatePayloadKeys == nil) {
        privatePayloadKeys = @[ @"apiKey", @"url", @"headers", @"ingestUrl", @"project", @"projectKey" ];
    }
    for (NSString *key in privatePayloadKeys) {
        [dictionary removeObjectForKey:key];
    }
}

static NSDictionary *BuildMemoryInfo(void)
{
    NSMutableDictionary *memoryInfo = [NSMutableDictionary dictionary];
    memoryInfo[@"totalMemory"] = @(NSProcessInfo.processInfo.physicalMemory);
    return memoryInfo;
}

static NSDictionary *BuildStorageInfo(void)
{
    NSMutableDictionary *storageInfo = [NSMutableDictionary dictionary];
    NSError *error = nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfFileSystemForPath:NSHomeDirectory()
                                                                                     error:&error];
    if (error == nil) {
        NSNumber *totalDiskCapacity = attributes[NSFileSystemSize];
        NSNumber *freeDiskStorage = attributes[NSFileSystemFreeSize];
        if (totalDiskCapacity != nil) {
            storageInfo[@"totalDiskCapacity"] = totalDiskCapacity;
        }
        if (freeDiskStorage != nil) {
            storageInfo[@"freeDiskStorage"] = freeDiskStorage;
        }
    }
    return storageInfo;
}

static NSDictionary *BuildBatteryInfo(void)
{
    UIDevice *device = UIDevice.currentDevice;
    BOOL wasMonitoring = device.batteryMonitoringEnabled;
    device.batteryMonitoringEnabled = YES;

    NSMutableDictionary *batteryInfo = [NSMutableDictionary dictionary];
    if (device.batteryLevel >= 0) {
        batteryInfo[@"batteryLevel"] = @(device.batteryLevel);
    }
    batteryInfo[@"batteryState"] = @(device.batteryState);

    device.batteryMonitoringEnabled = wasMonitoring;
    return batteryInfo;
}

static NSString *StackTraceString(NSException *exception)
{
    NSArray *stack = exception.userInfo[RNUncaughtExceptionHandlerAddressesKey];
    if ([stack isKindOfClass:[NSArray class]]) {
        return [stack componentsJoinedByString:@"\n"];
    }
    return [exception.callStackSymbols componentsJoinedByString:@"\n"];
}

static BOOL PostException(NSDictionary *payload)
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block BOOL uploaded = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uploaded = PostExceptionSync(payload);
        dispatch_semaphore_signal(semaphore);
    });
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return uploaded;
}

static BOOL PostExceptionSync(NSDictionary *payload)
{
    if (ingestUrl.length == 0) {
        NSLog(@"ThirdDigitalExceptionTracking: native fallback skipped because ingest URL is not configured");
        return NO;
    }

    NSURL *url = [NSURL URLWithString:ingestUrl];
    if (!url || ![NSJSONSerialization isValidJSONObject:payload]) {
        NSLog(@"ThirdDigitalExceptionTracking: native fallback skipped because URL or payload is invalid");
        return NO;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 4;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (apiKey.length > 0) {
        [request setValue:apiKey forHTTPHeaderField:@"Api-Key"];
    }
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        [request setValue:[NSString stringWithFormat:@"%@", value] forHTTPHeaderField:[NSString stringWithFormat:@"%@", key]];
    }];

    NSError *jsonError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (jsonError) {
        NSLog(@"ThirdDigitalExceptionTracking: native fallback failed %@", jsonError.localizedDescription);
        return NO;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSInteger statusCode = 0;
    __block NSError *requestError = nil;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        statusCode = [(NSHTTPURLResponse *)response statusCode];
        requestError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];

    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (requestError) {
        NSLog(@"ThirdDigitalExceptionTracking: native fallback failed %@", requestError.localizedDescription);
        return NO;
    }
    if (statusCode < 200 || statusCode >= 300) {
        NSLog(@"ThirdDigitalExceptionTracking: native fallback failed with status %ld", (long)statusCode);
        return NO;
    }
    NSLog(@"ThirdDigitalExceptionTracking: native fallback uploaded exception");
    return YES;
}

static void PersistConfiguration(void)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (ingestUrl != nil) {
        [defaults setObject:ingestUrl forKey:[NSString stringWithFormat:@"%@.ingestUrl", RNPrefsName]];
    }
    if (apiKey != nil) {
        [defaults setObject:apiKey forKey:[NSString stringWithFormat:@"%@.apiKey", RNPrefsName]];
    }
    if (projectKey != nil) {
        [defaults setObject:projectKey forKey:[NSString stringWithFormat:@"%@.projectKey", RNPrefsName]];
    }
    if (headers != nil) {
        [defaults setObject:headers forKey:[NSString stringWithFormat:@"%@.headers", RNPrefsName]];
    }
    if (basePayload != nil) {
        [defaults setObject:basePayload forKey:[NSString stringWithFormat:@"%@.basePayload", RNPrefsName]];
    }
    [defaults setBool:nativeFallbackEnabled forKey:[NSString stringWithFormat:@"%@.nativeFallbackEnabled", RNPrefsName]];
    [defaults setBool:callPreviousNativeErrorCallbackBlock forKey:[NSString stringWithFormat:@"%@.executeOriginalHandler", RNPrefsName]];
    [defaults setBool:forceApplicationToQuitAfterHandling forKey:[NSString stringWithFormat:@"%@.forceToQuit", RNPrefsName]];
    [defaults synchronize];
}

static void RestoreConfiguration(void)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    ingestUrl = [defaults stringForKey:[NSString stringWithFormat:@"%@.ingestUrl", RNPrefsName]];
    apiKey = [defaults stringForKey:[NSString stringWithFormat:@"%@.apiKey", RNPrefsName]];
    projectKey = [defaults stringForKey:[NSString stringWithFormat:@"%@.projectKey", RNPrefsName]];
    headers = [defaults dictionaryForKey:[NSString stringWithFormat:@"%@.headers", RNPrefsName]] ?: @{};
    basePayload = [defaults dictionaryForKey:[NSString stringWithFormat:@"%@.basePayload", RNPrefsName]] ?: @{};
    nativeFallbackEnabled = [defaults objectForKey:[NSString stringWithFormat:@"%@.nativeFallbackEnabled", RNPrefsName]]
        ? [defaults boolForKey:[NSString stringWithFormat:@"%@.nativeFallbackEnabled", RNPrefsName]]
        : nativeFallbackEnabled;
    callPreviousNativeErrorCallbackBlock = [defaults objectForKey:[NSString stringWithFormat:@"%@.executeOriginalHandler", RNPrefsName]]
        ? [defaults boolForKey:[NSString stringWithFormat:@"%@.executeOriginalHandler", RNPrefsName]]
        : callPreviousNativeErrorCallbackBlock;
    forceApplicationToQuitAfterHandling = [defaults objectForKey:[NSString stringWithFormat:@"%@.forceToQuit", RNPrefsName]]
        ? [defaults boolForKey:[NSString stringWithFormat:@"%@.forceToQuit", RNPrefsName]]
        : forceApplicationToQuitAfterHandling;
}

static void PersistPendingException(NSDictionary *payload)
{
    if (![NSJSONSerialization isValidJSONObject:payload]) {
        return;
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [NSUserDefaults.standardUserDefaults setObject:json forKey:RNPendingPayloadKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

static void ClearPendingException(void)
{
    [NSUserDefaults.standardUserDefaults removeObjectForKey:RNPendingPayloadKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

static void UploadPendingException(void)
{
    if (!nativeFallbackEnabled) {
        return;
    }
    if (pendingUploadScheduled) {
        return;
    }

    NSString *json = [NSUserDefaults.standardUserDefaults stringForKey:RNPendingPayloadKey];
    if (json.length == 0) {
        return;
    }

    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![payload isKindOfClass:[NSDictionary class]]) {
        ClearPendingException();
        return;
    }

    pendingUploadScheduled = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (PostExceptionSync(payload)) {
            ClearPendingException();
        }
        pendingUploadScheduled = NO;
    });
}

static NSString *IsoTimestamp(void)
{
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    return [formatter stringFromDate:[NSDate date]];
}

#ifdef RCT_NEW_ARCH_ENABLED
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativeReactNativeExceptionHandlerSpecJSI>(params);
}
#endif

@end
