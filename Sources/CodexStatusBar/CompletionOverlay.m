#import "CompletionOverlay.h"

static const NSTimeInterval CSFadeInDuration = 0.8;
static const NSTimeInterval CSFadeOutDuration = 0.4;
static const NSTimeInterval CSMinimumVisibleDuration = 1.0;
static const NSTimeInterval CSMaximumVisibleDuration = 60.0;
static const NSTimeInterval CSInputPollInterval = 0.1;

@interface CSCompletionOverlay ()
@property(nonatomic) NSPanel *panel;
@property(nonatomic) NSView *rootView;
@property(nonatomic) NSVisualEffectView *blurView;
@property(nonatomic) NSImageView *imageView;
@property(nonatomic) NSTimer *inputTimer;
@property(nonatomic) NSTimer *dismissTimer;
@property(nonatomic) NSTimeInterval shownAt;
@property(nonatomic) NSInteger pendingCount;
@property(nonatomic) BOOL showing;
@property(nonatomic) BOOL fadingOut;
@end

@implementation CSCompletionOverlay

- (instancetype)initWithImage:(NSImage *)image {
    self = [super init];
    if (!self) return nil;

    _panel = [[NSPanel alloc] initWithContentRect:NSZeroRect
                                        styleMask:NSWindowStyleMaskBorderless
                                          backing:NSBackingStoreBuffered
                                            defer:YES];
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.level = NSScreenSaverWindowLevel;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary |
                                NSWindowCollectionBehaviorStationary;
    _panel.ignoresMouseEvents = YES;
    _panel.hasShadow = NO;
    _panel.hidesOnDeactivate = NO;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.releasedWhenClosed = NO;

    _rootView = [[NSView alloc] initWithFrame:NSZeroRect];
    _rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _blurView = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    _blurView.material = NSVisualEffectMaterialFullScreenUI;
    _blurView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _blurView.state = NSVisualEffectStateActive;
    _blurView.alphaValue = 0.72;
    _blurView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _imageView.image = image;
    _imageView.imageAlignment = NSImageAlignCenter;
    _imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _imageView.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    [_rootView addSubview:_blurView];
    [_rootView addSubview:_imageView];
    _panel.contentView = _rootView;
    return self;
}

- (void)enqueue {
    if (self.showing) return;
    self.pendingCount += 1;
    if (!self.showing) [self showNext];
}

- (void)setImage:(NSImage *)image {
    self.imageView.animates = NO;
    self.imageView.image = image;
    if (self.showing) [self layoutImageForScreen:self.panel.screen ?: NSScreen.mainScreen];
    self.imageView.animates = self.showing;
}

- (void)layoutImageForScreen:(NSScreen *)screen {
    NSSize size = self.imageView.image.size;
    BOOL animated = NO;
    CGFloat backingScale = screen ? screen.backingScaleFactor : 1;
    for (NSImageRep *representation in self.imageView.image.representations) {
        if (representation.pixelsWide > 0 && representation.pixelsHigh > 0) {
            size = NSMakeSize(representation.pixelsWide / backingScale, representation.pixelsHigh / backingScale);
            animated = [representation isKindOfClass:NSBitmapImageRep.class] &&
                       [[(NSBitmapImageRep *)representation valueForProperty:NSImageFrameCount] integerValue] > 1;
            break;
        }
    }
    if (size.width <= 0 || size.height <= 0) return;
    if (animated) {
        CGFloat scale = MIN(600 / size.width, 600 / size.height);
        size.width *= scale;
        size.height *= scale;
    }
    NSRect bounds = self.rootView.bounds;
    CGFloat scale = MIN(1, MIN(NSWidth(bounds) / size.width, NSHeight(bounds) / size.height));
    size.width *= scale;
    size.height *= scale;
    self.imageView.frame = NSMakeRect(NSMidX(bounds) - size.width / 2,
                                     NSMidY(bounds) - size.height / 2,
                                     size.width, size.height);
}

