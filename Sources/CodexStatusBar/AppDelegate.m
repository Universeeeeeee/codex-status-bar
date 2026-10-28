#import "AppDelegate.h"
#import "AppServerClient.h"
#import "CompletionOverlay.h"
#import "Core.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const CSCompletionAlertsEnabledKey = @"CompletionAlertsEnabled";

@interface CSAppDelegate ()
@property(nonatomic) NSStatusItem *statusItem;
@property(nonatomic) CSSessionScanner *scanner;
@property(nonatomic) CSAppServerClient *client;
@property(nonatomic) CSCompletionOverlay *completionOverlay;
@property(nonatomic) NSMenu *menu;
@property(nonatomic) NSMenuItem *statusMenuItem;
@property(nonatomic) NSMenuItem *tasksSeparator;
@property(nonatomic) NSArray<NSMenuItem *> *taskMenuItems;
@property(nonatomic) NSMenuItem *fiveHourMenuItem;
@property(nonatomic) NSMenuItem *weeklyMenuItem;
@property(nonatomic) NSMenuItem *updatedMenuItem;
@property(nonatomic) NSMenuItem *menuSpaceWarningItem;
@property(nonatomic) NSMenuItem *completionAlertsMenuItem;
@property(nonatomic) NSMenuItem *restoreCompletionImageMenuItem;
@property(nonatomic) NSTimer *statusTimer;
@property(nonatomic) NSTimer *quotaTimer;
@property(nonatomic) CSActivity activity;
@property(nonatomic) NSArray<CSSessionItem *> *sessions;
@property(nonatomic) CSRateSnapshot *rateLimits;
@property(nonatomic) NSString *quotaError;
@property(nonatomic) BOOL statusRefreshInFlight;
@property(nonatomic) CSCompletionTracker *completionTracker;
@property(nonatomic) dispatch_queue_t scanQueue;
@property(nonatomic, copy) NSString *lastRenderedTitle;
@property(nonatomic) BOOL taskItemsDirty;
@end

@implementation CSAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSUserDefaults.standardUserDefaults registerDefaults:@{CSCompletionAlertsEnabledKey: @YES}];
    // 固定串行队列: 原来每次都丢到 global concurrent queue, 会让 libdispatch
    // 反复创建并保留 worker 线程 (采样时可见约 10 个空闲 worker 线程)
    self.scanQueue = dispatch_queue_create("local.codex.statusbar.scan", DISPATCH_QUEUE_SERIAL);
    self.taskItemsDirty = YES;
    self.scanner = [CSSessionScanner new];
    self.client = [CSAppServerClient new];
    NSImage *completionImage = [self savedCompletionImage] ?: [self defaultCompletionImage];
    if (completionImage) self.completionOverlay = [[CSCompletionOverlay alloc] initWithImage:completionImage];
    self.sessions = @[];
    self.taskMenuItems = @[];
    self.completionTracker = [CSCompletionTracker new];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    [self configureMenu];
    [self refreshStatus];
    [self refreshQuota];

    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
    // tolerance 让系统可以合并定时器唤醒, 显著降低空闲功耗; 3 秒的精度对这个用途没有意义
    self.statusTimer.tolerance = 1.0;
    self.quotaTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(refreshQuota) userInfo:nil repeats:YES];
    self.quotaTimer.tolerance = 10.0;
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
    self.fiveHourMenuItem = [[NSMenuItem alloc] initWithTitle:@"5 小时额度：读取中" action:nil keyEquivalent:@""];
    self.weeklyMenuItem = [[NSMenuItem alloc] initWithTitle:@"周额度：读取中" action:nil keyEquivalent:@""];
    self.updatedMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.menuSpaceWarningItem = [[NSMenuItem alloc] initWithTitle:@"菜单栏空间不足：额度文字可能被截断" action:nil keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];
    self.tasksSeparator = NSMenuItem.separatorItem;
    [menu addItem:self.tasksSeparator];

    for (NSMenuItem *item in @[self.fiveHourMenuItem, self.weeklyMenuItem, self.updatedMenuItem]) {
        item.enabled = NO;
        [menu addItem:item];
    }
    self.menuSpaceWarningItem.enabled = NO;
    self.menuSpaceWarningItem.hidden = YES;
    [menu addItem:self.menuSpaceWarningItem];
    [menu addItem:NSMenuItem.separatorItem];

    self.completionAlertsMenuItem = [[NSMenuItem alloc] initWithTitle:@"全屏完成提醒" action:@selector(toggleCompletionAlerts:) keyEquivalent:@""];
    self.completionAlertsMenuItem.target = self;
    self.completionAlertsMenuItem.state = [NSUserDefaults.standardUserDefaults boolForKey:CSCompletionAlertsEnabledKey] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:self.completionAlertsMenuItem];

    NSMenuItem *chooseImage = [[NSMenuItem alloc] initWithTitle:@"更换提示图片…" action:@selector(chooseCompletionImage:) keyEquivalent:@""];
    chooseImage.target = self;
    chooseImage.image = [NSImage imageWithSystemSymbolName:@"photo" accessibilityDescription:@"更换提示图片"];
    [menu addItem:chooseImage];

    self.restoreCompletionImageMenuItem = [[NSMenuItem alloc] initWithTitle:@"恢复默认图片" action:@selector(restoreCompletionImage:) keyEquivalent:@""];
    self.restoreCompletionImageMenuItem.target = self;
    [menu addItem:self.restoreCompletionImageMenuItem];

    NSMenuItem *preview = [[NSMenuItem alloc] initWithTitle:@"预览全屏提示" action:@selector(previewCompletionImage:) keyEquivalent:@""];
    preview.target = self;
    preview.image = [NSImage imageWithSystemSymbolName:@"play.rectangle" accessibilityDescription:@"预览全屏提示"];
    [menu addItem:preview];
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

