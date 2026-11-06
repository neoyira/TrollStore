#import "TSAPIServer.h"
#import "TSApplicationsManager.h"
#import "TSAppInfo.h"
#import <TSUtil.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

extern NSUserDefaults* trollStoreUserDefaults(void);

@interface TSAPIServer ()
{
    int _serverSocket;
    dispatch_queue_t _serverQueue;
    AVAudioPlayer *_silentAudioPlayer;
    BOOL _isRunning;
}
@end

@implementation TSAPIServer

+ (instancetype)sharedInstance
{
    static TSAPIServer *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[TSAPIServer alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _port = 8080;
        _serverSocket = -1;
        _isRunning = NO;

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAudioInterruption:)
                                                     name:AVAudioSessionInterruptionNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
    }
    return self;
}

- (BOOL)isRunning
{
    @synchronized (self) {
        return _isRunning;
    }
}

#pragma mark - Background Keepalive

static NSData* generateSilentWavData(void)
{
    // 8000 Hz, 1 channel (mono), 16-bit PCM, 1 second = 8000 samples = 16000 bytes
    uint32_t sampleRate = 8000;
    uint16_t channels = 1;
    uint16_t bitsPerSample = 16;
    uint32_t dataSize = sampleRate * channels * (bitsPerSample / 8); // 16000 bytes
    uint32_t chunkSize = 36 + dataSize;
    uint32_t byteRate = sampleRate * channels * (bitsPerSample / 8);
    uint16_t blockAlign = channels * (bitsPerSample / 8);

    NSMutableData *data = [NSMutableData dataWithCapacity:44 + dataSize];
    [data appendBytes:"RIFF" length:4];
    [data appendBytes:&chunkSize length:4];
    [data appendBytes:"WAVE" length:4];
    [data appendBytes:"fmt " length:4];
    uint32_t subchunk1Size = 16;
    [data appendBytes:&subchunk1Size length:4];
    uint16_t audioFormat = 1; // PCM
    [data appendBytes:&audioFormat length:2];
    [data appendBytes:&channels length:2];
    [data appendBytes:&sampleRate length:4];
    [data appendBytes:&byteRate length:4];
    [data appendBytes:&blockAlign length:2];
    [data appendBytes:&bitsPerSample length:2];
    [data appendBytes:"data" length:4];
    [data appendBytes:&dataSize length:4];

    uint8_t zeroBytes[1000] = {0};
    for (uint32_t i = 0; i < dataSize; i += sizeof(zeroBytes)) {
        uint32_t toWrite = MIN((uint32_t)sizeof(zeroBytes), dataSize - i);
        [data appendBytes:zeroBytes length:toWrite];
    }
    return data;
}

- (void)startBackgroundKeepAlive
{
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            AVAudioSession *session = [AVAudioSession sharedInstance];
            NSError *catError = nil;
            [session setCategory:AVAudioSessionCategoryPlayback
                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                           error:&catError];
            if (catError) {
                NSLog(@"[TSAPIServer] Audio session setCategory error: %@", catError);
            }
            [session setActive:YES error:nil];

            if (!self->_silentAudioPlayer) {
                NSData *wavData = generateSilentWavData();
                NSError *playerError = nil;
                self->_silentAudioPlayer = [[AVAudioPlayer alloc] initWithData:wavData error:&playerError];
                self->_silentAudioPlayer.numberOfLoops = -1;
                self->_silentAudioPlayer.volume = 0.0f;
                [self->_silentAudioPlayer prepareToPlay];
            }
            [self->_silentAudioPlayer play];
            NSLog(@"[TSAPIServer] Background silent audio player started");
        } @catch (NSException *e) {
            NSLog(@"[TSAPIServer] Exception starting audio keepalive: %@", e);
        }
    });
}

- (void)handleAudioInterruption:(NSNotification *)notification
{
    NSDictionary *userInfo = notification.userInfo;
    NSNumber *typeValue = userInfo[AVAudioSessionInterruptionTypeKey];
    if (typeValue && [typeValue unsignedIntegerValue] == AVAudioSessionInterruptionTypeEnded) {
        if (_isRunning && _silentAudioPlayer) {
            [[AVAudioSession sharedInstance] setActive:YES error:nil];
            [_silentAudioPlayer play];
        }
    }
}

