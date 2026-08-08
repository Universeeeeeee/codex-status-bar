#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "CompletionOverlay.h"
#import "Core.h"

static int RunSelfTests(void) {
    NSData *session = [@"{\"timestamp\":\"2026-07-13T08:00:00.000Z\",\"payload\":{\"type\":\"task_started\"}}\n{\"timestamp\":\"2026-07-13T08:02:00.000Z\",\"payload\":{\"type\":\"task_complete\"}}\n" dataUsingEncoding:NSUTF8StringEncoding];
    if (CSParseSessionData(session, NULL) != CSActivityCompleted) return 1;

    NSData *working = [@"{\"timestamp\":\"2026-07-13T08:00:00.000Z\",\"payload\":{\"type\":\"task_started\"}}\n" dataUsingEncoding:NSUTF8StringEncoding];
    if (CSParseSessionData(working, NULL) != CSActivityWorking) return 2;

    NSData *quota = [@"{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":25,\"windowDurationMins\":300,\"resetsAt\":1000},\"secondary\":{\"usedPercent\":40,\"windowDurationMins\":10080,\"resetsAt\":2000}}}}" dataUsingEncoding:NSUTF8StringEncoding];
    CSRateSnapshot *snapshot = CSParseRateLimitResponse(quota);
    if (snapshot.fiveHour.remainingPercent != 75 || snapshot.weekly.remainingPercent != 60) return 3;

    NSData *weeklyOnly = [@"{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":12,\"windowDurationMins\":10080,\"resetsAt\":2000},\"secondary\":null}}}" dataUsingEncoding:NSUTF8StringEncoding];
    snapshot = CSParseRateLimitResponse(weeklyOnly);
    if (snapshot.fiveHour || snapshot.weekly.remainingPercent != 88) return 4;

    CSRateSnapshot *merged = CSMergeRateSnapshots(CSParseRateLimitResponse(quota), snapshot);
    if (merged.fiveHour.remainingPercent != 75 || merged.weekly.remainingPercent != 88) return 5;

    NSDate *now = [NSDate dateWithTimeIntervalSince1970:100000];
    CSActivity visibleActivity;
    if (!CSVisibleSessionActivity(CSActivityCompleted, [now dateByAddingTimeInterval:-9 * 60], now, &visibleActivity) || visibleActivity != CSActivityCompleted) return 6;
    if (!CSVisibleSessionActivity(CSActivityCompleted, [now dateByAddingTimeInterval:-11 * 60], now, &visibleActivity) || visibleActivity != CSActivityIdle) return 7;
    if (CSVisibleSessionActivity(CSActivityIdle, [now dateByAddingTimeInterval:-(5 * 60 * 60 + 1)], now, &visibleActivity)) return 8;
    if (!CSVisibleSessionActivity(CSActivityWorking, [now dateByAddingTimeInterval:-6 * 60 * 60], now, &visibleActivity) || visibleActivity != CSActivityWorking) return 9;

    CSSessionItem *completedTask = [CSSessionItem new];
    completedTask.activity = CSActivityCompleted;
    CSSessionItem *workingTask = [CSSessionItem new];
    workingTask.activity = CSActivityWorking;
    if (CSAggregateSessionActivity(@[completedTask, workingTask]) != CSActivityWorking) return 10;

    puts("All parser tests passed");
    return 0;
}

static int PrintSessions(void) {
    CSSessionScanner *scanner = [CSSessionScanner new];
    for (CSSessionItem *session in scanner.currentSessions) {
        const char *status = session.activity == CSActivityWorking ? "working" :
                             session.activity == CSActivityCompleted ? "completed" : "idle";
        printf("%s\t%s\t%s\n", status, session.threadID.UTF8String, session.title.UTF8String);
    }
    return 0;
}

@interface CSTestOverlayDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic) CSCompletionOverlay *overlay;
@end

@implementation CSTestOverlayDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self.overlay enqueue];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

@end

static int ShowTestOverlay(void) {
    NSString *imagePath = [NSBundle.mainBundle pathForResource:@"Completion" ofType:@"png"];
    NSImage *image = imagePath ? [[NSImage alloc] initWithContentsOfFile:imagePath] : nil;
    if (!image) return 10;

    NSApplication *application = NSApplication.sharedApplication;
    CSTestOverlayDelegate *delegate = [CSTestOverlayDelegate new];
    delegate.overlay = [[CSCompletionOverlay alloc] initWithImage:image];
    delegate.overlay.queueDidDrainHandler = ^{
        [NSApp terminate:nil];
    };
    application.delegate = delegate;
    [application run];
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) return RunSelfTests();
        if (argc > 1 && strcmp(argv[1], "--probe-sessions") == 0) return PrintSessions();
        if (argc > 1 && strcmp(argv[1], "--test-overlay") == 0) return ShowTestOverlay();
        NSApplication *application = NSApplication.sharedApplication;
        CSAppDelegate *delegate = [CSAppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
