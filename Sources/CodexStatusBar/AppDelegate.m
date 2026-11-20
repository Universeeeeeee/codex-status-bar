#import "AppDelegate.h"
#import "AppServerClient.h"
#import "CompletionOverlay.h"
#import "Core.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const CSCompletionAlertsEnabledKey = @"CompletionAlertsEnabled";
static const CGFloat CSMenuWidth = 366;

@interface CSMenuTaskView : NSView
- (instancetype)initWithStatus:(NSString *)status
                          title:(NSString *)title
                      symbolName:(NSString *)symbolName
                           color:(NSColor *)color
                          header:(BOOL)header;
- (void)updateStatus:(NSString *)status
                title:(NSString *)title
            symbolName:(NSString *)symbolName
                 color:(NSColor *)color;
@end

@interface CSMenuInfoView : NSView
- (instancetype)initWithLabel:(NSString *)label detail:(NSString *)detail muted:(BOOL)muted;
- (void)updateLabel:(NSString *)label detail:(NSString *)detail;
@end

@implementation CSMenuTaskView {
    NSImageView *_iconView;
    NSTextField *_statusField;
    NSTextField *_titleField;
}

- (instancetype)initWithStatus:(NSString *)status
                          title:(NSString *)title
                      symbolName:(NSString *)symbolName
                           color:(NSColor *)color
                          header:(BOOL)header {
    CGFloat height = header ? 32 : 28;
    self = [super initWithFrame:NSMakeRect(0, 0, CSMenuWidth, height)];
    if (!self) return nil;
    _iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(16, (height - 18) / 2, 18, 18)];
    _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:_iconView];

    _statusField = [NSTextField labelWithString:@""];
    _statusField.frame = NSMakeRect(42, (height - 20) / 2, header ? 36 : 57, 20);
    _statusField.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _statusField.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_statusField];

    _titleField = [NSTextField labelWithString:@""];
    CGFloat titleX = header ? 80 : 104;
    _titleField.frame = NSMakeRect(titleX, (height - 20) / 2, CSMenuWidth - titleX - 16, 20);
    _titleField.font = [NSFont systemFontOfSize:13];
    _titleField.textColor = header ? NSColor.secondaryLabelColor : NSColor.labelColor;
    _titleField.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_titleField];
    [self updateStatus:status title:title symbolName:symbolName color:color];
    return self;
}

- (void)updateStatus:(NSString *)status
                title:(NSString *)title
            symbolName:(NSString *)symbolName
                 color:(NSColor *)color {
    _statusField.stringValue = status ?: @"";
    _titleField.stringValue = title ?: @"";
    _statusField.textColor = color ?: NSColor.secondaryLabelColor;
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    if (image) {
        image = [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightMedium]];
        image.template = YES;
        _iconView.image = image;
        _iconView.contentTintColor = color ?: NSColor.secondaryLabelColor;
    }
}
@end

@implementation CSMenuInfoView {
    NSTextField *_labelField;
    NSTextField *_detailField;
}

- (instancetype)initWithLabel:(NSString *)label detail:(NSString *)detail muted:(BOOL)muted {
    CGFloat height = muted ? 24 : 30;
    self = [super initWithFrame:NSMakeRect(0, 0, CSMenuWidth, height)];
    if (!self) return nil;
    _labelField = [NSTextField labelWithString:@""];
    _labelField.frame = NSMakeRect(16, (height - 20) / 2, 60, 20);
    _labelField.font = [NSFont systemFontOfSize:muted ? 12 : 13 weight:muted ? NSFontWeightRegular : NSFontWeightSemibold];
    _labelField.textColor = NSColor.secondaryLabelColor;
    [self addSubview:_labelField];

    _detailField = [NSTextField labelWithString:@""];
    _detailField.frame = NSMakeRect(80, (height - 20) / 2, CSMenuWidth - 96, 20);
    _detailField.font = [NSFont systemFontOfSize:muted ? 12 : 13];
    _detailField.textColor = muted ? NSColor.secondaryLabelColor : NSColor.labelColor;
    _detailField.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_detailField];
    [self updateLabel:label detail:detail];
    return self;
}

- (void)updateLabel:(NSString *)label detail:(NSString *)detail {
    _labelField.stringValue = label;
    _detailField.stringValue = detail;
    self.toolTip = [NSString stringWithFormat:@"%@ %@", label, detail];
}
@end

