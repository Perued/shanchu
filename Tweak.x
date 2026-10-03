// WCBlackListBatchDelete v2 - 微信黑名单批量删除 + 自定义间隔
// 改动: 不依赖 Substrate (纯 runtime swizzle), 适配 TrollFools 注入
//   - 加载自检: 日志 + 屏幕 toast
//   - 修复注入标记提前设置的 bug, 增加悬浮按钮兜底
//   - 删除回调增加 30s 超时, 避免卡死
//   - 日志路径多级回退

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 前向声明

@interface ContactBatchModifyLogic : NSObject
- (void)setM_delegate:(id)delegate;
- (void)batchModContactTypeWithAddContantctAr:(NSArray *)addAr
                           deleteContantctAr:(NSArray *)delAr
                               modContactType:(int)type;
@end

// 以下签名均已对照 8.0.74 二进制的 type encoding 核实
@interface CContactMgr : NSObject
// getContactList:contactType: 的编码是 @24@0:8I16I20, 两个参数都是 unsigned int
- (NSArray *)getContactList:(unsigned int)type contactType:(unsigned int)mask;
// 编码 B28@0:8@16I24, 第一个参数是 CContact 对象
- (BOOL)deleteContact:(id)contact listType:(unsigned int)listType;
@end

@interface MMNewSessionMgr : NSObject
- (void)DeleteSessionOfUser:(NSString *)userName; // v24@0:8@16
@end

#pragma mark - 常量

static NSString *const kWCBLIntervalKey = @"WCBLDeleteInterval";       // 旧版固定间隔, 仅用于迁移
static NSString *const kWCBLMinKey = @"WCBLDeleteIntervalMin";
static NSString *const kWCBLMaxKey = @"WCBLDeleteIntervalMax";
static const NSTimeInterval kWCBLDefaultInterval = 5.0;
static const NSTimeInterval kWCBLMaxInterval = 300.0;
static const NSTimeInterval kWCBLCallbackTimeout = 30.0;
static const BOOL kWCBLShowLoadedToast = YES; // 确认能加载后可改为 NO

#pragma mark - 日志

static NSString *WCBLLogFilePath(void) {
    NSArray *dirs = @[
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: @"",
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: @"",
        NSTemporaryDirectory() ?: @""
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *d in dirs) {
        if (d.length == 0) continue;
        NSString *p = [d stringByAppendingPathComponent:@"WCBL.log"];
        if ([fm fileExistsAtPath:p] || [fm createFileAtPath:p contents:nil attributes:nil]) return p;
    }
    return nil;
}

static void WCBLWriteFileLog(NSString *msg) {
    static dispatch_queue_t q;
    static NSString *path;
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.wcbl.filelog", DISPATCH_QUEUE_SERIAL);
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"MM-dd HH:mm:ss.SSS";
        path = WCBLLogFilePath();
        NSLog(@"[WCBL] 日志文件: %@", path ?: @"(创建失败)");
        if (path) {
            NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
            if ([attr[NSFileSize] unsignedLongLongValue] > 2 * 1024 * 1024)
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }
    });
    if (!path) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];
    dispatch_sync(q, ^{ // 同步写, 保证 ctor 里就能落盘
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    });
}

#define WCBLLog(fmt, ...) do { \
    NSString *_m = [NSString stringWithFormat:@"[WCBL] " fmt, ##__VA_ARGS__]; \
    NSLog(@"%@", _m); \
    WCBLWriteFileLog(_m); \
} while (0)

#pragma mark - 工具函数

static UIWindow *WCBLKeyWindow(void) {
    UIWindow *w = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in ((UIWindowScene *)s).windows) {
            if (win.isKeyWindow) return win;
            if (!w) w = win;
        }
    }
    return w;
}

