#import "TSAPIDaemon.h"
#import <TSUtil.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <signal.h>
#import <spawn.h>
#import <errno.h>
#import <string.h>
#import <fcntl.h>
#import <sys/sysctl.h>
#import <objc/runtime.h>
#import <objc/message.h>

#ifndef POSIX_SPAWN_SETSID
#define POSIX_SPAWN_SETSID 0x0400
#endif

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict, uid_t);

#define PID_FILE_PATH @"/tmp/trollstore_api.pid"
#define LOG_FILE_PATH @"/tmp/trollstore_api.log"

extern int SBSLaunchApplicationWithIdentifier(CFStringRef identifier, Boolean suspended);
extern int installIpa(NSString* ipaPath, BOOL force, BOOL useInstalldMethod, BOOL skipUICache);
extern int uninstallAppById(NSString* appId, BOOL useCustomMethod);
extern int uninstallAppByPath(NSString* appPath, BOOL useCustomMethod);
extern int enableJIT(NSString* userAppId);
extern NSString* appIdForAppPath(NSString* appPath);
extern NSString* findAppPathInBundlePath(NSString* bundlePath);
extern NSDictionary* infoDictionaryForAppPath(NSString* appPath);

static volatile sig_atomic_t g_daemonRunning = 1;

static void handleDaemonSignal(int sig)
{
    g_daemonRunning = 0;
}

static BOOL launchAppWithBundleId(NSString* bundleId)
{
    if (!bundleId || bundleId.length == 0) return NO;

    BOOL opened = NO;
    Class lsWorkspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (lsWorkspaceClass) {
        id workspace = [lsWorkspaceClass performSelector:@selector(defaultWorkspace)];
        if ([workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) {
            opened = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, @selector(openApplicationWithBundleID:), bundleId);
        }
    }
    if (!opened) {
        int sbsRet = SBSLaunchApplicationWithIdentifier((__bridge CFStringRef)bundleId, false);
        opened = (sbsRet == 0);
    }
    return opened;
}

static BOOL shouldOpenAppAfterInstall(void)
{
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.opa334.TrollStore.plist"];
    NSNumber *num = prefs[@"openAppAfterInstall"];
    return num ? [num boolValue] : YES;
}