@interface CSAppDelegate ()
@property(nonatomic) NSStatusItem *statusItem;
@property(nonatomic) CSSessionScanner *scanner;
@property(nonatomic) CSAppServerClient *client;
@property(nonatomic) CSCompletionOverlay *completionOverlay;
@property(nonatomic) NSMenu *menu;
@property(nonatomic) NSMenuItem *statusMenuItem;
@property(nonatomic) NSArray<NSMenuItem *> *taskMenuItems;
@property(nonatomic) NSMenuItem *weeklyMenuItem;
@property(nonatomic) NSMenuItem *updatedMenuItem;
@property(nonatomic) CSMenuTaskView *statusHeaderView;
@property(nonatomic) CSMenuInfoView *weeklyInfoView;
@property(nonatomic) CSMenuInfoView *updatedInfoView;
@property(nonatomic) NSMenuItem *menuSpaceWarningItem;
@property(nonatomic) NSMenuItem *completionAlertsMenuItem;
@property(nonatomic) NSTimer *statusTimer;
@property(nonatomic) NSTimer *quotaTimer;
@property(nonatomic) CSActivity activity;
@property(nonatomic) NSArray<CSSessionItem *> *sessions;
@property(nonatomic) CSRateSnapshot *rateLimits;
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
    self.weeklyMenuItem = [[NSMenuItem alloc] initWithTitle:@"周额度：读取中" action:nil keyEquivalent:@""];
    self.updatedMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.menuSpaceWarningItem = [[NSMenuItem alloc] initWithTitle:@"菜单栏空间不足：额度文字可能被截断" action:nil keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    self.statusHeaderView = [[CSMenuTaskView alloc] initWithStatus:@"任务"
                                                               title:@"读取中"
                                                           symbolName:@"hammer.fill"
                                                                color:NSColor.secondaryLabelColor
                                                               header:YES];
    self.statusMenuItem.view = self.statusHeaderView;
    [menu addItem:self.statusMenuItem];
    [menu addItem:NSMenuItem.separatorItem];

    for (NSMenuItem *item in @[self.weeklyMenuItem, self.updatedMenuItem]) {
        item.enabled = NO;
        [menu addItem:item];
    }
    self.weeklyInfoView = [[CSMenuInfoView alloc] initWithLabel:@"周额度" detail:@"读取中" muted:NO];
    self.weeklyMenuItem.view = self.weeklyInfoView;
    self.updatedInfoView = [[CSMenuInfoView alloc] initWithLabel:@"更新于" detail:@"读取中" muted:YES];
    self.updatedMenuItem.view = self.updatedInfoView;
    self.menuSpaceWarningItem.enabled = NO;
    self.menuSpaceWarningItem.hidden = YES;
    [menu addItem:self.menuSpaceWarningItem];
    [menu addItem:NSMenuItem.separatorItem];

    self.completionAlertsMenuItem = [[NSMenuItem alloc] initWithTitle:@"全屏提醒（完成 / 等待回复）" action:@selector(toggleCompletionAlerts:) keyEquivalent:@""];
    self.completionAlertsMenuItem.target = self;
    self.completionAlertsMenuItem.image = [self symbolImage:@"bell"];
    self.completionAlertsMenuItem.state = [NSUserDefaults.standardUserDefaults boolForKey:CSCompletionAlertsEnabledKey] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:self.completionAlertsMenuItem];

    NSMenuItem *chooseImage = [[NSMenuItem alloc] initWithTitle:@"更换提示图片…" action:@selector(chooseCompletionImage:) keyEquivalent:@""];
    chooseImage.target = self;
    chooseImage.image = [NSImage imageWithSystemSymbolName:@"photo" accessibilityDescription:@"更换提示图片"];
    [menu addItem:chooseImage];

    NSMenuItem *preview = [[NSMenuItem alloc] initWithTitle:@"预览全屏提示" action:@selector(previewCompletionImage:) keyEquivalent:@""];
    preview.target = self;
    preview.image = [NSImage imageWithSystemSymbolName:@"play.rectangle" accessibilityDescription:@"预览全屏提示"];
    [menu addItem:preview];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"刷新额度" action:@selector(refreshQuota) keyEquivalent:@"r"];
    refresh.target = self;
    refresh.image = [NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"刷新额度"];
    refresh.attributedTitle = [[NSAttributedString alloc] initWithString:refresh.title
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:[NSFont menuFontOfSize:0].pointSize weight:NSFontWeightSemibold]}];
    [menu addItem:refresh];

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
    [self.updatedInfoView updateLabel:@"额度" detail:@"更新中…"];
    __weak typeof(self) weakSelf = self;
    [self.client fetchRateLimits:^(CSRateSnapshot *snapshot, NSError *error) {
        CSAppDelegate *delegate = weakSelf;
        if (!delegate) return;
        delegate.rateLimits = CSMergeRateSnapshots(delegate.rateLimits, snapshot);
        NSString *label = error ? @"读取失败" : @"更新于";
        NSString *detail = error ? error.localizedDescription : [delegate.class.timeFormatter stringFromDate:NSDate.date];
        delegate.updatedMenuItem.title = [NSString stringWithFormat:@"%@ %@", label, detail];
        [delegate.updatedInfoView updateLabel:label detail:detail];
        [delegate render];
    }];
}