static void WCBLToast(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = WCBLKeyWindow();
        if (!w) return;
        UILabel *l = [[UILabel alloc] init];
        l.text = [NSString stringWithFormat:@"  %@  ", text];
        l.font = [UIFont systemFontOfSize:14];
        l.textColor = [UIColor whiteColor];
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
        l.layer.cornerRadius = 8;
        l.clipsToBounds = YES;
        [l sizeToFit];
        CGRect f = l.frame; f.size.height = 34; f.size.width += 8;
        f.origin.x = (w.bounds.size.width - f.size.width) / 2;
        f.origin.y = w.safeAreaInsets.top + 60;
        l.frame = f;
        [w addSubview:l];
        [UIView animateWithDuration:0.4 delay:3 options:0 animations:^{ l.alpha = 0; }
                         completion:^(BOOL d){ [l removeFromSuperview]; }];
    });
}

static NSString *WCBLDisplayName(id contact) {
    SEL dn = NSSelectorFromString(@"getContactDisplayName");
    if ([contact respondsToSelector:dn]) {
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(contact, dn);
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        } @catch (NSException *e) {}
    }
    NSArray *keys = @[@"m_nsRemark", @"m_nsNickName", @"nickName", @"remark",
                      @"m_nsUsrName", @"usrName", @"m_nsUserName", @"userName"];
    for (NSString *k in keys) {
        @try {
            id v = [contact valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        } @catch (NSException *e) {}
    }
    return @"(未知)";
}

// 8.0.74 里没有 +[MMServiceCenter defaultCenter], 微信自己用的是:
//   [[MMContext currentContext] getService:[Xxx class]]   (loadContacts 反汇编确认)
static id WCBLGetService(Class cls) {
    if (!cls) return nil;
    @try {
        Class ctxCls = objc_getClass("MMContext");
        SEL cur = NSSelectorFromString(@"currentContext");
        if (ctxCls && [ctxCls respondsToSelector:cur]) {
            id ctx = ((id (*)(id, SEL))objc_msgSend)(ctxCls, cur);
            if ([ctx respondsToSelector:@selector(getService:)])
                return ((id (*)(id, SEL, Class))objc_msgSend)(ctx, @selector(getService:), cls);
        }
        // 兜底: 旧版本才有的 MMServiceCenter defaultCenter (必须先检查是否响应)
        Class scCls = objc_getClass("MMServiceCenter");
        SEL dc = NSSelectorFromString(@"defaultCenter");
        if (scCls && [scCls respondsToSelector:dc]) {
            id c = ((id (*)(id, SEL))objc_msgSend)(scCls, dc);
            if ([c respondsToSelector:@selector(getService:)])
                return ((id (*)(id, SEL, Class))objc_msgSend)(c, @selector(getService:), cls);
        }
    } @catch (NSException *e) { WCBLLog(@"getService 异常: %@", e); }
    return nil;
}

static CContactMgr *WCBLContactMgr(void) {
    Class mgrCls = objc_getClass("CContactMgr");
    if (!mgrCls) { WCBLLog(@"找不到 CContactMgr 类"); return nil; }
    id svc = WCBLGetService(mgrCls);
    if (!svc) WCBLLog(@"getService:CContactMgr 返回 nil");
    return [svc isKindOfClass:mgrCls] ? svc : nil;
}

// 取页面当前的模式: 微信 8.0.74 里 ContactsGenericViewController 的 ivar m_iViewType (long long)
//   0 -> getContactList:8        contactType:-1  (通讯录黑名单)
//   1 -> getContactList:0x800000 contactType:-1  (社交黑名单)
// 依据 -[ContactsGenericViewController loadContacts] 反汇编
static NSArray *WCBLFlattenPageContacts(UIViewController *page) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        id dic = [page valueForKey:@"m_dicAllContacts"];
        if (![dic isKindOfClass:[NSDictionary class]]) return out;
        for (id v in [(NSDictionary *)dic allValues]) {
            if ([v isKindOfClass:[NSArray class]]) {
                for (id c in (NSArray *)v)
                    if ([c respondsToSelector:NSSelectorFromString(@"m_nsUsrName")]) [out addObject:c];
            } else if ([v respondsToSelector:NSSelectorFromString(@"m_nsUsrName")]) {
                [out addObject:v];
            }
        }
    } @catch (NSException *e) { WCBLLog(@"读取页面 m_dicAllContacts 异常: %@", e); }
    return out;
}