- (NSURL *)completionImageURL {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"Codex Status Bar" isDirectory:YES] URLByAppendingPathComponent:@"CompletionImage"];
}

- (NSImage *)savedCompletionImage {
    NSData *data = [NSData dataWithContentsOfURL:[self completionImageURL]];
    NSImage *image = data ? [[NSImage alloc] initWithData:data] : nil;
    return image.isValid ? image : nil;
}

- (NSImage *)defaultCompletionImage {
    NSString *path = [NSBundle.mainBundle pathForResource:@"Completion" ofType:@"png"];
    return path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
}

- (BOOL)setCompletionImageFromURL:(NSURL *)url error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) return NO;
    NSImage *image = [[NSImage alloc] initWithData:data];
    if (!image.isValid) {
        if (error) *error = [NSError errorWithDomain:@"CodexStatusBar" code:2 userInfo:@{NSLocalizedDescriptionKey: @"无法读取此图片，请选择有效的 GIF 或静态图片。"}];
        return NO;
    }
    NSURL *destination = [self completionImageURL];
    if (![NSFileManager.defaultManager createDirectoryAtURL:destination.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error] ||
        ![data writeToURL:destination options:NSDataWritingAtomic error:error]) return NO;
    if (self.completionOverlay) [self.completionOverlay setImage:image];
    else self.completionOverlay = [[CSCompletionOverlay alloc] initWithImage:image];
    return YES;
}

- (void)chooseCompletionImage:(id)sender {
    [self.completionOverlay dismissAll];
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"更换全屏提示图片";
    panel.allowedContentTypes = @[UTTypeImage];
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    [NSApp activateIgnoringOtherApps:YES];
    if ([panel runModal] != NSModalResponseOK) return;
    NSError *error = nil;
    if (![self setCompletionImageFromURL:panel.URL error:&error]) [NSApp presentError:error];
}

- (void)restoreCompletionImage:(id)sender {
    NSURL *url = [self completionImageURL];
    NSError *error = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path] &&
        ![NSFileManager.defaultManager removeItemAtURL:url error:&error]) {
        [NSApp presentError:error];
        return;
    }
    NSImage *image = [self defaultCompletionImage];
    if (image) [self.completionOverlay setImage:image];
}

- (void)previewCompletionImage:(id)sender {
    [self.completionOverlay enqueue];
}

- (void)toggleCompletionAlerts:(NSMenuItem *)sender {
    BOOL enabled = ![NSUserDefaults.standardUserDefaults boolForKey:CSCompletionAlertsEnabledKey];
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:CSCompletionAlertsEnabledKey];
    sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (!enabled) [self.completionOverlay dismissAll];
}