static NSDictionary* getDeviceInfo(void)
{
    NSDictionary *sysVer = [NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"];
    NSString *version = sysVer[@"ProductVersion"] ?: @"";
    NSString *build = sysVer[@"ProductBuildVersion"] ?: @"";

    char machine[64] = {0};
    size_t size = sizeof(machine);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    NSString *model = [NSString stringWithUTF8String:machine] ?: @"iPhone";

    return @{
        @"system_version": version,
        @"build": build,
        @"model": model,
        @"name": @"iOS Device"
    };
}

static NSString* errorMessageForInstallCode(int code)
{
    switch(code)
    {
        case 0: return @"Success";
        case 166: return @"The IPA file does not exist or is not accessible.";
        case 167: return @"The IPA file does not appear to contain an app.";
        case 168: return @"Failed to extract IPA file.";
        case 169: return @"Failed to extract update tar file.";
        case 170: return @"Failed to create container for app bundle.";
        case 171: return @"An app with the same identifier is already installed.";
        case 172: return @"The app does not contain an Info.plist file.";
        case 173: return @"The app is not signed with fake CoreTrust and ldid is not installed.";
        case 174: return @"The app main executable does not exist.";
        case 175: return @"Failed to sign the app. ldid returned non-zero status.";
        case 176: return @"The app Info.plist is missing required values.";
        case 177: return @"Failed to mark app as TrollStore app.";
        case 178: return @"Failed to copy app bundle.";
        case 179: return @"The app identifier conflicts with a system app.";
        case 180: return @"The app has an encrypted main binary (DRM).";
        case 181: return @"Failed to add app to icon cache.";
        case 182: return @"App installed, but requires developer mode enabled.";
        case 183: return @"Failed to enable developer mode.";
        case 184: return @"App installed, but has additional encrypted binaries.";
        case 185: return @"Failed to sign app. CoreTrust bypass returned non-zero.";
        default: return [NSString stringWithFormat:@"Unknown error code %d", code];
    }
}

static void sendJSONResponse(NSDictionary *responseDict, int statusCode, NSString *statusText, int clientFd)
{
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:responseDict options:NSJSONWritingPrettyPrinted error:&error];
    if (!jsonData) {
        jsonData = [@"{\"status\":\"error\",\"message\":\"JSON serialization error\"}" dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSString *headers = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
        @"Content-Type: application/json; charset=utf-8\r\n"
        @"Content-Length: %lu\r\n"
        @"Connection: close\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        @"Access-Control-Allow-Headers: *\r\n\r\n",
        statusCode, statusText, (unsigned long)jsonData.length];

    NSData *headerData = [headers dataUsingEncoding:NSUTF8StringEncoding];
    send(clientFd, headerData.bytes, headerData.length, 0);
    send(clientFd, jsonData.bytes, jsonData.length, 0);
}

static NSDictionary<NSString *, NSString *>* parseQueryString(NSString *query)
{
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if (!query || query.length == 0) return params;

    NSArray *pairs = [query componentsSeparatedByString:@"&"];
    for (NSString *pair in pairs) {
        NSArray *kv = [pair componentsSeparatedByString:@"="];
        if (kv.count >= 2) {
            NSString *key = [[kv firstObject] stringByRemovingPercentEncoding];
            NSString *val = [[[kv subarrayWithRange:NSMakeRange(1, kv.count - 1)] componentsJoinedByString:@"="] stringByRemovingPercentEncoding];
            if (key && val) {
                params[key] = val;
            }
        } else if (kv.count == 1) {
            NSString *key = [kv[0] stringByRemovingPercentEncoding];
            if (key) params[key] = @"";
        }
    }
    return params;
}

#pragma mark - Endpoint Handlers

static void handleStatus(NSDictionary *params, int clientFd)
{
    NSDictionary *devInfo = getDeviceInfo();
    BOOL openAppAfterInstall = shouldOpenAppAfterInstall();

    NSDictionary *response = @{
        @"status": @"ok",
        @"app": @"TrollStore",
        @"mode": @"daemon",
        @"pid": @(getpid()),
        @"port": @8080,
        @"device": devInfo,
        @"open_app_after_install": @(openAppAfterInstall),
        @"api_server": @YES,
        @"version": @"2.1.1"
    };

    sendJSONResponse(response, 200, @"OK", clientFd);
}

static void handleApps(NSDictionary *params, int clientFd)
{
    NSArray *bundlePaths = trollStoreInstalledAppBundlePaths();
    NSMutableArray *appsList = [NSMutableArray array];

    for (NSString *bundlePath in bundlePaths) {
        NSDictionary *infoDict = infoDictionaryForAppPath(bundlePath);
        NSString *bundleId = infoDict[@"CFBundleIdentifier"] ?: appIdForAppPath(bundlePath);
        NSString *displayName = infoDict[@"CFBundleDisplayName"] ?: infoDict[@"CFBundleName"] ?: bundlePath.lastPathComponent;
        NSString *version = infoDict[@"CFBundleShortVersionString"] ?: infoDict[@"CFBundleVersion"] ?: @"";

        NSMutableDictionary *appEntry = [NSMutableDictionary dictionary];
        if (bundleId) appEntry[@"bundle_id"] = bundleId;
        if (displayName) appEntry[@"name"] = displayName;
        if (version) appEntry[@"version"] = version;
        if (bundlePath) appEntry[@"path"] = bundlePath;

        [appsList addObject:appEntry];
    }

    NSDictionary *response = @{
        @"status": @"ok",
        @"count": @(appsList.count),
        @"apps": appsList
    };

    sendJSONResponse(response, 200, @"OK", clientFd);
}

static void handleOpen(NSDictionary *params, int clientFd)
{
    NSString *bundleId = params[@"bundle_id"] ?: params[@"bundleId"] ?: params[@"id"];
    if (!bundleId || bundleId.length == 0) {
        sendJSONResponse(@{
            @"status": @"error",
            @"message": @"Missing parameter 'bundle_id'"
        }, 400, @"Bad Request", clientFd);
        return;
    }

    BOOL opened = launchAppWithBundleId(bundleId);

    if (opened) {
        sendJSONResponse(@{
            @"status": @"ok",
            @"bundle_id": bundleId,
            @"opened": @YES
        }, 200, @"OK", clientFd);
    } else {
        sendJSONResponse(@{
            @"status": @"error",
            @"bundle_id": bundleId,
            @"message": @"Failed to open application"
        }, 500, @"Failed", clientFd);
    }
}

static void handleUninstall(NSDictionary *params, int clientFd)
{
    NSString *bundleId = params[@"bundle_id"] ?: params[@"bundleId"] ?: params[@"id"];
    NSString *path = params[@"path"];

    if (!bundleId && !path) {
        sendJSONResponse(@{
            @"status": @"error",
            @"message": @"Missing parameter 'bundle_id' or 'path'"
        }, 400, @"Bad Request", clientFd);
        return;
    }

    int ret = -1;
    if (bundleId) {
        ret = uninstallAppById(bundleId, YES);
    } else if (path) {
        ret = uninstallAppByPath(path, YES);
    }

    if (ret == 0) {
        sendJSONResponse(@{
            @"status": @"ok",
            @"message": @"Uninstalled successfully",
            @"code": @(ret)
        }, 200, @"OK", clientFd);
    } else {
        sendJSONResponse(@{
            @"status": @"error",
            @"code": @(ret),
            @"error": @"Uninstall failed"
        }, 500, @"Uninstall Failed", clientFd);
    }
}

static void handleRespring(NSDictionary *params, int clientFd)
{
    sendJSONResponse(@{
        @"status": @"ok",
        @"message": @"Device respringing..."
    }, 200, @"OK", clientFd);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        killall(@"backboardd", YES);
    });
}