static NSArray *WCBLFetchBlackListContacts(UIViewController *page) {
    CContactMgr *mgr = WCBLContactMgr();
    if (!mgr) { WCBLLog(@"CContactMgr 获取失败"); return @[]; }

    long long mode = 0;
    @try {
        id m = [page valueForKey:@"m_iViewType"];
        if ([m respondsToSelector:@selector(longLongValue)]) mode = [m longLongValue];
    } @catch (NSException *e) { WCBLLog(@"读取 m_iViewType 失败: %@", e); }
    unsigned int type = (mode == 1) ? 0x800000u : 8u;
    WCBLLog(@"页面模式 m_iViewType=%lld -> getContactList:0x%x contactType:-1", mode, type);

    NSArray *raw = nil;
    SEL sel = @selector(getContactList:contactType:);
    if ([mgr respondsToSelector:sel]) {
        @try { raw = [mgr getContactList:type contactType:0xFFFFFFFFu]; }
        @catch (NSException *e) { WCBLLog(@"getContactList 异常: %@", e); }
    } else {
        WCBLLog(@"CContactMgr 不响应 getContactList:contactType:");
    }
    WCBLLog(@"getContactList 返回 %lu 个", (unsigned long)raw.count);

    if (raw.count == 0 && page) {
        raw = WCBLFlattenPageContacts(page);
        WCBLLog(@"改读页面自身数据 m_dicAllContacts: %lu 个", (unsigned long)raw.count);
    }

    NSMutableArray *list = [NSMutableArray array];
    SEL selDeleted = NSSelectorFromString(@"isAccountDeleted");
    for (id c in raw) {
        @try {
            if ([c respondsToSelector:selDeleted] && ((BOOL (*)(id, SEL))objc_msgSend)(c, selDeleted)) continue;
            [list addObject:c];
        } @catch (NSException *e) {}
    }
    if (list.count > 0) WCBLLog(@"首个联系人类: %@", NSStringFromClass([list.firstObject class]));
    WCBLLog(@"黑名单联系人 %lu 个", (unsigned long)list.count);
    return list;
}

// 与原生 OnContactBatchModify 回调里的本地清理保持一致:
//   deleteContact:listType:2 / 1, 再 DeleteSessionOfUser:
static void WCBLLocalCleanup(id contact) {
    @try {
        CContactMgr *mgr = WCBLContactMgr();
        if (mgr && [mgr respondsToSelector:@selector(deleteContact:listType:)]) {
            [mgr deleteContact:contact listType:2];
            [mgr deleteContact:contact listType:1];
        }
        NSString *un = nil;
        @try { un = [contact valueForKey:@"m_nsUsrName"]; } @catch (NSException *e) {}
        Class sc = objc_getClass("MMNewSessionMgr");
        if (un.length && sc) {
            id sm = WCBLGetService(sc);
            if ([sm respondsToSelector:@selector(DeleteSessionOfUser:)]) [sm DeleteSessionOfUser:un];
        }
    } @catch (NSException *e) { WCBLLog(@"本地清理异常: %@", e); }
}

#pragma mark - 批量删除 VC

@interface WCBLBatchDeleteViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSArray *contacts;
@property (nonatomic, weak) UIViewController *hostPage;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *selected;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *bottom;
@property (nonatomic, strong) UILabel *minCapLabel;
@property (nonatomic, strong) UILabel *maxCapLabel;
@property (nonatomic, strong) UIStepper *minStepper;
@property (nonatomic, strong) UIStepper *maxStepper;
@property (nonatomic, strong) UILabel *minLabel;
@property (nonatomic, strong) UILabel *maxLabel;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) NSTimeInterval minInterval;
@property (nonatomic, assign) NSTimeInterval maxInterval;
@property (nonatomic, strong) ContactBatchModifyLogic *batchLogic;
@property (nonatomic, strong) NSArray *deleteQueue;
@property (nonatomic, assign) NSInteger deleteIndex;
@property (nonatomic, assign) NSInteger successCount;
@property (nonatomic, assign) NSInteger failCount;
@property (nonatomic, assign) NSInteger token; // 用于识别当前等待中的回调/超时
@property (nonatomic, assign) BOOL isDeleting;
- (instancetype)initWithContacts:(NSArray *)contacts;
// 微信 delegate 回调
- (void)OnContactBatchModify:(id)arg1 withRet:(int)ret errorMsg:(id)msg isNetWorkError:(BOOL)isErr;
@end

