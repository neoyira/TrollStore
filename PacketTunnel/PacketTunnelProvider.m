#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import <dlfcn.h>

FOUNDATION_EXTERN int NSExtensionMain(int argc, const char *argv[]);

@interface PacketTunnelProvider : NEPacketTunnelProvider
@end

static void ts_launchApp(NSString *bundleId, BOOL suspended)
{
    if (!bundleId || bundleId.length == 0) return;

    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (!handle) {
        NSLog(@"[TSAutoLaunch] Failed to dlopen SpringBoardServices");
        return;
    }

    typedef int (*SBSLaunchFn)(CFStringRef, CFURLRef, CFDictionaryRef, CFDictionaryRef, BOOL);
    SBSLaunchFn launchFn = (SBSLaunchFn)dlsym(handle, "SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions");
    if (!launchFn) {
        NSLog(@"[TSAutoLaunch] Failed to resolve SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions");
        dlclose(handle);
        return;
    }

    NSDictionary *launchOptions = nil;
    if (!suspended) {
        launchOptions = @{ @"SBSApplicationLaunchOptionUnlockDeviceKey": @YES };
    }

    NSLog(@"[TSAutoLaunch] Launching app: %@ (suspended=%d)", bundleId, suspended);
    int ret = launchFn((__bridge CFStringRef)bundleId, NULL, NULL, (__bridge CFDictionaryRef)launchOptions, suspended);
    NSLog(@"[TSAutoLaunch] SBSLaunch returned: %d for %@", ret, bundleId);
    dlclose(handle);
}

static void ts_autoLaunch(void)
{
    NSString *plistPath = @"/var/mobile/Library/Preferences/com.opa334.TrollStore.plist";
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];

    if (prefs[@"autoLaunchEnabled"] && ![prefs[@"autoLaunchEnabled"] boolValue]) {
        NSLog(@"[TSAutoLaunch] Auto launch is disabled in preferences");
        return;
    }

    NSString *targetId = prefs[@"autoLaunchBundleId"];
    if (!targetId || targetId.length == 0) {
        targetId = @"com.opa334.Dopamine";
    }

    NSArray *targets = [targetId componentsSeparatedByString:@","];
    for (NSString *target in targets) {
        NSString *cleanId = [target stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (cleanId.length == 0) continue;

        BOOL isTrollStore = [cleanId isEqualToString:@"com.opa334.TrollStore"];
        BOOL suspended = isTrollStore;

        if ([cleanId isEqualToString:@"com.opa334.Dopamine"]) {
            // Attempt standard Dopamine and Dopamine-roothide
            ts_launchApp(@"com.opa334.Dopamine", suspended);
            ts_launchApp(@"com.opa334.Dopamine-roothide", suspended);
        } else {
            ts_launchApp(cleanId, suspended);
        }
    }
}

@implementation PacketTunnelProvider

- (void)startTunnelWithOptions:(NSDictionary<NSString *, NSObject *> *)options
             completionHandler:(void (^)(NSError *error))completionHandler
{
    NSLog(@"[TSAutoLaunch] startTunnelWithOptions called");

    NEPacketTunnelNetworkSettings *settings =
        [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:@"192.0.2.1"];
    NEIPv4Settings *ipv4 = [[NEIPv4Settings alloc] initWithAddresses:@[ @"192.0.2.2" ]
                                                          subnetMasks:@[ @"255.255.255.255" ]];
    ipv4.includedRoutes = @[]; // No routes -> does not route or intercept traffic
    settings.IPv4Settings = ipv4;

    [self setTunnelNetworkSettings:settings completionHandler:^(NSError *error) {
        completionHandler(error);
        if (!error) {
            int delaySeconds = 2;
            NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.opa334.TrollStore.plist"];
            if (prefs[@"autoLaunchDelay"]) {
                delaySeconds = [prefs[@"autoLaunchDelay"] intValue];
                if (delaySeconds < 1) delaySeconds = 1;
            }

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delaySeconds * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                ts_autoLaunch();
            });
        } else {
            NSLog(@"[TSAutoLaunch] setTunnelNetworkSettings error: %@", error);
        }
    }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler
{
    NSLog(@"[TSAutoLaunch] stopTunnelWithReason: %ld", (long)reason);
    completionHandler();
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return NSExtensionMain(argc, (const char **)argv);
    }
}