static void handleJIT(NSDictionary *params, int clientFd)
{
    NSString *bundleId = params[@"bundle_id"] ?: params[@"bundleId"] ?: params[@"id"];
    if (!bundleId || bundleId.length == 0) {
        sendJSONResponse(@{
            @"status": @"error",
            @"message": @"Missing parameter 'bundle_id'"
        }, 400, @"Bad Request", clientFd);
        return;
    }

    int ret = enableJIT(bundleId);
    if (ret == 0) {
        sendJSONResponse(@{
            @"status": @"ok",
            @"message": @"JIT enabled",
            @"bundle_id": bundleId
        }, 200, @"OK", clientFd);
    } else {
        sendJSONResponse(@{
            @"status": @"error",
            @"code": @(ret),
            @"message": @"Failed to enable JIT"
        }, 500, @"JIT Failed", clientFd);
    }
}

static void handleInstall(NSDictionary *params, int clientFd)
{
    NSString *urlString = params[@"url"];
    NSString *localPath = params[@"path"];
    BOOL force = [params[@"force"] boolValue] || [params[@"force"] isEqualToString:@"1"];

    if ((!urlString || urlString.length == 0) && (!localPath || localPath.length == 0)) {
        sendJSONResponse(@{
            @"status": @"error",
            @"message": @"Missing parameter 'url' or 'path'"
        }, 400, @"Bad Request", clientFd);
        return;
    }

    NSString *pathToInstall = nil;
    BOOL isDownloaded = NO;

    if (urlString && urlString.length > 0) {
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            sendJSONResponse(@{
                @"status": @"error",
                @"message": [NSString stringWithFormat:@"Invalid URL: %@", urlString]
            }, 400, @"Bad Request", clientFd);
            return;
        }

        NSLog(@"[TSAPIDaemon] Downloading IPA from: %@", url);
        __block NSString *tempFile = nil;
        __block NSError *dlError = nil;
        __block NSInteger httpStatusCode = 0;

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 180.0;
        config.timeoutIntervalForResource = 600.0;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

        NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                httpStatusCode = ((NSHTTPURLResponse *)response).statusCode;
            }
            if (error) {
                dlError = error;
            } else if (httpStatusCode >= 400) {
                dlError = [NSError errorWithDomain:@"TSAPIDaemon" code:httpStatusCode userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP status %ld", (long)httpStatusCode]}];
            } else if (location) {
                NSString *targetPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"daemon_dl_%@.ipa", [[NSUUID UUID] UUIDString]]];
                [[NSFileManager defaultManager] removeItemAtPath:targetPath error:nil];
                NSError *moveErr = nil;
                [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:targetPath error:&moveErr];
                if (!moveErr) {
                    tempFile = targetPath;
                } else {
                    dlError = moveErr;
                }
            }
            dispatch_semaphore_signal(sem);
        }];
        [task resume];

        long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_SEC)));
        if (waitResult != 0 || !tempFile) {
            if (waitResult != 0) [task cancel];
            sendJSONResponse(@{
                @"status": @"error",
                @"message": dlError ? dlError.localizedDescription : @"Download timed out or failed"
            }, 500, @"Download Failed", clientFd);
            return;
        }

        pathToInstall = tempFile;
        isDownloaded = YES;
    } else {
        pathToInstall = localPath;
        if (![[NSFileManager defaultManager] fileExistsAtPath:pathToInstall]) {
            sendJSONResponse(@{
                @"status": @"error",
                @"message": [NSString stringWithFormat:@"Local file not found: %@", pathToInstall]
            }, 404, @"File Not Found", clientFd);
            return;
        }
    }

    // Get list of apps before install to identify newly installed app if needed
    NSSet *appsBefore = [NSSet setWithArray:trollStoreInstalledAppBundlePaths()];

    NSLog(@"[TSAPIDaemon] Installing IPA: %@", pathToInstall);
    int ret = installIpa(pathToInstall, force, NO, NO);

    if (isDownloaded && pathToInstall) {
        [[NSFileManager defaultManager] removeItemAtPath:pathToInstall error:nil];
    }

    if (ret == 0 || ret == 182 || ret == 184) {
        // Find newly installed app
        NSMutableSet *appsAfter = [NSMutableSet setWithArray:trollStoreInstalledAppBundlePaths()];
        [appsAfter minusSet:appsBefore];
        NSString *newAppPath = [appsAfter anyObject];
        NSString *bundleId = newAppPath ? appIdForAppPath(newAppPath) : nil;

        BOOL shouldOpen = shouldOpenAppAfterInstall();
        if (shouldOpen && bundleId) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                launchAppWithBundleId(bundleId);
            });
        }

        sendJSONResponse(@{
            @"status": @"ok",
            @"message": @"App installed successfully",
            @"bundle_id": bundleId ?: @"",
            @"opened": @(shouldOpen && bundleId != nil),
            @"code": @(ret)
        }, 200, @"OK", clientFd);
    } else {
        NSString *errDesc = errorMessageForInstallCode(ret);
        sendJSONResponse(@{
            @"status": @"error",
            @"code": @(ret),
            @"error": errDesc
        }, 500, @"Install Error", clientFd);
    }
}