@implementation WCBLBatchDeleteViewController

- (instancetype)initWithContacts:(NSArray *)contacts {
    if (self = [super init]) {
        _contacts = contacts;
        _selected = [NSMutableSet set];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        _minInterval = [ud doubleForKey:kWCBLMinKey];
        _maxInterval = [ud doubleForKey:kWCBLMaxKey];
        if (_minInterval < 1) {
            // 迁移旧版固定间隔: 最小=旧值, 最大=旧值+5
            double old = [ud doubleForKey:kWCBLIntervalKey];
            _minInterval = old >= 1 ? old : kWCBLDefaultInterval;
            _maxInterval = _minInterval + 5;
        }
        if (_maxInterval < _minInterval) _maxInterval = _minInterval;
        if (_maxInterval > kWCBLMaxInterval) _maxInterval = kWCBLMaxInterval;
        if (_minInterval > _maxInterval) _minInterval = _maxInterval;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [NSString stringWithFormat:@"黑名单批量删除 (%lu)", (unsigned long)self.contacts.count];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onSelectAllTapped)];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    [self.view addSubview:self.tableView];

    self.bottom = [[UIView alloc] init];
    self.bottom.backgroundColor = [UIColor secondarySystemBackgroundColor];
    [self.view addSubview:self.bottom];

    self.minCapLabel = [[UILabel alloc] init];
    self.minCapLabel.text = @"最小间隔(秒)";
    self.minCapLabel.font = [UIFont systemFontOfSize:14];
    [self.bottom addSubview:self.minCapLabel];

    self.maxCapLabel = [[UILabel alloc] init];
    self.maxCapLabel.text = @"最大间隔(秒)";
    self.maxCapLabel.font = [UIFont systemFontOfSize:14];
    [self.bottom addSubview:self.maxCapLabel];

    self.minLabel = [[UILabel alloc] init];
    self.minLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.bottom addSubview:self.minLabel];
    self.maxLabel = [[UILabel alloc] init];
    self.maxLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.bottom addSubview:self.maxLabel];

    self.minStepper = [[UIStepper alloc] init];
    self.maxStepper = [[UIStepper alloc] init];
    for (UIStepper *st in @[self.minStepper, self.maxStepper]) {
        st.minimumValue = 1;
        st.maximumValue = kWCBLMaxInterval;
        st.stepValue = 1;
        [st addTarget:self action:@selector(onStepperChanged:) forControlEvents:UIControlEventValueChanged];
        [self.bottom addSubview:st];
    }
    self.minStepper.value = self.minInterval;
    self.maxStepper.value = self.maxInterval;
    [self refreshIntervalLabel];

    self.progressView = [[UIProgressView alloc] init];
    [self.bottom addSubview:self.progressView];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = @"就绪";
    [self.bottom addSubview:self.statusLabel];

    self.deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.deleteButton.backgroundColor = [UIColor systemRedColor];
    [self.deleteButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.deleteButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.deleteButton.layer.cornerRadius = 8;
    [self.deleteButton addTarget:self action:@selector(onDeleteTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.bottom addSubview:self.deleteButton];
    [self refreshDeleteButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat inset = self.view.safeAreaInsets.bottom;
    CGFloat bottomH = 176 + inset;
    self.tableView.frame = CGRectMake(0, 0, w, h - bottomH);
    self.bottom.frame = CGRectMake(0, h - bottomH, w, bottomH);
    self.minCapLabel.frame = CGRectMake(16, 6, 120, 30);
    self.minLabel.frame = CGRectMake(140, 6, 60, 30);
    self.minStepper.frame = CGRectMake(210, 6, 100, 30);
    self.maxCapLabel.frame = CGRectMake(16, 40, 120, 30);
    self.maxLabel.frame = CGRectMake(140, 40, 60, 30);
    self.maxStepper.frame = CGRectMake(210, 40, 100, 30);
    self.progressView.frame = CGRectMake(16, 82, w - 32, 10);
    self.statusLabel.frame = CGRectMake(16, 94, w - 32, 20);
    self.deleteButton.frame = CGRectMake(16, 120, w - 32, 44);
}

- (void)onStepperChanged:(UIStepper *)sender {
    if (sender == self.minStepper) {
        self.minInterval = self.minStepper.value;
        if (self.maxInterval < self.minInterval) { self.maxInterval = self.minInterval; self.maxStepper.value = self.maxInterval; }
    } else {
        self.maxInterval = self.maxStepper.value;
        if (self.minInterval > self.maxInterval) { self.minInterval = self.maxInterval; self.minStepper.value = self.minInterval; }
    }
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setDouble:self.minInterval forKey:kWCBLMinKey];
    [ud setDouble:self.maxInterval forKey:kWCBLMaxKey];
    [self refreshIntervalLabel];
}
- (void)refreshIntervalLabel {
    self.minLabel.text = [NSString stringWithFormat:@"%.0f", self.minInterval];
    self.maxLabel.text = [NSString stringWithFormat:@"%.0f", self.maxInterval];
}

// 在 [min, max] 之间随机取一个间隔 (精度 0.001 秒)
- (NSTimeInterval)randomInterval {
    double lo = self.minInterval, hi = self.maxInterval;
    if (hi <= lo) return lo;
    uint32_t steps = (uint32_t)((hi - lo) * 1000.0) + 1;
    return lo + (double)arc4random_uniform(steps) / 1000.0;
}

- (void)onSelectAllTapped {
    BOOL allSelected = self.selected.count == self.contacts.count;
    [self.selected removeAllObjects];
    if (!allSelected) for (NSUInteger i = 0; i < self.contacts.count; i++) [self.selected addObject:@(i)];
    self.navigationItem.rightBarButtonItem.title = allSelected ? @"全选" : @"取消全选";
    [self.tableView reloadData];
    [self refreshDeleteButton];
}

- (void)refreshDeleteButton {
    [self.deleteButton setTitle:[NSString stringWithFormat:@"删除选中 (%lu)", (unsigned long)self.selected.count]
                       forState:UIControlStateNormal];
    self.deleteButton.enabled = !self.isDeleting && self.selected.count > 0;
    self.deleteButton.alpha = self.deleteButton.enabled ? 1.0 : 0.5;
}

#pragma mark TableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.contacts.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"wcbl_cell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    cell.textLabel.text = WCBLDisplayName(self.contacts[ip.row]);
    cell.accessoryType = [self.selected containsObject:@(ip.row)] ?
        UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.isDeleting) return;
    NSNumber *k = @(ip.row);
    if ([self.selected containsObject:k]) [self.selected removeObject:k]; else [self.selected addObject:k];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    [self refreshDeleteButton];
}

