#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSAPIServer : NSObject

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, assign) uint16_t port;

+ (instancetype)sharedInstance;
- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
