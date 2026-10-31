#import "TSAppDelegate.h"
#import "TSRootViewController.h"
#import <TSUtil.h>

extern NSUserDefaults* trollStoreUserDefaults(void);

@implementation TSAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	// Auto migrate installAlertConfiguration to Never (2)
	NSUserDefaults* tsDefaults = trollStoreUserDefaults();
	if(![tsDefaults boolForKey:@"hasConfiguredInstallAlert_v2"])
	{
		[tsDefaults setObject:@2 forKey:@"installAlertConfiguration"];
		[tsDefaults setBool:YES forKey:@"hasConfiguredInstallAlert_v2"];
	}

	// Auto enable URL Scheme if disabled
	if(![NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleURLTypes"])
	{
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
		{
			spawnRoot(rootHelperPath(), @[@"url-scheme", @"enable"], nil, nil);
			spawnRoot(rootHelperPath(), @[@"refresh-all"], nil, nil);
		});
	}

	return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
    // Called when a new scene session is being created.
    // Use this method to select a configuration to create the new scene with.
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}


- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    // Called when the user discards a scene session.
    // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
    // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
}

@end
