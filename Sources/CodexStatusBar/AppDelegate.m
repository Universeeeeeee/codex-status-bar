#import "AppDelegate.h"
#import "AppServerClient.h"
#import "CompletionOverlay.h"
#import "Core.h"

@interface CSAppDelegate ()
@property(nonatomic) NSStatusItem *statusItem;
@property(nonatomic) CSSessionScanner *scanner;
@property(nonatomic) CSAppServerClient *client;
@property(nonatomic) CSCompletionOverlay *completionOverlay;
@property(nonatomic) NSMenu *menu;
@property(nonatomic) NSMenuItem *statusMenuItem;
@property(nonatomic) NSMenuItem *tasksSeparator;
@property(nonatomic) NSArray<NSMenuItem *> *taskMenuItems;
@property(nonatomic) NSMenuItem *weeklyMenuItem;
@property(nonatomic) NSMenuItem *updatedMenuItem;
@property(nonatomic) NSMenuItem *menuSpaceWarningItem;
@property(nonatomic) NSTimer *statusTimer;
@property(nonatomic) NSTimer *quotaTimer;
@property(nonatomic) CSActivity activity;
@property(nonatomic) NSArray<CSSessionItem *> *sessions;
@property(nonatomic) CSRateSnapshot *rateLimits;
@property(nonatomic) NSString *quotaError;
@property(nonatomic) BOOL statusRefreshInFlight;
@property(nonatomic) NSDictionary<NSString *, NSNumber *> *previousActivities;
@property(nonatomic) NSDate *lastSessionSnapshotAt;
@end

@implementation CSAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.scanner = [CSSessionScanner new];
    self.client = [CSAppServerClient new];
    NSString *completionImagePath = [NSBundle.mainBundle pathForResource:@"Completion" ofType:@"png"];
    NSImage *completionImage = completionImagePath ? [[NSImage alloc] initWithContentsOfFile:completionImagePath] : nil;
    if (completionImage) self.completionOverlay = [[CSCompletionOverlay alloc] initWithImage:completionImage];
    self.sessions = @[];
    self.taskMenuItems = @[];
    self.previousActivities = @{};
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    [self configureMenu];
    [self refreshStatus];
    [self refreshQuota];

    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
    self.quotaTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(refreshQuota) userInfo:nil repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.statusTimer invalidate];
    [self.quotaTimer invalidate];
}

- (void)configureMenu {
    NSMenu *menu = [NSMenu new];
    self.menu = menu;
    menu.delegate = self;
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"状态：读取中" action:nil keyEquivalent:@""];
    self.weeklyMenuItem = [[NSMenuItem alloc] initWithTitle:@"周额度：读取中" action:nil keyEquivalent:@""];
    self.updatedMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.menuSpaceWarningItem = [[NSMenuItem alloc] initWithTitle:@"菜单栏空间不足：额度文字可能被截断" action:nil keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];
    self.tasksSeparator = NSMenuItem.separatorItem;
    [menu addItem:self.tasksSeparator];

    for (NSMenuItem *item in @[self.weeklyMenuItem, self.updatedMenuItem]) {
        item.enabled = NO;
        [menu addItem:item];
    }
    self.menuSpaceWarningItem.enabled = NO;
    self.menuSpaceWarningItem.hidden = YES;
    [menu addItem:self.menuSpaceWarningItem];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"刷新额度" action:@selector(refreshQuota) keyEquivalent:@"r"];
    refresh.target = self;
    refresh.image = [NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"刷新额度"];
    [menu addItem:refresh];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出 Codex 状态" action:@selector(quit) keyEquivalent:@"q"];
    quit.target = self;
    quit.image = [NSImage imageWithSystemSymbolName:@"power" accessibilityDescription:@"退出"];
    [menu addItem:quit];

    self.statusItem.menu = menu;
    self.statusItem.button.toolTip = @"Codex 状态与额度";
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self refreshStatus];
}

- (void)refreshStatus {
    if (self.statusRefreshInFlight) return;
    self.statusRefreshInFlight = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<CSSessionItem *> *sessions = [weakSelf.scanner currentSessions];
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.statusRefreshInFlight = NO;
            [weakSelf handleCompletionTransitions:sessions];
            weakSelf.sessions = sessions;
            [weakSelf render];
        });
    });
}

- (void)handleCompletionTransitions:(NSArray<CSSessionItem *> *)sessions {
    NSDate *snapshotAt = NSDate.date;
    if (self.lastSessionSnapshotAt) {
        for (CSSessionItem *session in sessions) {
            if (session.activity != CSActivityCompleted) continue;

            NSNumber *previous = self.previousActivities[session.threadID];
            BOOL changedFromWorking = previous && previous.integerValue == CSActivityWorking;
            BOOL completedSinceLastScan = session.eventDate &&
                                          [session.eventDate compare:self.lastSessionSnapshotAt] == NSOrderedDescending;
            if (changedFromWorking || completedSinceLastScan) [self.completionOverlay enqueue];
        }
    }

    NSMutableDictionary<NSString *, NSNumber *> *nextActivities = [NSMutableDictionary dictionary];
    for (CSSessionItem *session in sessions) {
        nextActivities[session.threadID] = @(session.activity);
    }
    self.previousActivities = nextActivities;
    self.lastSessionSnapshotAt = snapshotAt;
}

