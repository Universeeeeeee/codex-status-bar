#import "Core.h"
#import <sqlite3.h>

@implementation CSRateBucket
- (NSInteger)remainingPercent {
    return (NSInteger)llround(MIN(100, MAX(0, 100 - self.usedPercent)));
}
@end

@implementation CSRateSnapshot
@end

@implementation CSSessionItem
@end

@interface CSSessionCacheEntry : NSObject
@property(nonatomic) unsigned long long fileSize;
@property(nonatomic) CSActivity activity;
@property(nonatomic, nullable) NSDate *eventDate;
@end

@implementation CSSessionCacheEntry
@end

static NSDate *CSParseDate(NSString *value) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSISO8601DateFormatter new];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return [formatter dateFromString:value];
}

BOOL CSTryParseSessionData(NSData *data, CSActivity *activity, NSDate **eventDate) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return NO;

    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSSet<NSString *> *lifecycle = [NSSet setWithObjects:@"task_started", @"task_complete", @"turn_aborted", nil];
    for (NSString *line in [lines reverseObjectEnumerator]) {
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *object = lineData.length ? [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil] : nil;
        NSDictionary *payload = [object[@"payload"] isKindOfClass:NSDictionary.class] ? object[@"payload"] : nil;
        NSString *type = [payload[@"type"] isKindOfClass:NSString.class] ? payload[@"type"] : nil;
        if (!type || ![lifecycle containsObject:type]) continue;

        if (eventDate) {
            NSString *timestamp = [object[@"timestamp"] isKindOfClass:NSString.class] ? object[@"timestamp"] : nil;
            *eventDate = timestamp ? CSParseDate(timestamp) : nil;
        }
        if (activity) {
            if ([type isEqualToString:@"task_started"]) *activity = CSActivityWorking;
            else if ([type isEqualToString:@"task_complete"]) *activity = CSActivityCompleted;
            else *activity = CSActivityIdle;
        }
        return YES;
    }
    return NO;
}

CSActivity CSParseSessionData(NSData *data, NSDate **eventDate) {
    CSActivity activity = CSActivityIdle;
    CSTryParseSessionData(data, &activity, eventDate);
    return activity;
}

BOOL CSVisibleSessionActivity(CSActivity rawActivity, NSDate *lastActivityAt, NSDate *now, CSActivity *visibleActivity) {
    CSActivity resolved = rawActivity;
    NSTimeInterval idleDuration = [now timeIntervalSinceDate:lastActivityAt];
    if (resolved == CSActivityCompleted && idleDuration > 10 * 60) resolved = CSActivityIdle;
    if (visibleActivity) *visibleActivity = resolved;
    return resolved != CSActivityIdle || idleDuration <= 5 * 60 * 60;
}

CSActivity CSAggregateSessionActivity(NSArray<CSSessionItem *> *sessions) {
    for (CSSessionItem *session in sessions) {
        if (session.activity == CSActivityWorking) return CSActivityWorking;
    }
    for (CSSessionItem *session in sessions) {
        if (session.activity == CSActivityCompleted) return CSActivityCompleted;
    }
    return CSActivityIdle;
}