- (void)quit {
    [NSApp terminate:nil];
}

- (void)render {
    NSInteger workingCount = [self countForActivity:CSActivityWorking];
    NSInteger completedCount = [self countForActivity:CSActivityCompleted];
    NSInteger idleCount = [self countForActivity:CSActivityIdle];
    NSInteger waitingCount = [self countForActivity:CSActivityWaitingForInput];
    self.activity = CSAggregateSessionActivity(self.sessions);

    NSString *symbol = [self symbolForActivity:self.activity];
    NSString *weekly = self.rateLimits.weekly ? [NSString stringWithFormat:@"%ld%%", self.rateLimits.weekly.remainingPercent] : @"--";

    NSString *taskSummary;
    if (workingCount || completedCount || waitingCount) {
        taskSummary = [NSString stringWithFormat:@"待回复 %ld · 开发 %ld · 完成 %ld", waitingCount, workingCount, completedCount];
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
    NSString *summary = [NSString stringWithFormat:@"待回复 %ld · 开发中 %ld · 已完成 %ld · 闲置 %ld", waitingCount, workingCount, completedCount, idleCount];
    self.statusMenuItem.title = [NSString stringWithFormat:@"任务：%@", summary];
    [self.statusHeaderView updateStatus:@"任务" title:summary symbolName:symbol color:[self colorForActivity:self.activity]];
    [self renderTaskItems];
    NSString *weeklyDetail = [self detailForBucket:self.rateLimits.weekly];
    self.weeklyMenuItem.title = [NSString stringWithFormat:@"周额度：%@", weeklyDetail];
    [self.weeklyInfoView updateLabel:@"周额度" detail:weeklyDetail];
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
            NSString *title = [[session.title componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
            NSString *status = [self titleForActivity:session.activity];
            NSString *itemTitle = [NSString stringWithFormat:@"%@  %@", status, title];
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:itemTitle action:nil keyEquivalent:@""];
            item.enabled = NO;
            item.view = [[CSMenuTaskView alloc] initWithStatus:status
                                                          title:title
                                                      symbolName:[self symbolForActivity:session.activity]
                                                           color:[self colorForActivity:session.activity]
                                                          header:NO];
            item.view.toolTip = title;
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

- (NSString *)detailForBucket:(CSRateBucket *)bucket {
    if (!bucket) return @"当前账号未返回";
    NSDate *resetDate = [NSDate dateWithTimeIntervalSince1970:bucket.resetsAt];
    return [NSString stringWithFormat:@"剩余 %ld%% · %@ 重置", bucket.remainingPercent, [self.class.resetFormatter stringFromDate:resetDate]];
}

- (NSString *)titleForActivity:(CSActivity)activity {
    if (activity == CSActivityWaitingForInput) return @"等待回复";
    if (activity == CSActivityWorking) return @"开发中";
    if (activity == CSActivityCompleted) return @"已完成";
    return @"闲置";
}

- (NSColor *)colorForActivity:(CSActivity)activity {
    if (activity == CSActivityWaitingForInput) return NSColor.systemOrangeColor;
    if (activity == CSActivityWorking) return NSColor.controlAccentColor;
    if (activity == CSActivityCompleted) return NSColor.systemGreenColor;
    return NSColor.secondaryLabelColor;
}

- (NSString *)symbolForActivity:(CSActivity)activity {
    if (activity == CSActivityWaitingForInput) return @"questionmark.bubble.fill";
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