#pragma mark 删除引擎

- (void)onDeleteTapped {
    if (self.isDeleting || self.selected.count == 0) return;
    NSMutableArray *queue = [NSMutableArray array];
    NSArray *sorted = [[self.selected allObjects] sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *n in sorted) [queue addObject:self.contacts[n.integerValue]];

    NSString *msg = [NSString stringWithFormat:@"将逐个删除 %lu 个联系人, 每次间隔在 %.0f~%.0f 秒之间随机。删除后不可恢复, 是否继续?",
                     (unsigned long)queue.count, self.minInterval, self.maxInterval];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"确认删除" message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) { [ws startDelete:queue]; }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)startDelete:(NSArray *)queue {
    self.isDeleting = YES;
    self.deleteQueue = queue;
    self.deleteIndex = 0;
    self.successCount = 0;
    self.failCount = 0;
    [self refreshDeleteButton];
    self.navigationItem.rightBarButtonItem.enabled = NO;

    Class logicCls = objc_getClass("ContactBatchModifyLogic");
    if (!logicCls) { [self finishWithError:@"ContactBatchModifyLogic 不存在 (版本不匹配)"]; return; }
    self.batchLogic = [[logicCls alloc] init];
    if ([self.batchLogic respondsToSelector:@selector(setM_delegate:)])
        [self.batchLogic setM_delegate:self];

    WCBLLog(@"开始批量删除, 共 %lu 个, 随机间隔 %.0f~%.0fs", (unsigned long)queue.count, self.minInterval, self.maxInterval);
    [self deleteNext];
}