- (void)handleAppDidEnterBackground:(NSNotification *)notification
{
    if (_isRunning && _silentAudioPlayer && ![_silentAudioPlayer isPlaying]) {
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        [_silentAudioPlayer play];
    }
}

#pragma mark - Server Lifecycle

- (void)start
{
    @synchronized (self) {
        if (_isRunning) return;
        _isRunning = YES;
    }

    [self startBackgroundKeepAlive];
    [self startSocketServer];
}

- (void)stop
{
    @synchronized (self) {
        if (!_isRunning) return;
        _isRunning = NO;
        if (_serverSocket >= 0) {
            close(_serverSocket);
            _serverSocket = -1;
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_silentAudioPlayer) {
            [self->_silentAudioPlayer stop];
            self->_silentAudioPlayer = nil;
        }
        @try {
            [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        } @catch (NSException *e) {}
    });

    NSLog(@"[TSAPIServer] Server stopped");
}

- (void)startSocketServer
{
    _serverQueue = dispatch_queue_create("com.opa334.trollstore.apiserver", DISPATCH_QUEUE_SERIAL);
    dispatch_async(_serverQueue, ^{
        self->_serverSocket = socket(AF_INET, SOCK_STREAM, 0);
        if (self->_serverSocket < 0) {
            NSLog(@"[TSAPIServer] socket() failed: %d (%s)", errno, strerror(errno));
            return;
        }

        int opt = 1;
        setsockopt(self->_serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#ifdef SO_NOSIGPIPE
        setsockopt(self->_serverSocket, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));
#endif

        struct sockaddr_in serv_addr;
        memset(&serv_addr, 0, sizeof(serv_addr));
        serv_addr.sin_family = AF_INET;
        serv_addr.sin_addr.s_addr = htonl(INADDR_ANY);
        serv_addr.sin_port = htons(self->_port ? self->_port : 8080);

        if (bind(self->_serverSocket, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0) {
            NSLog(@"[TSAPIServer] bind() failed: %d (%s)", errno, strerror(errno));
            close(self->_serverSocket);
            self->_serverSocket = -1;
            return;
        }

        if (listen(self->_serverSocket, 16) < 0) {
            NSLog(@"[TSAPIServer] listen() failed: %d (%s)", errno, strerror(errno));
            close(self->_serverSocket);
            self->_serverSocket = -1;
            return;
        }

        NSLog(@"[TSAPIServer] Pure BSD socket listening on 0.0.0.0:%d", self->_port ? self->_port : 8080);

        while (self->_isRunning && self->_serverSocket >= 0) {
            struct sockaddr_in client_addr;
            socklen_t client_len = sizeof(client_addr);
            int client_fd = accept(self->_serverSocket, (struct sockaddr *)&client_addr, &client_len);
            if (client_fd < 0) {
                if (!self->_isRunning) break;
                continue;
            }

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self handleClientConnection:client_fd];
            });
        }
    });
}

#pragma mark - Client Handling

- (void)handleClientConnection:(int)client_fd
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
        [self processRequestString:requestString clientFd:client_fd];
    }
    close(client_fd);
}

- (void)sendJSONResponse:(NSDictionary *)responseDict statusCode:(int)statusCode statusText:(NSString *)statusText clientFd:(int)clientFd
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

- (NSDictionary<NSString *, NSString *> *)parseQueryString:(NSString *)query
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