- (void)refreshStatus {
    if (self.statusRefreshInFlight) return;
    self.statusRefreshInFlight = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.scanQueue, ^{
        NSArray<CSSessionItem *> *sessions = [weakSelf.scanner currentSessions];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.statusRefreshInFlight = NO;
            [strongSelf handleCompletionTransitions:sessions];
            // 会话列表没变化就整段跳过重绘。改状态栏标题、重建菜单项、
            // 以及 updateMenuBarTruncationWarning 里的强制布局都很贵,
            // 而每 3 秒重绘一次纯属浪费。
            if ([strongSelf sessions:sessions isSameAs:strongSelf.sessions]) return;
            strongSelf.sessions = sessions;
            strongSelf.taskItemsDirty = YES;
            [strongSelf render];
        });
    });
}

// 轻量比较: 只有会话集合真的变了才重绘界面
- (BOOL)sessions:(NSArray<CSSessionItem *> *)newSessions isSameAs:(NSArray<CSSessionItem *> *)oldSessions {
    if (newSessions.count != oldSessions.count) return NO;
    for (NSUInteger index = 0; index < newSessions.count; index++) {
        CSSessionItem *left = newSessions[index];
        CSSessionItem *right = oldSessions[index];
        if (left.activity != right.activity) return NO;
        if (![left.threadID isEqualToString:right.threadID]) return NO;
        if (left.title != right.title && ![left.title isEqualToString:right.title]) return NO;
        if (left.updatedAt != right.updatedAt && ![left.updatedAt isEqualToDate:right.updatedAt]) return NO;
    }
    return YES;
}

- (void)handleCompletionTransitions:(NSArray<CSSessionItem *> *)sessions {
    NSDate *snapshotAt = NSDate.date;
    for (CSSessionItem *session in sessions) {
        if ([self.completionTracker consumeSession:session atDate:snapshotAt] &&
            [NSUserDefaults.standardUserDefaults boolForKey:CSCompletionAlertsEnabledKey]) {
            [self.completionOverlay enqueue];
        }
    }
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

    NSString *taskSummary;
    if (workingCount || completedCount) {
        taskSummary = [NSString stringWithFormat:@"开发 %ld · 完成 %ld", workingCount, completedCount];
    } else {
        taskSummary = @"闲置";
    }
    NSString *statusTitle = [NSString stringWithFormat:@"周 %@", weekly];
    self.statusItem.button.title = statusTitle;
    self.statusItem.button.image = [self symbolImage:symbol];
    self.statusItem.button.imagePosition = NSImageLeading;
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"Codex 状态与额度\n%@\n任务：%@", statusTitle, taskSummary];
    // 只有标题真的变了才重新做排版测量: layoutSubtreeIfNeeded 会触发
    // NSButtonDrawVerticallyCenteredTitle → CoreText 造字排版, 原来每 3 秒跑一次
    if (![statusTitle isEqualToString:self.lastRenderedTitle]) {
        self.lastRenderedTitle = statusTitle;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf updateMenuBarTruncationWarning];
        });
    }
    self.statusMenuItem.title = [NSString stringWithFormat:@"任务：开发中 %ld · 已完成 %ld · 闲置 %ld", workingCount, completedCount, idleCount];
    self.statusMenuItem.image = [self symbolImage:symbol];
    [self renderTaskItems];
    self.fiveHourMenuItem.title = [self detailForTitle:@"5 小时额度" bucket:self.rateLimits.fiveHour];
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
    // 会话没变化就不重建菜单项 (removeItem + insertItem 会牵动整个 NSMenu 布局)
    if (!self.taskItemsDirty) return;
    self.taskItemsDirty = NO;

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
            item.image = [self symbolImage:[self symbolForActivity:session.activity]];
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

// 缓存系统符号图片。原来每次重绘都为状态栏按钮和每个菜单项新建一张 NSImage,
// 每 3 秒重建最多 100 张 —— 纯浪费。
- (NSImage *)symbolImage:(NSString *)name {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    NSImage *image = cache[name];
    if (!image) {
        image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
        if (image) cache[name] = image;
    }
    return image;
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
