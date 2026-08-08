#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CSActivity) {
    CSActivityIdle,
    CSActivityWorking,
    CSActivityCompleted,
};

@interface CSRateBucket : NSObject
@property(nonatomic) double usedPercent;
@property(nonatomic) NSInteger windowMinutes;
@property(nonatomic) NSTimeInterval resetsAt;
@property(nonatomic, readonly) NSInteger remainingPercent;
@end

@interface CSRateSnapshot : NSObject
@property(nonatomic, nullable) CSRateBucket *fiveHour;
@property(nonatomic, nullable) CSRateBucket *weekly;
@end

@interface CSSessionItem : NSObject
@property(nonatomic) NSString *threadID;
@property(nonatomic) NSString *title;
@property(nonatomic) CSActivity activity;
@property(nonatomic, nullable) NSDate *eventDate;
@property(nonatomic) NSDate *updatedAt;
@end

FOUNDATION_EXPORT CSActivity CSParseSessionData(NSData *data, NSDate * _Nullable * _Nullable eventDate);
FOUNDATION_EXPORT BOOL CSTryParseSessionData(NSData *data, CSActivity *_Nullable activity, NSDate * _Nullable * _Nullable eventDate);
FOUNDATION_EXPORT BOOL CSVisibleSessionActivity(CSActivity rawActivity, NSDate *lastActivityAt, NSDate *now, CSActivity *_Nullable visibleActivity);
FOUNDATION_EXPORT CSActivity CSAggregateSessionActivity(NSArray<CSSessionItem *> *sessions);
FOUNDATION_EXPORT CSRateSnapshot *_Nullable CSParseRateLimitResponse(NSData *data);
FOUNDATION_EXPORT CSRateSnapshot *_Nullable CSMergeRateSnapshots(CSRateSnapshot *_Nullable previous, CSRateSnapshot *_Nullable update);

@interface CSSessionScanner : NSObject
- (NSArray<CSSessionItem *> *)currentSessions;
- (CSActivity)currentActivity;
@end

NS_ASSUME_NONNULL_END