- (void)processRequestString:(NSString *)req clientFd:(int)clientFd
{
    if (!req || req.length == 0) return;

    NSString *headerSection = req;
    NSString *bodySection = @"";
    NSRange separatorRange = [req rangeOfString:@"\r\n\r\n"];
    if (separatorRange.location != NSNotFound) {
        headerSection = [req substringToIndex:separatorRange.location];
        bodySection = [req substringFromIndex:separatorRange.location + separatorRange.length];
    }

    NSArray<NSString *> *headerLines = [headerSection componentsSeparatedByString:@"\r\n"];
    if (headerLines.count == 0) return;

    NSString *requestLine = headerLines.firstObject;
    NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
    if (parts.count < 2) return;

    NSString *method = [parts[0] uppercaseString];
    NSString *fullUri = parts[1];

    if ([method isEqualToString:@"OPTIONS"]) {
        [self sendJSONResponse:@{@"status": @"ok"} statusCode:200 statusText:@"OK" clientFd:clientFd];
        return;
    }

    NSString *path = fullUri;
    NSString *queryString = @"";
    NSRange queryRange = [fullUri rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        path = [fullUri substringToIndex:queryRange.location];
        queryString = [fullUri substringFromIndex:queryRange.location + 1];
    }

    NSMutableDictionary<NSString *, NSString *> *params = [self parseQueryString:queryString].mutableCopy;

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
                NSDictionary *bodyParams = [self parseQueryString:bodySection];
                [params addEntriesFromDictionary:bodyParams];
            }
        }
    }

    [self routePath:path method:method params:params clientFd:clientFd];
}

- (void)routePath:(NSString *)path method:(NSString *)method params:(NSDictionary *)params clientFd:(int)clientFd
{
    if ([path isEqualToString:@"/"] || [path isEqualToString:@"/status"] || [path isEqualToString:@"/api/status"]) {
        [self handleStatus:params clientFd:clientFd];
    } else if ([path isEqualToString:@"/apps"] || [path isEqualToString:@"/api/apps"]) {
        [self handleApps:params clientFd:clientFd];
    } else if ([path isEqualToString:@"/install"] || [path isEqualToString:@"/api/install"]) {
        [self handleInstall:params clientFd:clientFd];
    } else if ([path isEqualToString:@"/open"] || [path isEqualToString:@"/api/open"]) {
        [self handleOpen:params clientFd:clientFd];
    } else if ([path isEqualToString:@"/uninstall"] || [path isEqualToString:@"/api/uninstall"]) {
        [self handleUninstall:params clientFd:clientFd];
    } else if ([path isEqualToString:@"/respring"] || [path isEqualToString:@"/api/respring"]) {
        [self handleRespring:params clientFd:clientFd];
    } else if ([path isEqualToString:@"/jit"] || [path isEqualToString:@"/api/jit"]) {
        [self handleJIT:params clientFd:clientFd];
    } else {
        [self sendJSONResponse:@{
            @"status": @"error",
            @"message": [NSString stringWithFormat:@"Endpoint not found: %@", path]
        } statusCode:404 statusText:@"Not Found" clientFd:clientFd];
    }
}

#pragma mark - Endpoint Handlers

