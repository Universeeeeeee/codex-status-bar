#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface CSCompletionOverlay : NSObject
@property(nonatomic, copy, nullable) dispatch_block_t queueDidDrainHandler;
- (instancetype)initWithImage:(NSImage *)image;
- (void)enqueue;
@end

NS_ASSUME_NONNULL_END