- (void)dismissAll {
    self.pendingCount = 0;
    [self beginFadeOut];
}

- (void)showNext {
    if (self.pendingCount <= 0) return;
    self.pendingCount -= 1;
    self.showing = YES;
    self.fadingOut = NO;

    NSScreen *screen = [self screenContainingMouse] ?: NSScreen.mainScreen;
    if (!screen) {
        self.showing = NO;
        return;
    }

    [self.panel setFrame:screen.frame display:YES];
    self.rootView.frame = self.panel.contentView.bounds;
    self.blurView.frame = self.rootView.bounds;
    [self layoutImageForScreen:screen];
    self.panel.alphaValue = 0;
    for (NSImageRep *representation in self.imageView.image.representations) {
        if ([representation isKindOfClass:NSBitmapImageRep.class] &&
            [[(NSBitmapImageRep *)representation valueForProperty:NSImageFrameCount] integerValue] > 1) {
            [(NSBitmapImageRep *)representation setProperty:NSImageCurrentFrame withValue:@0];
        }
    }
    self.imageView.animates = YES;
    [self.panel orderFrontRegardless];
    self.shownAt = NSProcessInfo.processInfo.systemUptime;
    [self startInputMonitoring];
    [self scheduleDismissAfter:CSMaximumVisibleDuration - CSFadeOutDuration];

    __weak typeof(self) weakSelf = self;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = CSFadeInDuration;
        weakSelf.panel.animator.alphaValue = 1;
    }];
}

- (void)startInputMonitoring {
    [self.inputTimer invalidate];
    self.inputTimer = [NSTimer timerWithTimeInterval:CSInputPollInterval
                                             target:self
                                           selector:@selector(checkForInput)
                                           userInfo:nil
                                            repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.inputTimer forMode:NSRunLoopCommonModes];
}

- (void)checkForInput {
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - self.shownAt;
    NSTimeInterval inputAge = CGEventSourceSecondsSinceLastEventType(
        kCGEventSourceStateCombinedSessionState,
        kCGAnyInputEventType
    );
    if (inputAge >= elapsed) return;

    [self.inputTimer invalidate];
    self.inputTimer = nil;
    [self scheduleDismissAfter:MAX(0, CSMinimumVisibleDuration - CSFadeOutDuration - elapsed)];
}

- (void)scheduleDismissAfter:(NSTimeInterval)delay {
    [self.dismissTimer invalidate];
    self.dismissTimer = [NSTimer timerWithTimeInterval:delay
                                               target:self
                                             selector:@selector(beginFadeOut)
                                             userInfo:nil
                                              repeats:NO];
    [NSRunLoop.mainRunLoop addTimer:self.dismissTimer forMode:NSRunLoopCommonModes];
}

- (void)beginFadeOut {
    if (!self.showing || self.fadingOut) return;
    self.fadingOut = YES;
    [self.inputTimer invalidate];
    self.inputTimer = nil;
    [self.dismissTimer invalidate];
    self.dismissTimer = nil;

    __weak typeof(self) weakSelf = self;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = CSFadeOutDuration;
        weakSelf.panel.animator.alphaValue = 0;
    } completionHandler:^{
        [weakSelf.panel orderOut:nil];
        weakSelf.imageView.animates = NO;
        weakSelf.showing = NO;
        weakSelf.fadingOut = NO;
        if (weakSelf.pendingCount > 0) {
            [weakSelf showNext];
        } else if (weakSelf.queueDidDrainHandler) {
            weakSelf.queueDidDrainHandler();
        }
    }];
}

- (NSScreen *)screenContainingMouse {
    NSPoint mouseLocation = NSEvent.mouseLocation;
    for (NSScreen *screen in NSScreen.screens) {
        if (NSPointInRect(mouseLocation, screen.frame)) return screen;
    }
    return nil;
}

@end