- (void)handleStatus:(NSDictionary *)params clientFd:(int)clientFd
{
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"2.1.1";
    NSString *deviceName = [[UIDevice currentDevice] name];
    NSString *systemVersion = [[UIDevice currentDevice] systemVersion];
    NSString *model = [[UIDevice currentDevice] model];

    BOOL urlSchemeActive = (BOOL)[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleURLTypes"];
    NSNumber *openAppNum = [trollStoreUserDefaults() objectForKey:@"openAppAfterInstall"];
    BOOL openAppAfterInstall = openAppNum ? [openAppNum boolValue] : YES;

    NSDictionary *response = @{
        @"status": @"ok",
        @"app": @"TrollStore",
        @"version": version,
        @"device": @{
            @"name": deviceName ?: @"iOS Device",
            @"system_version": systemVersion ?: @"",
            @"model": model ?: @""
        },
        @"port": @(_port ? _port : 8080),
        @"url_scheme_enabled": @(urlSchemeActive),
        @"open_app_after_install": @(openAppAfterInstall),
        @"api_server": @YES
    };

    [self sendJSONResponse:response statusCode:200 statusText:@"OK" clientFd:clientFd];
}

- (void)handleApps:(NSDictionary *)params clientFd:(int)clientFd
{
    NSArray *bundlePaths = trollStoreInstalledAppBundlePaths();
    NSMutableArray *appsList = [NSMutableArray array];

    for (NSString *bundlePath in bundlePaths) {
        TSAppInfo *appInfo = [[TSAppInfo alloc] initWithAppBundlePath:bundlePath];
        [appInfo sync_loadBasicInfo];

        NSMutableDictionary *appEntry = [NSMutableDictionary dictionary];
        if (appInfo.bundleIdentifier) {
            appEntry[@"bundle_id"] = appInfo.bundleIdentifier;
        }
        if (appInfo.displayName) {
            appEntry[@"name"] = appInfo.displayName;
        }
        if (appInfo.versionString) {
            appEntry[@"version"] = appInfo.versionString;
        }
        if (bundlePath) {
            appEntry[@"path"] = bundlePath;
        }
        [appsList addObject:appEntry];
    }

    NSDictionary *response = @{
        @"status": @"ok",
        @"count": @(appsList.count),
        @"apps": appsList
    };

    [self sendJSONResponse:response statusCode:200 statusText:@"OK" clientFd:clientFd];
}

- (void)handleOpen:(NSDictionary *)params clientFd:(int)clientFd
{
    NSString *bundleId = params[@"bundle_id"] ?: params[@"bundleId"] ?: params[@"id"];
    if (!bundleId || bundleId.length == 0) {
        [self sendJSONResponse:@{
            @"status": @"error",
            @"message": @"Missing parameter 'bundle_id'"
        } statusCode:400 statusText:@"Bad Request" clientFd:clientFd];
        return;
    }

    __block BOOL opened = NO;
    if ([NSThread isMainThread]) {
        opened = [[TSApplicationsManager sharedInstance] openApplicationWithBundleID:bundleId];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            opened = [[TSApplicationsManager sharedInstance] openApplicationWithBundleID:bundleId];
        });
    }

    if (opened) {
        [self sendJSONResponse:@{
            @"status": @"ok",
            @"bundle_id": bundleId,
            @"opened": @YES
        } statusCode:200 statusText:@"OK" clientFd:clientFd];
    } else {
        [self sendJSONResponse:@{
            @"status": @"error",
            @"bundle_id": bundleId,
            @"message": @"Failed to open application"
        } statusCode:500 statusText:@"Failed" clientFd:clientFd];
    }
}

- (void)handleUninstall:(NSDictionary *)params clientFd:(int)clientFd
{
    NSString *bundleId = params[@"bundle_id"] ?: params[@"bundleId"] ?: params[@"id"];
    NSString *path = params[@"path"];

    if (!bundleId && !path) {
        [self sendJSONResponse:@{
            @"status": @"error",
            @"message": @"Missing parameter 'bundle_id' or 'path'"
        } statusCode:400 statusText:@"Bad Request" clientFd:clientFd];
        return;
    }

    int ret = -1;
    if (bundleId) {
        ret = [[TSApplicationsManager sharedInstance] uninstallApp:bundleId];
    } else if (path) {
        ret = [[TSApplicationsManager sharedInstance] uninstallAppByPath:path];
    }

    if (ret == 0) {
        [self sendJSONResponse:@{
            @"status": @"ok",
            @"message": @"Uninstalled successfully",
            @"code": @(ret)
        } statusCode:200 statusText:@"OK" clientFd:clientFd];
    } else {
        NSError *err = [[TSApplicationsManager sharedInstance] errorForCode:ret];
        [self sendJSONResponse:@{
            @"status": @"error",
            @"code": @(ret),
            @"error": err.localizedDescription ?: @"Uninstall failed"
        } statusCode:500 statusText:@"Uninstall Failed" clientFd:clientFd];
    }
}

- (void)handleRespring:(NSDictionary *)params clientFd:(int)clientFd
{
    [self sendJSONResponse:@{
        @"status": @"ok",
        @"message": @"Device respringing..."
    } statusCode:200 statusText:@"OK" clientFd:clientFd];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        respring();
    });
}

- (void)handleJIT:(NSDictionary *)params clientFd:(int)clientFd
{
    NSString *bundleId = params[@"bundle_id"] ?: params[@"bundleId"] ?: params[@"id"];
    if (!bundleId || bundleId.length == 0) {
        [self sendJSONResponse:@{
            @"status": @"error",
            @"message": @"Missing parameter 'bundle_id'"
        } statusCode:400 statusText:@"Bad Request" clientFd:clientFd];
        return;
    }

    int ret = [[TSApplicationsManager sharedInstance] enableJITForBundleID:bundleId];
    if (ret == 0) {
        [self sendJSONResponse:@{
            @"status": @"ok",
            @"message": @"JIT enabled",
            @"bundle_id": bundleId
        } statusCode:200 statusText:@"OK" clientFd:clientFd];
    } else {
        [self sendJSONResponse:@{
            @"status": @"error",
            @"code": @(ret),
            @"message": @"Failed to enable JIT"
        } statusCode:500 statusText:@"JIT Failed" clientFd:clientFd];
    }
}

