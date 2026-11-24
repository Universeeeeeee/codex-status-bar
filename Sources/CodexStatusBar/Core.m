#import "Core.h"
#import <sqlite3.h>
#import <sys/stat.h>

// 已读和闲置会话在菜单里可见的时间窗
static const NSTimeInterval CSVisibilityWindow = 2 * 60 * 60;
static const NSTimeInterval CSReadWindow = 10 * 60;
static NSString * const CSReadObservationsKey = @"ReadObservations";

@implementation CSRateBucket
- (NSInteger)remainingPercent {
    return (NSInteger)llround(MIN(100, MAX(0, 100 - self.usedPercent)));
}
@end

@implementation CSRateSnapshot
@end

@implementation CSSessionItem
@end

@interface CSCompletionTracker ()
@property(nonatomic) NSDate *startedAt;
@property(nonatomic) NSMutableDictionary<NSString *, NSDate *> *latestEvents;
@end

@implementation CSCompletionTracker
- (instancetype)init {
    self = [super init];
    if (self) {
        _startedAt = NSDate.date;
        _latestEvents = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)consumeSession:(CSSessionItem *)session atDate:(NSDate *)now {
    NSDate *eventDate = session.eventDate;
    if (!eventDate || !session.threadID.length || [eventDate compare:now] == NSOrderedDescending) return NO;
    NSDate *previous = self.latestEvents[session.threadID] ?: self.startedAt;
    if ([eventDate compare:previous] != NSOrderedDescending) return NO;
    self.latestEvents[session.threadID] = eventDate;
    return session.activity == CSActivityCompleted || session.activity == CSActivityWaitingForInput;
}
@end

@interface CSSessionCacheEntry : NSObject
@property(nonatomic) unsigned long long fileSize;
@property(nonatomic) CSActivity activity;
@property(nonatomic, nullable) NSDate *eventDate;
@property(nonatomic, nullable) NSString *completedTurnID;
@property(nonatomic, nullable) NSString *inputCallID;
@property(nonatomic) BOOL inputIsAsync;
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

static BOOL CSParseSessionUpdate(NSData *data, CSActivity *activity, NSDate **eventDate,
                                 NSString **inputCallID, BOOL *inputIsAsync, NSString **completedTurnID) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return NO;

    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    BOOL found = NO;
    for (NSString *line in lines) {
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *object = lineData.length ? [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil] : nil;
        NSDictionary *payload = [object[@"payload"] isKindOfClass:NSDictionary.class] ? object[@"payload"] : nil;
        NSString *type = [payload[@"type"] isKindOfClass:NSString.class] ? payload[@"type"] : nil;
        CSActivity next;
        if ([type isEqualToString:@"task_started"] || [type isEqualToString:@"task_complete"] ||
            [type isEqualToString:@"turn_aborted"]) {
            next = [type isEqualToString:@"task_started"] ? CSActivityWorking :
                   [type isEqualToString:@"task_complete"] ? CSActivityCompleted : CSActivityIdle;
            *inputCallID = nil;
        } else if ([object[@"type"] isEqual:@"response_item"] && [type isEqualToString:@"function_call"]) {
            NSString *name = [payload[@"name"] isKindOfClass:NSString.class] ? payload[@"name"] : @"";
            name = [name componentsSeparatedByString:@"."].lastObject;
            if (![name isEqualToString:@"request_user_input"] && ![name isEqualToString:@"request_user_input_async"]) continue;
            NSString *callID = [payload[@"call_id"] isKindOfClass:NSString.class] ? payload[@"call_id"] : nil;
            if (!callID.length) continue;
            *inputCallID = callID;
            *inputIsAsync = [name isEqualToString:@"request_user_input_async"];
            next = CSActivityWaitingForInput;
        } else if (*inputCallID && ([type isEqualToString:@"user_message"] ||
                   ([object[@"type"] isEqual:@"response_item"] && [type isEqualToString:@"message"] &&
                    [payload[@"role"] isEqual:@"user"]))) {
            *inputCallID = nil;
            next = CSActivityWorking;
        } else if ([object[@"type"] isEqual:@"response_item"] && [type isEqualToString:@"function_call_output"] &&
                   *inputCallID && !*inputIsAsync && [payload[@"call_id"] isEqual:*inputCallID]) {
            *inputCallID = nil;
            next = CSActivityWorking;
        } else {
            continue;
        }
        NSString *timestamp = [object[@"timestamp"] isKindOfClass:NSString.class] ? object[@"timestamp"] : nil;
        id turnID = payload[@"turn_id"];
        if (completedTurnID) *completedTurnID = next == CSActivityCompleted && [turnID isKindOfClass:NSString.class] ? turnID : nil;
        if (eventDate) *eventDate = timestamp ? CSParseDate(timestamp) : nil;
        if (activity) *activity = next;
        found = YES;
    }
    return found;
}