static NSNumber *CSNumber(id value) {
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

static CSRateBucket *CSParseBucket(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *dictionary = value;
    NSNumber *used = CSNumber(dictionary[@"usedPercent"]);
    NSNumber *window = CSNumber(dictionary[@"windowDurationMins"]);
    NSNumber *reset = CSNumber(dictionary[@"resetsAt"]);
    if (!used || !window || !reset) return nil;

    CSRateBucket *bucket = [CSRateBucket new];
    bucket.usedPercent = used.doubleValue;
    bucket.windowMinutes = window.integerValue;
    bucket.resetsAt = reset.doubleValue;
    return bucket;
}

static void CSCollectBuckets(NSDictionary *limit, NSMutableArray<CSRateBucket *> *buckets) {
    if (![limit isKindOfClass:NSDictionary.class]) return;
    CSRateBucket *primary = CSParseBucket(limit[@"primary"]);
    CSRateBucket *secondary = CSParseBucket(limit[@"secondary"]);
    if (primary) [buckets addObject:primary];
    if (secondary) [buckets addObject:secondary];
}

CSRateSnapshot *CSParseRateLimitResponse(NSData *data) {
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *result = [root[@"result"] isKindOfClass:NSDictionary.class] ? root[@"result"] : nil;
    if (!result) return nil;

    NSMutableArray<CSRateBucket *> *buckets = [NSMutableArray array];
    NSDictionary *byID = [result[@"rateLimitsByLimitId"] isKindOfClass:NSDictionary.class] ? result[@"rateLimitsByLimitId"] : nil;
    for (id value in byID.allValues) CSCollectBuckets(value, buckets);
    CSCollectBuckets(result[@"rateLimits"], buckets);

    CSRateSnapshot *snapshot = [CSRateSnapshot new];
    for (CSRateBucket *bucket in buckets) {
        if (bucket.windowMinutes == 300 && !snapshot.fiveHour) snapshot.fiveHour = bucket;
        if (bucket.windowMinutes == 10080 && !snapshot.weekly) snapshot.weekly = bucket;
    }
    return snapshot;
}

CSRateSnapshot *CSMergeRateSnapshots(CSRateSnapshot *previous, CSRateSnapshot *update) {
    if (!update) return previous;

    CSRateSnapshot *merged = [CSRateSnapshot new];
    merged.fiveHour = update.fiveHour ?: previous.fiveHour;
    merged.weekly = update.weekly ?: previous.weekly;
    return merged;
}

@interface CSSessionScanner ()
@property(nonatomic) NSMutableDictionary<NSString *, CSSessionCacheEntry *> *stateCache;
@end

@implementation CSSessionScanner

- (instancetype)init {
    self = [super init];
    if (self) _stateCache = [NSMutableDictionary dictionary];
    return self;
}

- (NSArray<CSSessionItem *> *)currentSessions {
    NSString *databasePath = [self stateDatabasePath];
    if (!databasePath) return @[];

    sqlite3 *database = NULL;
    if (sqlite3_open_v2(databasePath.fileSystemRepresentation, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (database) sqlite3_close(database);
        return @[];
    }
    sqlite3_busy_timeout(database, 250);

    const char *sql = "SELECT id, title, rollout_path, updated_at_ms FROM threads "
                      "WHERE archived = 0 AND thread_source = 'user' "
                      "ORDER BY updated_at_ms DESC LIMIT 100";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(database, sql, -1, &statement, NULL) != SQLITE_OK) {
        sqlite3_close(database);
        return @[];
    }

    NSDate *now = NSDate.date;
    NSMutableArray<CSSessionItem *> *sessions = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        NSString *threadID = [self stringAtColumn:0 statement:statement];
        NSString *title = [self stringAtColumn:1 statement:statement];
        NSString *rolloutPath = [self stringAtColumn:2 statement:statement];
        NSTimeInterval updatedSeconds = sqlite3_column_int64(statement, 3) / 1000.0;
        if (!threadID.length || !rolloutPath.length) continue;

        CSSessionCacheEntry *state = [self stateForRolloutPath:rolloutPath];
        NSDate *updatedAt = [NSDate dateWithTimeIntervalSince1970:updatedSeconds];
        NSDate *lastActivityAt = state.eventDate ?: updatedAt;
        CSActivity visibleActivity;
        if (!CSVisibleSessionActivity(state.activity, lastActivityAt, now, &visibleActivity)) continue;

        CSSessionItem *item = [CSSessionItem new];
        item.threadID = threadID;
        item.title = title.length ? title : @"未命名任务";
        item.activity = visibleActivity;
        item.eventDate = state.eventDate;
        item.updatedAt = updatedAt;
        [sessions addObject:item];
    }

    sqlite3_finalize(statement);
    sqlite3_close(database);
    [sessions sortUsingComparator:^NSComparisonResult(CSSessionItem *left, CSSessionItem *right) {
        NSInteger leftRank = [self rankForActivity:left.activity];
        NSInteger rightRank = [self rankForActivity:right.activity];
        if (leftRank != rightRank) return leftRank < rightRank ? NSOrderedAscending : NSOrderedDescending;
        return [right.updatedAt compare:left.updatedAt];
    }];
    return sessions;
}

- (CSActivity)currentActivity {
    return CSAggregateSessionActivity([self currentSessions]);
}

- (CSSessionCacheEntry *)stateForRolloutPath:(NSString *)path {
    CSSessionCacheEntry *cached = self.stateCache[path];
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return cached ?: [CSSessionCacheEntry new];

    unsigned long long size = [handle seekToEndOfFile];
    if (cached && cached.fileSize == size) {
        [handle closeFile];
        return cached;
    }

    CSActivity activity = cached ? cached.activity : CSActivityIdle;
    NSDate *eventDate = cached.eventDate;
    BOOL found = NO;
    if (cached && size > cached.fileSize) {
        [handle seekToFileOffset:cached.fileSize];
        NSData *appended = [handle readDataToEndOfFile];
        found = CSTryParseSessionData(appended, &activity, &eventDate);
    } else {
        unsigned long long tailSize = 256 * 1024;
        if (size > tailSize) [handle seekToFileOffset:size - tailSize];
        else [handle seekToFileOffset:0];
        NSData *tail = [handle readDataToEndOfFile];
        found = CSTryParseSessionData(tail, &activity, &eventDate);
        if (!found && size > tailSize) {
            [handle seekToFileOffset:0];
            NSData *fullData = [handle readDataToEndOfFile];
            found = CSTryParseSessionData(fullData, &activity, &eventDate);
        }
    }
    [handle closeFile];

    CSSessionCacheEntry *entry = cached ?: [CSSessionCacheEntry new];
    entry.fileSize = size;
    if (found) {
        entry.activity = activity;
        entry.eventDate = eventDate;
    }
    self.stateCache[path] = entry;
    return entry;
}

- (NSString *)stateDatabasePath {
    NSURL *codexHome = [NSFileManager.defaultManager.homeDirectoryForCurrentUser URLByAppendingPathComponent:@".codex" isDirectory:YES];
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:codexHome
                                                         includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                              error:nil];
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
        return [url.lastPathComponent hasPrefix:@"state_"] && [url.pathExtension isEqualToString:@"sqlite"];
    }];
    NSArray<NSURL *> *candidates = [files filteredArrayUsingPredicate:predicate];
    candidates = [candidates sortedArrayUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        NSDate *leftDate = [left resourceValuesForKeys:@[NSURLContentModificationDateKey] error:nil][NSURLContentModificationDateKey];
        NSDate *rightDate = [right resourceValuesForKeys:@[NSURLContentModificationDateKey] error:nil][NSURLContentModificationDateKey];
        return [rightDate compare:leftDate];
    }];
    return candidates.firstObject.path;
}

- (NSString *)stringAtColumn:(int)column statement:(sqlite3_stmt *)statement {
    const unsigned char *value = sqlite3_column_text(statement, column);
    return value ? [NSString stringWithUTF8String:(const char *)value] : @"";
}

- (NSInteger)rankForActivity:(CSActivity)activity {
    if (activity == CSActivityWorking) return 0;
    if (activity == CSActivityCompleted) return 1;
    return 2;
}

@end