static void routeDaemonPath(NSString *path, NSString *method, NSDictionary *params, int clientFd)
{
    if ([path isEqualToString:@"/"] || [path isEqualToString:@"/status"] || [path isEqualToString:@"/api/status"]) {
        handleStatus(params, clientFd);
    } else if ([path isEqualToString:@"/apps"] || [path isEqualToString:@"/api/apps"]) {
        handleApps(params, clientFd);
    } else if ([path isEqualToString:@"/install"] || [path isEqualToString:@"/api/install"]) {
        handleInstall(params, clientFd);
    } else if ([path isEqualToString:@"/open"] || [path isEqualToString:@"/api/open"]) {
        handleOpen(params, clientFd);
    } else if ([path isEqualToString:@"/uninstall"] || [path isEqualToString:@"/api/uninstall"]) {
        handleUninstall(params, clientFd);
    } else if ([path isEqualToString:@"/respring"] || [path isEqualToString:@"/api/respring"]) {
        handleRespring(params, clientFd);
    } else if ([path isEqualToString:@"/jit"] || [path isEqualToString:@"/api/jit"]) {
        handleJIT(params, clientFd);
    } else {
        sendJSONResponse(@{
            @"status": @"error",
            @"message": [NSString stringWithFormat:@"Endpoint not found: %@", path]
        }, 404, @"Not Found", clientFd);
    }
}

