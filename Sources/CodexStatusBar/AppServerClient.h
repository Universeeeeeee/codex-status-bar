#import <Foundation/Foundation.h>
#import "Core.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^CSRateCompletion)(CSRateSnapshot *_Nullable snapshot, NSError *_Nullable error);

@interface CSAppServerClient : NSObject
- (void)fetchRateLimits:(CSRateCompletion)completion;
@end

NS_ASSUME_NONNULL_END
