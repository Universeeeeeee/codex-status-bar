#import "AppServerClient.h"

@interface CSAppServerClient ()
@property(nonatomic) NSTask *process;
@property(nonatomic) NSFileHandle *input;
@property(nonatomic) NSFileHandle *output;
@property(nonatomic) NSMutableData *buffer;
@property(nonatomic, copy) CSRateCompletion completion;
@property(nonatomic) dispatch_block_t timeoutBlock;
@end

@implementation CSAppServerClient

- (void)fetchRateLimits:(CSRateCompletion)completion {
    if (self.process) return;
    NSURL *executable = [self findExecutable];
    if (!executable) {
        completion(nil, [self error:@"未找到 Codex 可执行文件"]);
        return;
    }

    self.completion = completion;
    self.buffer = [NSMutableData data];
    self.process = [NSTask new];
    self.process.executableURL = executable;
    self.process.arguments = @[@"app-server", @"--listen", @"stdio://"];

    NSPipe *inputPipe = [NSPipe pipe];
    NSPipe *outputPipe = [NSPipe pipe];
    self.process.standardInput = inputPipe;
    self.process.standardOutput = outputPipe;
    self.process.standardError = [NSPipe pipe];
    self.input = inputPipe.fileHandleForWriting;
    self.output = outputPipe.fileHandleForReading;

    __weak typeof(self) weakSelf = self;
    self.output.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf consume:data]; });
    };
    self.process.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.completion) [weakSelf finish:nil error:[weakSelf error:@"Codex app-server 提前退出"]];
        });
    };

    NSError *launchError = nil;
    if (![self.process launchAndReturnError:&launchError]) {
        [self finish:nil error:launchError];
        return;
    }

    [self send:@{
        @"method": @"initialize",
        @"id": @1,
        @"params": @{
            @"clientInfo": @{@"name": @"codex-status-bar", @"title": @"Codex Status Bar", @"version": @"0.1.0"},
            @"capabilities": @{@"experimentalApi": @YES}
        }
    }];

    dispatch_block_t timeout = dispatch_block_create(0, ^{
        if (weakSelf.completion) [weakSelf finish:nil error:[weakSelf error:@"额度查询超时"]];
    });
    self.timeoutBlock = timeout;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), timeout);
}

- (void)consume:(NSData *)data {
    [self.buffer appendData:data];
    while (true) {
        const void *bytes = self.buffer.bytes;
        const void *newline = memchr(bytes, '\n', self.buffer.length);
        if (!newline) break;
        NSUInteger length = (const uint8_t *)newline - (const uint8_t *)bytes;
        NSData *line = [self.buffer subdataWithRange:NSMakeRange(0, length)];
        [self.buffer replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
        [self handleLine:line];
    }
}

- (void)handleLine:(NSData *)data {
    NSDictionary *object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSNumber *identifier = [object[@"id"] isKindOfClass:NSNumber.class] ? object[@"id"] : nil;
    if (identifier.integerValue == 1) {
        [self send:@{@"method": @"initialized", @"params": @{}}];
        [self send:@{@"method": @"account/rateLimits/read", @"id": @2, @"params": @{}}];
    } else if (identifier.integerValue == 2) {
        CSRateSnapshot *snapshot = CSParseRateLimitResponse(data);
        if (snapshot) [self finish:snapshot error:nil];
        else [self finish:nil error:[self error:@"额度接口返回了无法识别的数据"]];
    }
}

- (void)send:(NSDictionary *)message {
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!data) return;
    [self.input writeData:data];
    [self.input writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)finish:(CSRateSnapshot *)snapshot error:(NSError *)error {
    if (self.timeoutBlock) dispatch_block_cancel(self.timeoutBlock);
    self.timeoutBlock = nil;
    self.output.readabilityHandler = nil;
    [self.input closeFile];
    [self.output closeFile];
    if (self.process.running) [self.process terminate];

    CSRateCompletion callback = self.completion;
    self.completion = nil;
    self.process = nil;
    self.input = nil;
    self.output = nil;
    self.buffer = nil;
    if (callback) callback(snapshot, error);
}

- (NSURL *)findExecutable {
    NSArray<NSString *> *candidates = @[
        @"/Applications/ChatGPT.app/Contents/Resources/codex",
        @"/Applications/Codex.app/Contents/Resources/codex",
        @"/opt/homebrew/bin/codex",
        @"/usr/local/bin/codex"
    ];
    for (NSString *path in candidates) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) return [NSURL fileURLWithPath:path];
    }
    return nil;
}

- (NSError *)error:(NSString *)message {
    return [NSError errorWithDomain:@"CodexStatusBar" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