- (void)refreshQuota {
    self.updatedMenuItem.title = @"额度更新中…";
    __weak typeof(self) weakSelf = self;
    [self.client fetchRateLimits:^(CSRateSnapshot *snapshot, NSError *error) {
        weakSelf.rateLimits = CSMergeRateSnapshots(weakSelf.rateLimits, snapshot);
        weakSelf.quotaError = error.localizedDescription;
        if (!error) weakSelf.updatedMenuItem.title = [NSString stringWithFormat:@"更新于 %@", [weakSelf.class.timeFormatter stringFromDate:NSDate.date]];
        [weakSelf render];
    }];
}

- (void)quit {
    [NSApp terminate:nil];
}

- (void)render {
    NSInteger workingCount = [self countForActivity:CSActivityWorking];
    NSInteger completedCount = [self countForActivity:CSActivityCompleted];
    NSInteger idleCount = [self countForActivity:CSActivityIdle];
    self.activity = CSAggregateSessionActivity(self.sessions);

    NSString *activityTitle = [self titleForActivity:self.activity];
    NSString *symbol = [self symbolForActivity:self.activity];
    NSString *weekly = self.rateLimits.weekly ? [NSString stringWithFormat:@"%ld%%", self.rateLimits.weekly.remainingPercent] : @"--";

    NSString *statusSummary;
    if (workingCount || completedCount) {
        statusSummary = [NSString stringWithFormat:@"开发 %ld · 完成 %ld", workingCount, completedCount];
    } else {
        statusSummary = @"闲置";
    }
    NSString *statusTitle = [NSString stringWithFormat:@" %@  周 %@", statusSummary, weekly];
    self.statusItem.button.title = statusTitle;
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:activityTitle];
    self.statusItem.button.imagePosition = NSImageLeading;
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"Codex 状态与额度\n%@", statusTitle];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf updateMenuBarTruncationWarning];
    });
    self.statusMenuItem.title = [NSString stringWithFormat:@"任务：开发中 %ld · 已完成 %ld · 闲置 %ld", workingCount, completedCount, idleCount];
    self.statusMenuItem.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:activityTitle];
    [self renderTaskItems];
    self.weeklyMenuItem.title = [self detailForTitle:@"周额度" bucket:self.rateLimits.weekly];
    if (self.quotaError) self.updatedMenuItem.title = [NSString stringWithFormat:@"额度读取失败：%@", self.quotaError];
}

- (void)updateMenuBarTruncationWarning {
    NSButton *button = self.statusItem.button;
    [button layoutSubtreeIfNeeded];
    CGFloat visibleWidth = NSWidth(button.bounds);
    CGFloat requiredWidth = button.intrinsicContentSize.width;
    self.menuSpaceWarningItem.hidden = !(requiredWidth > visibleWidth + 1);
}

- (void)renderTaskItems {
    for (NSMenuItem *item in self.taskMenuItems) [self.menu removeItem:item];
    NSMutableArray<NSMenuItem *> *items = [NSMutableArray array];
    NSInteger insertionIndex = 1;

    if (!self.sessions.count) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"近 5 小时无任务" action:nil keyEquivalent:@""];
        empty.enabled = NO;
        [self.menu insertItem:empty atIndex:insertionIndex];
        [items addObject:empty];
    } else {
        for (CSSessionItem *session in self.sessions) {
            NSString *title = [self compactTitle:session.title maximumLength:34];
            NSString *itemTitle = [NSString stringWithFormat:@"%@  %@", [self titleForActivity:session.activity], title];
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:itemTitle action:nil keyEquivalent:@""];
            item.enabled = NO;
            item.indentationLevel = 1;
            item.image = [NSImage imageWithSystemSymbolName:[self symbolForActivity:session.activity]
                                    accessibilityDescription:[self titleForActivity:session.activity]];
            [self.menu insertItem:item atIndex:insertionIndex++];
            [items addObject:item];
        }
    }
    self.taskMenuItems = items;
}

- (NSInteger)countForActivity:(CSActivity)activity {
    return [self.sessions indexesOfObjectsPassingTest:^BOOL(CSSessionItem *session, NSUInteger index, BOOL *stop) {
        return session.activity == activity;
    }].count;
}

- (NSString *)compactTitle:(NSString *)title maximumLength:(NSUInteger)maximumLength {
    NSString *singleLine = [[title componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    if (singleLine.length <= maximumLength) return singleLine;
    NSRange range = [singleLine rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, maximumLength)];
    return [[singleLine substringWithRange:range] stringByAppendingString:@"…"];
}

- (NSString *)detailForTitle:(NSString *)title bucket:(CSRateBucket *)bucket {
    if (!bucket) return [NSString stringWithFormat:@"%@：当前账号未返回", title];
    NSDate *resetDate = [NSDate dateWithTimeIntervalSince1970:bucket.resetsAt];
    return [NSString stringWithFormat:@"%@：剩余 %ld%% · %@ 重置", title, bucket.remainingPercent, [self.class.resetFormatter stringFromDate:resetDate]];
}

- (NSString *)titleForActivity:(CSActivity)activity {
    if (activity == CSActivityWorking) return @"开发中";
    if (activity == CSActivityCompleted) return @"已完成";
    return @"闲置";
}

- (NSString *)symbolForActivity:(CSActivity)activity {
    if (activity == CSActivityWorking) return @"hammer.fill";
    if (activity == CSActivityCompleted) return @"checkmark.circle.fill";
    return @"circle";
}

+ (NSDateFormatter *)timeFormatter {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"HH:mm:ss";
    });
    return formatter;
}

+ (NSDateFormatter *)resetFormatter {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"M月d日 HH:mm";
    });
    return formatter;
}

@end