- (void)handleInstall:(NSDictionary *)params clientFd:(int)clientFd
{
    NSString *urlString = params[@"url"];
    NSString *localPath = params[@"path"];
    BOOL force = [params[@"force"] boolValue] || [params[@"force"] isEqualToString:@"1"];

    if ((!urlString || urlString.length == 0) && (!localPath || localPath.length == 0)) {
        [self sendJSONResponse:@{
            @"status": @"error",
            @"message": @"Missing parameter 'url' or 'path'"
        } statusCode:400 statusText:@"Bad Request" clientFd:clientFd];
        return;
    }

    NSString *pathToInstall = nil;
    BOOL isDownloaded = NO;

    if (urlString && urlString.length > 0) {
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            [self sendJSONResponse:@{
                @"status": @"error",
                @"message": [NSString stringWithFormat:@"Invalid URL: %@", urlString]
            } statusCode:400 statusText:@"Bad Request" clientFd:clientFd];
            return;
        }

        NSLog(@"[TSAPIServer] Downloading IPA from: %@", url);
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
                dlError = [NSError errorWithDomain:@"TSAPIServer" code:httpStatusCode userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP error code %ld", (long)httpStatusCode]}];
            } else if (location) {
                NSString *targetPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"api_dl_%@.ipa", [[NSUUID UUID] UUIDString]]];
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
            [self sendJSONResponse:@{
                @"status": @"error",
                @"message": dlError ? dlError.localizedDescription : @"Download timed out or failed"
            } statusCode:500 statusText:@"Download Failed" clientFd:clientFd];
            return;
        }

        pathToInstall = tempFile;
        isDownloaded = YES;
    } else {
        pathToInstall = localPath;
        if (![[NSFileManager defaultManager] fileExistsAtPath:pathToInstall]) {
            [self sendJSONResponse:@{
                @"status": @"error",
                @"message": [NSString stringWithFormat:@"Local file not found: %@", pathToInstall]
            } statusCode:404 statusText:@"File Not Found" clientFd:clientFd];
            return;
        }
    }

    TSAppInfo *appInfo = [[TSAppInfo alloc] initWithIPAPath:pathToInstall];
    [appInfo sync_loadInfo];
    NSString *bundleId = [appInfo bundleIdentifier];
    NSString *appName = [appInfo displayName];

    NSLog(@"[TSAPIServer] Installing IPA (%@, %@)...", bundleId, appName);
    NSString *log = nil;
    int ret = [[TSApplicationsManager sharedInstance] installIpa:pathToInstall force:force log:&log];

    if (isDownloaded && pathToInstall) {
        [[NSFileManager defaultManager] removeItemAtPath:pathToInstall error:nil];
    }

    if (ret == 0) {
        NSNumber *openAppNum = [trollStoreUserDefaults() objectForKey:@"openAppAfterInstall"];
        BOOL shouldOpen = openAppNum ? [openAppNum boolValue] : YES;
        if (shouldOpen && bundleId) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[TSApplicationsManager sharedInstance] openApplicationWithBundleID:bundleId];
            });
        }

        [self sendJSONResponse:@{
            @"status": @"ok",
            @"message": @"App installed successfully",
            @"bundle_id": bundleId ?: @"",
            @"name": appName ?: @"",
            @"opened": @(shouldOpen && bundleId != nil),
            @"log": log ?: @""
        } statusCode:200 statusText:@"OK" clientFd:clientFd];
    } else {
        NSError *error = [[TSApplicationsManager sharedInstance] errorForCode:ret];
        [self sendJSONResponse:@{
            @"status": @"error",
            @"code": @(ret),
            @"error": error.localizedDescription ?: @"Installation failed",
            @"log": log ?: @""
        } statusCode:500 statusText:@"Install Error" clientFd:clientFd];
    }
}

@end