BOOL CSTryParseSessionData(NSData *data, CSActivity *activity, NSDate **eventDate) {
    NSString *inputCallID = nil;
    BOOL inputIsAsync = NO;
    return CSParseSessionUpdate(data, activity, eventDate, &inputCallID, &inputIsAsync, NULL);
}

CSActivity CSParseSessionData(NSData *data, NSDate **eventDate) {
    CSActivity activity = CSActivityIdle;
    CSTryParseSessionData(data, &activity, eventDate);
    return activity;
}

BOOL CSVisibleSessionActivity(CSActivity rawActivity, NSDate *lastActivityAt, NSDate *now, CSActivity *visibleActivity) {
    if (visibleActivity) *visibleActivity = rawActivity;
    return (rawActivity != CSActivityIdle && rawActivity != CSActivityRead) ||
        [now timeIntervalSinceDate:lastActivityAt] <= CSVisibilityWindow;
}

CSActivity CSAggregateSessionActivity(NSArray<CSSessionItem *> *sessions) {
    for (CSSessionItem *session in sessions) {
        if (session.activity == CSActivityWaitingForInput) return CSActivityWaitingForInput;
    }
    for (CSSessionItem *session in sessions) {
        if (session.activity == CSActivityWorking) return CSActivityWorking;
    }
    for (CSSessionItem *session in sessions) {
        if (session.activity == CSActivityCompleted) return CSActivityCompleted;
    }
    for (CSSessionItem *session in sessions) {
        if (session.activity == CSActivityRead) return CSActivityRead;
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

@interface CSSessionScanner () {
    sqlite3 *_database;
    sqlite3_stmt *_sessionsStatement;
    NSString *_databasePath;
    NSString *_cachedDatabasePath;
    NSTimeInterval _databasePathResolvedAt;
}
@property(nonatomic) NSMutableDictionary<NSString *, CSSessionCacheEntry *> *stateCache;
@property(nonatomic) NSDictionary<NSString *, NSDictionary *> *readObservations;
@end

@implementation CSSessionScanner

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateCache = [NSMutableDictionary dictionary];
        _readObservations = [NSUserDefaults.standardUserDefaults dictionaryForKey:CSReadObservationsKey] ?: @{};
    }
    return self;
}

- (void)dealloc {
    [self closeDatabase];
}

// 复用同一个连接和同一条已编译语句。
// 原实现每次刷新都 open_v2 + prepare + finalize + close, 导致:
//   1) 每次重新解析整个 schema (sqlite3ReadSchema → sqlite3RunParser → yy_reduce)
//   2) page cache 每次都是冷的, 重复 pread 读页 (采样里 49/76 样本都在这)
- (void)closeStatement {
    if (_sessionsStatement) { sqlite3_finalize(_sessionsStatement); _sessionsStatement = NULL; }
}

- (void)closeDatabase {
    [self closeStatement];
    if (_database) { sqlite3_close(_database); _database = NULL; }
    _databasePath = nil;
}