- (void)deleteNext {
    if (self.deleteIndex >= (NSInteger)self.deleteQueue.count) { [self finishDone]; return; }
    id contact = self.deleteQueue[self.deleteIndex];
    NSString *name = WCBLDisplayName(contact);
    WCBLLog(@"删除 %ld/%lu: %@", (long)(self.deleteIndex + 1), (unsigned long)self.deleteQueue.count, name);
    self.statusLabel.text = [NSString stringWithFormat:@"正在删除 %ld/%lu: %@",
                             (long)(self.deleteIndex + 1), (unsigned long)self.deleteQueue.count, name];
    self.progressView.progress = (float)self.deleteIndex / (float)self.deleteQueue.count;

    NSInteger myToken = ++self.token;
    __weak typeof(self) ws = self;
    // 超时保护: 回调迟迟不来则视为失败并继续
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWCBLCallbackTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) s = ws;
        if (!s || !s.isDeleting || s.token != myToken) return;
        WCBLLog(@"回调超时 idx=%ld, 跳过", (long)s.deleteIndex);
        [s handleResult:-1 message:@"timeout"];
    });

    @try {
        [self.batchLogic batchModContactTypeWithAddContantctAr:nil
                                            deleteContantctAr:@[contact]
                                                modContactType:1];
    } @catch (NSException *e) {
        WCBLLog(@"调用异常: %@", e);
        [self handleResult:-2 message:e.reason];
    }
}

- (void)OnContactBatchModify:(id)arg1 withRet:(int)ret errorMsg:(id)msg isNetWorkError:(BOOL)isErr {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.isDeleting) return;
        [self handleResult:ret message:msg];
    });
}

// 必须在主线程调用
- (void)handleResult:(int)ret message:(id)msg {
    self.token++; // 让对应的超时/重复回调失效
    if (ret == 0) {
        self.successCount++;
        if (self.deleteIndex < (NSInteger)self.deleteQueue.count) WCBLLocalCleanup(self.deleteQueue[self.deleteIndex]);
    }
    else { self.failCount++; WCBLLog(@"删除失败 idx=%ld ret=%d msg=%@", (long)self.deleteIndex, ret, msg); }
    self.deleteIndex++;

    if (self.deleteIndex >= (NSInteger)self.deleteQueue.count) { [self finishDone]; return; }

    NSTimeInterval iv = [self randomInterval];
    WCBLLog(@"等待 %.1fs 后继续 (%ld/%lu)", iv, (long)(self.deleteIndex + 1), (unsigned long)self.deleteQueue.count);
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(iv * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ if (ws.isDeleting) [ws deleteNext]; });
}

- (void)finishDone {
    self.isDeleting = NO;
    self.token++;
    self.batchLogic = nil;
    self.progressView.progress = 1.0;
    NSString *msg = [NSString stringWithFormat:@"完成: 成功 %ld, 失败 %ld",
                     (long)self.successCount, (long)self.failCount];
    self.statusLabel.text = msg;
    WCBLLog(@"%@", msg);
    self.navigationItem.rightBarButtonItem.enabled = YES;
    if (self.successCount > 0) {
        self.contacts = WCBLFetchBlackListContacts(self.hostPage);
        [self.selected removeAllObjects];
        SEL rd = NSSelectorFromString(@"reloadData");
        if ([self.hostPage respondsToSelector:rd]) { @try { ((void (*)(id, SEL))objc_msgSend)(self.hostPage, rd); } @catch (NSException *e) {} }
        self.title = [NSString stringWithFormat:@"黑名单批量删除 (%lu)", (unsigned long)self.contacts.count];
        self.navigationItem.rightBarButtonItem.title = @"全选";
        [self.tableView reloadData];
    }
    [self refreshDeleteButton];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"批量删除完成" message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)finishWithError:(NSString *)msg {
    self.isDeleting = NO;
    self.statusLabel.text = msg;
    WCBLLog(@"%@", msg);
    [self refreshDeleteButton];
    self.navigationItem.rightBarButtonItem.enabled = YES;
}