static void handleClientHTTP(int client_fd)
{
    struct timeval tv;
    tv.tv_sec = 10;
    tv.tv_usec = 0;
    setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
    setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv, sizeof(tv));
#ifdef SO_NOSIGPIPE
    int opt = 1;
    setsockopt(client_fd, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));
#endif

    char buffer[8192];
    ssize_t bytesRead = recv(client_fd, buffer, sizeof(buffer) - 1, 0);
    if (bytesRead > 0) {
        buffer[bytesRead] = '\0';
        NSString *requestString = [[NSString alloc] initWithBytes:buffer length:bytesRead encoding:NSUTF8StringEncoding];
        if (!requestString) {
            requestString = [[NSString alloc] initWithBytes:buffer length:bytesRead encoding:NSISOLatin1StringEncoding];
        }

        if (requestString && requestString.length > 0) {
            NSString *headerSection = requestString;
            NSString *bodySection = @"";
            NSRange separatorRange = [requestString rangeOfString:@"\r\n\r\n"];
            if (separatorRange.location != NSNotFound) {
                headerSection = [requestString substringToIndex:separatorRange.location];
                bodySection = [requestString substringFromIndex:separatorRange.location + separatorRange.length];
            }

            NSArray<NSString *> *headerLines = [headerSection componentsSeparatedByString:@"\r\n"];
            if (headerLines.count > 0) {
                NSString *requestLine = headerLines.firstObject;
                NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
                if (parts.count >= 2) {
                    NSString *method = [parts[0] uppercaseString];
                    NSString *fullUri = parts[1];

                    if ([method isEqualToString:@"OPTIONS"]) {
                        sendJSONResponse(@{@"status": @"ok"}, 200, @"OK", client_fd);
                    } else {
                        NSString *path = fullUri;
                        NSString *queryString = @"";
                        NSRange queryRange = [fullUri rangeOfString:@"?"];
                        if (queryRange.location != NSNotFound) {
                            path = [fullUri substringToIndex:queryRange.location];
                            queryString = [fullUri substringFromIndex:queryRange.location + 1];
                        }

                        NSMutableDictionary<NSString *, NSString *> *params = [parseQueryString(queryString) mutableCopy];

                        if (bodySection.length > 0) {
                            NSData *bodyData = [bodySection dataUsingEncoding:NSUTF8StringEncoding];
                            if (bodyData) {
                                id jsonObject = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
                                if ([jsonObject isKindOfClass:[NSDictionary class]]) {
                                    for (NSString *key in (NSDictionary *)jsonObject) {
                                        id val = jsonObject[key];
                                        if ([val isKindOfClass:[NSString class]]) {
                                            params[key] = val;
                                        } else if ([val isKindOfClass:[NSNumber class]]) {
                                            params[key] = [val stringValue];
                                        }
                                    }
                                } else {
                                    NSDictionary *bodyParams = parseQueryString(bodySection);
                                    [params addEntriesFromDictionary:bodyParams];
                                }
                            }
                        }

                        routeDaemonPath(path, method, params, client_fd);
                    }
                }
            }
        }
    }
    close(client_fd);
}