- (sqlite3_stmt *)sessionStatement {
    NSString *path = [self stateDatabasePath];
    if (!path) { [self closeDatabase]; return NULL; }
    if (_database && ![_databasePath isEqualToString:path]) [self closeDatabase];
    if (_sessionsStatement) return _sessionsStatement;

    if (!_database) {
        if (sqlite3_open_v2(path.fileSystemRepresentation, &_database,
                            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
            [self closeDatabase];
            return NULL;
        }
        sqlite3_busy_timeout(_database, 250);
        _databasePath = [path copy];
    }

    // 保留索引提示的兼容回退。扫描所有未归档的用户会话，以免遗漏较早完成的未读任务。
    NSString *readTurn = @"(SELECT last_published_turn FROM thread_read_receipts "
        "WHERE thread_id = threads.id AND first_unread_turn IS NULL)";
    // 老版本没有已读回执时，仍可显示已完成任务。
    for (NSString *receipt in @[readTurn, @"NULL"]) {
        for (NSString *indexHint in @[@"INDEXED BY idx_threads_updated_at_ms", @""]) {
            NSString *sql = [NSString stringWithFormat:
                @"SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''), '未命名任务'), rollout_path, updated_at_ms, %@ "
                "FROM threads %@ WHERE archived = 0 AND thread_source = 'user' ORDER BY updated_at_ms DESC",
                receipt, indexHint];
            if (sqlite3_prepare_v2(_database, sql.UTF8String, -1, &_sessionsStatement, NULL) == SQLITE_OK) {
                return _sessionsStatement;
            }
        }
    }
    return NULL;
}

- (NSArray<CSSessionItem *> *)currentSessions {
    // 最多两轮。第一轮若在"执行期"失败——典型情况是语句依赖的索引在 App 运行中被
    // DROP 掉, SQLite 重编译语句时找不到该索引, sqlite3_step 返回错误而不是
    // SQLITE_ROW/SQLITE_DONE——就释放语句重来。第二次 sessionStatement 会重新
    // prepare, 从而走到不带 INDEXED BY 的回退查询。否则列表会一直空到重启。
    for (int attempt = 0; attempt < 2; attempt++) {
        sqlite3_stmt *statement = [self sessionStatement];
        if (!statement) return @[];

        // 复用同一条已编译语句: 重置即可, 不再重新 prepare
        sqlite3_reset(statement);
        sqlite3_clear_bindings(statement);

        NSDate *now = NSDate.date;
        NSMutableDictionary<NSString *, NSDictionary *> *readObservations = [self.readObservations mutableCopy];
        NSMutableArray<CSSessionItem *> *sessions = [NSMutableArray array];
        int stepResult;
        while ((stepResult = sqlite3_step(statement)) == SQLITE_ROW) {
            NSString *threadID = [self stringAtColumn:0 statement:statement];
            NSString *title = [self stringAtColumn:1 statement:statement];
            NSString *rolloutPath = [self stringAtColumn:2 statement:statement];
            NSTimeInterval updatedSeconds = sqlite3_column_int64(statement, 3) / 1000.0;
            if (!threadID.length || !rolloutPath.length) continue;

            NSDate *updatedAt = [NSDate dateWithTimeIntervalSince1970:updatedSeconds];

            // 先读取会话状态。完成时间较早的任务也可能未读，或刚刚启动了新一轮。
            CSSessionCacheEntry *state = [self stateForRolloutPath:rolloutPath];
            NSDate *lastActivityAt = state.eventDate ?: updatedAt;
            CSActivity activity = state.activity;
            if (activity == CSActivityCompleted && state.completedTurnID.length &&
                [state.completedTurnID isEqualToString:[self stringAtColumn:4 statement:statement]]) {
                // 旧回执只有已读状态。活动已过期时，不能用首次检测时间重新显示。
                if (!CSVisibleSessionActivity(CSActivityRead, lastActivityAt, now, NULL)) continue;
                NSDictionary *observation = readObservations[threadID];
                NSDate *readAt = [observation[@"turnID"] isEqualToString:state.completedTurnID] ? observation[@"firstSeenAt"] : nil;
                // 回执没有时间戳。保留本轮首次已读时间，避免旧结果重新进入已读。
                if (!readAt) {
                    readAt = now;
                    readObservations[threadID] = @{@"turnID": state.completedTurnID, @"firstSeenAt": readAt};
                }
                activity = [now timeIntervalSinceDate:readAt] < CSReadWindow ? CSActivityRead : CSActivityIdle;
            }
            CSActivity visibleActivity;
            if (!CSVisibleSessionActivity(activity, lastActivityAt, now, &visibleActivity)) continue;

            CSSessionItem *item = [CSSessionItem new];
            item.threadID = threadID;
            item.title = title.length ? title : @"未命名任务";
            item.activity = visibleActivity;
            item.eventDate = state.eventDate;
            item.updatedAt = updatedAt;
            [sessions addObject:item];
        }

        if (stepResult == SQLITE_DONE) {
            if (![readObservations isEqualToDictionary:self.readObservations]) {
                self.readObservations = readObservations;
                [NSUserDefaults.standardUserDefaults setObject:readObservations forKey:CSReadObservationsKey];
            }
            // 语句保留复用, 不做 finalize; 连接也不关
            [sessions sortUsingComparator:^NSComparisonResult(CSSessionItem *left, CSSessionItem *right) {
                NSInteger leftRank = [self rankForActivity:left.activity];
                NSInteger rightRank = [self rankForActivity:right.activity];
                if (leftRank != rightRank) return leftRank < rightRank ? NSOrderedAscending : NSOrderedDescending;
                return [right.updatedAt compare:left.updatedAt];
            }];
            return sessions;
        }

        // 执行期失败: 释放语句, 下一轮重新 prepare (回退查询会在这里生效)
        [self closeStatement];
    }
    return @[];
}

- (CSActivity)currentActivity {
    return CSAggregateSessionActivity([self currentSessions]);
}

- (CSSessionCacheEntry *)stateForRolloutPath:(NSString *)path {
    CSSessionCacheEntry *cached = self.stateCache[path];

    // 用裸 stat() 取文件大小。
    // 注意: 不能用 [NSFileManager attributesOfItemAtPath:] —— 采样显示它会顺带
    // 调用 getxattr / listxattr 和 __getattrlist 去读扩展属性和一整组属性, 每次约 50µs;
    // 裸 stat 只要约 1µs。
    struct stat fileInfo;
    if (stat(path.fileSystemRepresentation, &fileInfo) != 0)
        return cached ?: [CSSessionCacheEntry new];
    unsigned long long size = (unsigned long long)fileInfo.st_size;
    if (cached && cached.fileSize == size) return cached;   // 内容没变, 到此为止

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return cached ?: [CSSessionCacheEntry new];

    CSActivity activity = cached ? cached.activity : CSActivityIdle;
    NSDate *eventDate = cached.eventDate;
    NSString *completedTurnID = cached.completedTurnID;
    NSString *inputCallID = cached.inputCallID;
    BOOL inputIsAsync = cached.inputIsAsync;
    BOOL found = NO;
    if (cached && size > cached.fileSize) {
        [handle seekToFileOffset:cached.fileSize];
        NSData *appended = [handle readDataToEndOfFile];
        found = CSParseSessionUpdate(appended, &activity, &eventDate, &inputCallID, &inputIsAsync, &completedTurnID);
    } else {
        unsigned long long tailSize = 256 * 1024;
        if (size > tailSize) [handle seekToFileOffset:size - tailSize];
        else [handle seekToFileOffset:0];
        NSData *tail = [handle readDataToEndOfFile];
        inputCallID = nil;
        inputIsAsync = NO;
        found = CSParseSessionUpdate(tail, &activity, &eventDate, &inputCallID, &inputIsAsync, &completedTurnID);
        if (!found && size > tailSize) {
            [handle seekToFileOffset:0];
            NSData *fullData = [handle readDataToEndOfFile];
            found = CSParseSessionUpdate(fullData, &activity, &eventDate, &inputCallID, &inputIsAsync, &completedTurnID);
        }
    }
    [handle closeFile];

    CSSessionCacheEntry *entry = cached ?: [CSSessionCacheEntry new];
    entry.fileSize = size;
    if (found) {
        entry.activity = activity;
        entry.eventDate = eventDate;
        entry.completedTurnID = completedTurnID;
        entry.inputCallID = inputCallID;
        entry.inputIsAsync = inputIsAsync;
    }
    self.stateCache[path] = entry;
    return entry;
}

// 解析 ~/.codex 下最新的 state_*.sqlite。
// 原实现每次刷新(3 秒)都枚举一遍 ~/.codex 并排序, 而且排序比较器里反复 lstat。
// 现在缓存 60 秒 —— Codex 只在新建 state_N 时才会换文件。
- (NSString *)stateDatabasePath {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (_cachedDatabasePath && now - _databasePathResolvedAt < 60 &&
        [NSFileManager.defaultManager fileExistsAtPath:_cachedDatabasePath]) {
        return _cachedDatabasePath;
    }

    NSURL *codexHome = [NSFileManager.defaultManager.homeDirectoryForCurrentUser URLByAppendingPathComponent:@".codex" isDirectory:YES];
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:codexHome
                                                         includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                              error:nil];
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
        return [url.lastPathComponent hasPrefix:@"state_"] && [url.pathExtension isEqualToString:@"sqlite"];
    }];
    NSArray<NSURL *> *candidates = [files filteredArrayUsingPredicate:predicate];

    // 每项先取一次 mtime, 避免在比较器内部反复 lstat (O(n log n) 次系统调用)
    NSMutableArray<NSArray *> *pairs = [NSMutableArray arrayWithCapacity:candidates.count];
    for (NSURL *url in candidates) {
        NSDate *date = [url resourceValuesForKeys:@[NSURLContentModificationDateKey] error:nil][NSURLContentModificationDateKey];
        [pairs addObject:@[date ?: NSDate.distantPast, url]];
    }
    [pairs sortUsingComparator:^NSComparisonResult(NSArray *left, NSArray *right) {
        return [(NSDate *)right[0] compare:(NSDate *)left[0]];
    }];

    NSString *resolved = pairs.count ? ((NSURL *)pairs.firstObject[1]).path : nil;
    _cachedDatabasePath = resolved;
    _databasePathResolvedAt = now;
    return resolved;
}

- (NSString *)stringAtColumn:(int)column statement:(sqlite3_stmt *)statement {
    const unsigned char *value = sqlite3_column_text(statement, column);
    return value ? [NSString stringWithUTF8String:(const char *)value] : @"";
}

- (NSInteger)rankForActivity:(CSActivity)activity {
    if (activity == CSActivityWaitingForInput) return -1;
    if (activity == CSActivityWorking) return 0;
    if (activity == CSActivityCompleted) return 1;
    if (activity == CSActivityRead) return 2;
    return 3;
}

@end