@end

#pragma mark - 入口按钮

@interface WCBLActionTarget : NSObject
@property (nonatomic, weak) UIViewController *vc;
- (void)open;
@end

@implementation WCBLActionTarget
- (void)open {
    WCBLLog(@"批量删除按钮被点击");
    UIViewController *host = self.vc;
    if (!host) return;
    NSArray *contacts = WCBLFetchBlackListContacts(host);
    if (contacts.count == 0) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"提示"
            message:@"未获取到黑名单联系人 (接口可能不匹配, 详见 WCBL.log)"
            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [host presentViewController:ac animated:YES completion:nil];
        return;
    }
    WCBLBatchDeleteViewController *vc = [[WCBLBatchDeleteViewController alloc] initWithContacts:contacts];
    vc.hostPage = host;
    if (host.navigationController) [host.navigationController pushViewController:vc animated:YES];
    else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [host presentViewController:nav animated:YES completion:nil];
    }
}
@end

static const void *kWCBLInjectedKey = &kWCBLInjectedKey;

static BOOL WCBLIsBlackListPage(UIViewController *vc) {
    NSString *clsName = NSStringFromClass([vc class]);
    if ([clsName rangeOfString:@"BlackList" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    NSString *t = vc.title ?: vc.navigationItem.title;
    return [t isEqualToString:@"通讯录黑名单"] || [t isEqualToString:@"黑名单"];
}

static void WCBLInject(UIViewController *vc) {
    if (objc_getAssociatedObject(vc, kWCBLInjectedKey)) return;
    if (!WCBLIsBlackListPage(vc)) return; // 不匹配时不打标记, 下次还会再检查

    WCBLActionTarget *target = [[WCBLActionTarget alloc] init];
    target.vc = vc;
    objc_setAssociatedObject(vc, kWCBLInjectedKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCBLLog(@"检测到黑名单页面: %@ (title=%@)", NSStringFromClass([vc class]), vc.title);

    // 1) 导航栏按钮
    NSMutableArray *items = [vc.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"批量删除" style:UIBarButtonItemStylePlain
                                                           target:target action:@selector(open)];
    [items addObject:btn];
    vc.navigationItem.rightBarButtonItems = items;

    // 2) 悬浮按钮兜底 (导航栏被微信自定义时仍可用)
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeSystem];
    [fab setTitle:@"批量删除" forState:UIControlStateNormal];
    [fab setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    fab.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    fab.backgroundColor = [UIColor systemRedColor];
    fab.layer.cornerRadius = 20;
    fab.frame = CGRectMake(vc.view.bounds.size.width - 110,
                           vc.view.bounds.size.height - vc.view.safeAreaInsets.bottom - 90, 96, 40);
    fab.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [fab addTarget:target action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:fab];
    WCBLLog(@"已注入批量删除按钮");
}

#pragma mark - Swizzle (无需 Substrate)

static void (*orig_viewDidAppear)(id, SEL, BOOL);

static void wcbl_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    @try {
        WCBLInject(self);
        // 标题可能稍后才设置, 延迟再检查一次
        __weak UIViewController *ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ if (ws) WCBLInject(ws); });
    } @catch (NSException *e) {}
}

__attribute__((constructor))
static void WCBLInit(void) {
    @autoreleasepool {
        WCBLLog(@"WCBlackListBatchDelete v2 加载完成");
        Method m = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
        if (m) {
            orig_viewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(m);
            method_setImplementation(m, (IMP)wcbl_viewDidAppear);
            WCBLLog(@"已 hook viewDidAppear:");
        } else {
            WCBLLog(@"hook 失败: 找不到 viewDidAppear:");
        }
        if (kWCBLShowLoadedToast) {
            __block id obs = [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
                    [[NSNotificationCenter defaultCenter] removeObserver:obs];
                    WCBLToast(@"WCBL 已加载");
                }];
        }
    }
}