#pragma mark - Process Management

int isAPIDaemonRunning(void)
{
    NSString *pidStr = [NSString stringWithContentsOfFile:PID_FILE_PATH encoding:NSUTF8StringEncoding error:nil];
    if (pidStr) {
        pid_t pid = (pid_t)[pidStr integerValue];
        if (pid > 0 && kill(pid, 0) == 0) {
            return 1;
        }
    }
    return 0;
}

int stopAPIDaemonProcess(void)
{
    NSString *pidStr = [NSString stringWithContentsOfFile:PID_FILE_PATH encoding:NSUTF8StringEncoding error:nil];
    if (pidStr) {
        pid_t pid = (pid_t)[pidStr integerValue];
        if (pid > 0) {
            NSLog(@"[TSAPIDaemon] Stopping daemon PID %d", pid);
            kill(pid, SIGTERM);
            for (int i = 0; i < 10; i++) {
                usleep(100000); // 100ms
                if (kill(pid, 0) != 0) break;
            }
            if (kill(pid, 0) == 0) {
                kill(pid, SIGKILL);
            }
        }
    }
    [[NSFileManager defaultManager] removeItemAtPath:PID_FILE_PATH error:nil];
    return 0;
}

int startAPIDaemonProcess(void)
{
    if (isAPIDaemonRunning()) {
        NSLog(@"[TSAPIDaemon] Daemon is already running (stopping to restart fresh)");
        stopAPIDaemonProcess();
        usleep(200000); // 200ms
    }

    NSString *executablePath = getExecutablePath();
    if (!executablePath) return -1;

    pid_t pid;
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, [LOG_FILE_PATH UTF8String], O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, [LOG_FILE_PATH UTF8String], O_WRONLY | O_CREAT | O_APPEND, 0644);

    char *const argv[] = {
        (char *)executablePath.fileSystemRepresentation,
        "api-daemon",
        NULL
    };

    int spawnError = posix_spawn(&pid, executablePath.fileSystemRepresentation, &actions, &attr, argv, NULL);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);

    if (spawnError != 0) {
        NSLog(@"[TSAPIDaemon] posix_spawn failed: %d", spawnError);
        return spawnError;
    }

    NSLog(@"[TSAPIDaemon] Spawned daemon PID %d", pid);
    return 0;
}

int runAPIDaemon(void)
{
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, handleDaemonSignal);
    signal(SIGINT, handleDaemonSignal);

    pid_t myPid = getpid();
    NSString *pidStr = [NSString stringWithFormat:@"%d", myPid];
    [pidStr writeToFile:PID_FILE_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSLog(@"[TSAPIDaemon] Daemon process active with PID %d", myPid);

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        NSLog(@"[TSAPIDaemon] socket failed: %d (%s)", errno, strerror(errno));
        return -1;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#ifdef SO_NOSIGPIPE
    setsockopt(server_fd, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));
#endif

    struct sockaddr_in serv_addr;
    memset(&serv_addr, 0, sizeof(serv_addr));
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    serv_addr.sin_port = htons(8080);

    if (bind(server_fd, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0) {
        NSLog(@"[TSAPIDaemon] bind failed: %d (%s)", errno, strerror(errno));
        close(server_fd);
        return -1;
    }

    if (listen(server_fd, 32) < 0) {
        NSLog(@"[TSAPIDaemon] listen failed: %d (%s)", errno, strerror(errno));
        close(server_fd);
        return -1;
    }

    NSLog(@"[TSAPIDaemon] Independent BSD socket server listening on 0.0.0.0:8080");

    while (g_daemonRunning) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &client_len);
        if (client_fd < 0) {
            if (!g_daemonRunning) break;
            continue;
        }

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            handleClientHTTP(client_fd);
        });
    }

    close(server_fd);
    [[NSFileManager defaultManager] removeItemAtPath:PID_FILE_PATH error:nil];
    NSLog(@"[TSAPIDaemon] Daemon process stopped");
    return 0;
}
