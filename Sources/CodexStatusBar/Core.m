#import "Core.h"
#import <sqlite3.h>
#import <sys/stat.h>

// 会话在菜单里可见的时间窗 (与 CSVisibleSessionActivity 保持一致)
static const NSTimeInterval CSVisibilityWindow = 5 * 60 * 60;

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
    return resolved != CSActivityIdle || idleDuration <= CSVisibilityWindow;
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

@interface CSSessionScanner () {
    sqlite3 *_database;
    sqlite3_stmt *_sessionsStatement;
    NSString *_databasePath;
    NSString *_cachedDatabasePath;
    NSTimeInterval _databasePathResolvedAt;
}
@property(nonatomic) NSMutableDictionary<NSString *, CSSessionCacheEntry *> *stateCache;
@end

@implementation CSSessionScanner

- (instancetype)init {
    self = [super init];
    if (self) _stateCache = [NSMutableDictionary dictionary];
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

    // 优先用 INDEXED BY 强制走 (updated_at_ms DESC, id DESC) 索引, 按序取满 100 行即停。
    // 不指定的话 SQLite 会选低选择度的 idx_threads_archived, 再对 640 行建临时 B 树排序。
    //
    // 但索引名是硬依赖: 万一 Codex 迁移 schema 时改名或删掉它, prepare 会直接失败
    // ("no such index"), 语句为 NULL, 整个任务列表会变成空的。所以准备失败时回退到
    // 不带 INDEXED BY 的同一条查询 —— 计划可能变差, 但结果始终正确。
    static const char *sqlIndexed =
        "SELECT id, title, rollout_path, updated_at_ms FROM threads "
        "INDEXED BY idx_threads_updated_at_ms "
        "WHERE archived = 0 AND thread_source = 'user' "
        "ORDER BY updated_at_ms DESC LIMIT 100";
    static const char *sqlFallback =
        "SELECT id, title, rollout_path, updated_at_ms FROM threads "
        "WHERE archived = 0 AND thread_source = 'user' "
        "ORDER BY updated_at_ms DESC LIMIT 100";

    if (sqlite3_prepare_v2(_database, sqlIndexed, -1, &_sessionsStatement, NULL) != SQLITE_OK) {
        _sessionsStatement = NULL;
        if (sqlite3_prepare_v2(_database, sqlFallback, -1, &_sessionsStatement, NULL) != SQLITE_OK) {
            _sessionsStatement = NULL;
            return NULL;
        }
    }
    return _sessionsStatement;
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
        NSMutableArray<CSSessionItem *> *sessions = [NSMutableArray array];
        int stepResult;
        while ((stepResult = sqlite3_step(statement)) == SQLITE_ROW) {
            NSString *threadID = [self stringAtColumn:0 statement:statement];
            NSString *title = [self stringAtColumn:1 statement:statement];
            NSString *rolloutPath = [self stringAtColumn:2 statement:statement];
            NSTimeInterval updatedSeconds = sqlite3_column_int64(statement, 3) / 1000.0;
            if (!threadID.length || !rolloutPath.length) continue;

            NSDate *updatedAt = [NSDate dateWithTimeIntervalSince1970:updatedSeconds];

            // 这里曾经加过一层"老会话预筛"(缓存中非 Working 且超出 5 小时就 continue),
            // 但它优先采用缓存的 eventDate, 会忽略数据库里刚刷新的 updated_at_ms:
            // 昨天完成的会话今天继续提问时, 数据库时间已更新, 预筛仍按昨天的缓存时间判定
            // "超过 5 小时"而跳过, 且每轮都跳 —— 该会话会被永久跳过, 完成提醒也随之丢失。
            // 换成裸 stat() 之后, 不预筛的代价只有每轮约 100 次 stat (约 0.1ms),
            // 收益微乎其微, 所以直接去掉, 完全恢复原本的可见性语义。
            CSSessionCacheEntry *state = [self stateForRolloutPath:rolloutPath];
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

        if (stepResult == SQLITE_DONE) {
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
    // 裸 stat 只要约 1µs。每 3 秒要对最多 100 个文件做这件事, 差距非常明显。
    struct stat fileInfo;
    if (stat(path.fileSystemRepresentation, &fileInfo) != 0)
        return cached ?: [CSSessionCacheEntry new];
    unsigned long long size = (unsigned long long)fileInfo.st_size;
    if (cached && cached.fileSize == size) return cached;   // 内容没变, 到此为止

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return cached ?: [CSSessionCacheEntry new];

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
    if (activity == CSActivityWorking) return 0;
    if (activity == CSActivityCompleted) return 1;
    return 2;
}

@end
