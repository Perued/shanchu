// WCBlackListBatchDelete - 微信黑名单多选一键删除 + 自定义删除间隔
// 分析基础: 微信 8.0.74 二进制
//   - 删除后端: ContactBatchModifyLogic -batchModContactTypeWithAddContantctAr:deleteContantctAr:modContactType:
//     (modContactType=1 为删除, 实证自 MultiDeleteContactsViewController -deleteSelectedContacts 反汇编)
//   - 单批上限: getMaxBatchOnceNumber = 50, 本 tweak 逐个删除以支持自定义间隔
//   - 黑名单判断: CContactMgr -isContactBlack:
//   - 服务: [MMServiceCenter defaultCenter] getService:

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 前向声明 (微信内部类)

@interface MMServiceCenter : NSObject
+ (instancetype)defaultCenter;
- (id)getService:(Class)cls;
@end

@interface ContactBatchModifyLogic : NSObject
- (void)setM_delegate:(id)delegate;
- (void)batchModContactTypeWithAddContantctAr:(NSArray *)addAr
                           deleteContantctAr:(NSArray *)delAr
                               modContactType:(int)type;
@end

@interface CContactMgr : NSObject
- (void)getAllContactList:(NSMutableArray *)list listType:(int)type;
- (NSArray *)getContactList:(id)arg1 contactType:(int)type;
- (BOOL)isContactBlack:(id)contact;
@end

// UIViewController 扩展方法前向声明 (供 %hook 内调用)
@interface UIViewController (WCBLAdditions)
- (void)wcbl_maybeInject;
- (void)wcbl_openBatchDelete;
@end

@protocol ContactBatchModifyLogicDelegate <NSObject>
@optional
- (void)OnContactBatchModify:(id)arg1 withRet:(int)arg2 errorMsg:(id)arg3 isNetWorkError:(BOOL)arg4;
@end

#pragma mark - 常量

static NSString *const kWCBLIntervalKey = @"WCBLDeleteInterval";
static const NSTimeInterval kWCBLDefaultInterval = 5.0;
static const NSTimeInterval kWCBLMaxInterval = 300.0;

// 文件日志路径: /var/mobile/WCBL.log (Filza 直接打开即可, 无需抓系统日志)
static NSString *WCBLLogFilePath(void) { return @"/var/mobile/WCBL.log"; }

static void WCBLWriteFileLog(NSString *msg) {
    static dispatch_queue_t q;
    static NSFileHandle *fh;
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.wcbl.filelog", DISPATCH_QUEUE_SERIAL);
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"MM-dd HH:mm:ss.SSS";
        NSString *path = WCBLLogFilePath();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
        if ([attr[NSFileSize] unsignedLongLongValue] > 2 * 1024 * 1024) {
            [fm removeItemAtPath:path error:nil]; // 超过 2MB 清空重来
        }
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
        [fh seekToEndOfFile];
    });
    if (!fh) return;
    NSString *proc = [[NSProcessInfo processInfo] processName];
    dispatch_async(q, ^{
        NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                          [df stringFromDate:[NSDate date]], proc, msg];
        @try { [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
        @catch (NSException *e) {}
    });
}

// 同时写 NSLog(系统日志) 和文件日志
#define WCBLLog(fmt, ...) do { \
    NSString *_wcbl_m = [NSString stringWithFormat:@"[WCBL] " fmt, ##__VA_ARGS__]; \
    NSLog(@"%@", _wcbl_m); \
    WCBLWriteFileLog(_wcbl_m); \
} while(0)

#pragma mark - 工具函数

// 取联系人显示名 (多 key 兼容)
static NSString *WCBLDisplayName(id contact) {
    NSArray *nickKeys = @[@"m_nsNickName", @"nickName", @"m_nsRemark", @"remark"];
    for (NSString *k in nickKeys) {
        @try {
            id v = [contact valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        } @catch (NSException *e) {}
    }
    NSArray *userKeys = @[@"m_nsUsrName", @"usrName", @"m_nsUserName", @"userName"];
    for (NSString *k in userKeys) {
        @try {
            id v = [contact valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        } @catch (NSException *e) {}
    }
    return @"(未知)";
}

// 取 CContactMgr 单例
static CContactMgr *WCBLContactMgr(void) {
    Class centerCls = objc_getClass("MMServiceCenter");
    Class mgrCls = objc_getClass("CContactMgr");
    if (!centerCls || !mgrCls) return nil;
    id center = [centerCls defaultCenter];
    if (![center respondsToSelector:@selector(getService:)]) return nil;
    id svc = [center getService:mgrCls];
    return [svc isKindOfClass:mgrCls] ? svc : nil;
}

// 获取黑名单联系人数组
static NSArray *WCBLFetchBlackListContacts(void) {
    CContactMgr *mgr = WCBLContactMgr();
    if (!mgr) { WCBLLog(@"CContactMgr 获取失败"); return @[]; }

    NSMutableArray *all = [NSMutableArray array];
    // getAllContactList:listType: 为填充式 (NSMutableArray*, int), 反汇编确认 x2=数组 x3=类型
    if ([mgr respondsToSelector:@selector(getAllContactList:listType:)]) {
        for (int t = 0; t <= 3; t++) {
            @try {
                NSUInteger before = all.count;
                [mgr getAllContactList:all listType:t];
                WCBLLog(@"getAllContactList:listType:%d 新增 %lu", t, (unsigned long)(all.count - before));
            } @catch (NSException *e) {
                WCBLLog(@"listType %d 异常: %@", t, e);
            }
        }
    }
    // 备用: getContactList:contactType:
    if (all.count == 0 && [mgr respondsToSelector:@selector(getContactList:contactType:)]) {
        @try {
            NSArray *r = [mgr getContactList:nil contactType:0];
            if ([r isKindOfClass:[NSArray class]]) [all addObjectsFromArray:r];
        } @catch (NSException *e) {}
    }
    WCBLLog(@"共取到 %lu 个联系人, 开始过滤黑名单", (unsigned long)all.count);

    NSMutableArray *black = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    BOOL canCheck = [mgr respondsToSelector:@selector(isContactBlack:)];
    for (id c in all) {
        @try {
            BOOL isBL = canCheck ? (BOOL)[mgr isContactBlack:c] : NO;
            if (isBL) {
                // 去重 (按指针)
                NSValue *key = [NSValue valueWithNonretainedObject:c];
                if (![seen containsObject:key]) { [seen addObject:key]; [black addObject:c]; }
            }
        } @catch (NSException *e) {}
    }
    WCBLLog(@"黑名单联系人 %lu 个", (unsigned long)black.count);
    return black;
}

#pragma mark - 批量删除 VC

@interface WCBLBatchDeleteViewController : UIViewController
<UITableViewDelegate, UITableViewDataSource, ContactBatchModifyLogicDelegate>
@property (nonatomic, strong) NSArray *contacts;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *selected; // 选中下标
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIStepper *stepper;
@property (nonatomic, strong) UILabel *intervalLabel;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) NSTimeInterval interval;
// 删除引擎
@property (nonatomic, strong) ContactBatchModifyLogic *batchLogic;
@property (nonatomic, strong) NSArray *deleteQueue;
@property (nonatomic, assign) NSInteger deleteIndex;
@property (nonatomic, assign) NSInteger successCount;
@property (nonatomic, assign) NSInteger failCount;
@property (nonatomic, assign) BOOL isDeleting;
- (instancetype)initWithContacts:(NSArray *)contacts;
@end

@implementation WCBLBatchDeleteViewController

- (instancetype)initWithContacts:(NSArray *)contacts {
    if (self = [super init]) {
        _contacts = contacts;
        _selected = [NSMutableSet set];
        _interval = [[NSUserDefaults standardUserDefaults] doubleForKey:kWCBLIntervalKey];
        if (_interval < 1) _interval = kWCBLDefaultInterval;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [NSString stringWithFormat:@"黑名单批量删除 (%lu)", (unsigned long)self.contacts.count];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 全选按钮
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain
                                       target:self action:@selector(onSelectAllTapped)];

    CGFloat bottomH = 150;
    CGRect bounds = self.view.bounds;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, bounds.size.height - bottomH)
                                                 style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    UIView *bottom = [[UIView alloc] initWithFrame:CGRectMake(0, bounds.size.height - bottomH, bounds.size.width, bottomH)];
    bottom.backgroundColor = [UIColor secondarySystemBackgroundColor];
    bottom.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:bottom];

    // 间隔设置行
    UILabel *cap = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, 120, 30)];
    cap.text = @"删除间隔(秒)";
    cap.font = [UIFont systemFontOfSize:14];
    [bottom addSubview:cap];

    self.intervalLabel = [[UILabel alloc] initWithFrame:CGRectMake(140, 8, 60, 30)];
    self.intervalLabel.font = [UIFont boldSystemFontOfSize:16];
    [bottom addSubview:self.intervalLabel];

    self.stepper = [[UIStepper alloc] initWithFrame:CGRectMake(210, 8, 100, 30)];
    self.stepper.minimumValue = 1;
    self.stepper.maximumValue = kWCBLMaxInterval;
    self.stepper.stepValue = 1;
    self.stepper.value = self.interval;
    [self.stepper addTarget:self action:@selector(onStepperChanged) forControlEvents:UIControlEventValueChanged];
    [bottom addSubview:self.stepper];
    [self refreshIntervalLabel];

    // 进度
    self.progressView = [[UIProgressView alloc] initWithFrame:CGRectMake(16, 48, bounds.size.width - 32, 10)];
    self.progressView.progress = 0;
    [bottom addSubview:self.progressView];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, bounds.size.width - 32, 20)];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = @"就绪";
    [bottom addSubview:self.statusLabel];

    // 删除按钮
    self.deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.deleteButton.frame = CGRectMake(16, 86, bounds.size.width - 32, 48);
    self.deleteButton.backgroundColor = [UIColor systemRedColor];
    [self.deleteButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.deleteButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.deleteButton.layer.cornerRadius = 8;
    [self.deleteButton addTarget:self action:@selector(onDeleteTapped) forControlEvents:UIControlEventTouchUpInside];
    [bottom addSubview:self.deleteButton];
    [self refreshDeleteButton];
}

- (void)onStepperChanged {
    self.interval = self.stepper.value;
    [[NSUserDefaults standardUserDefaults] setDouble:self.interval forKey:kWCBLIntervalKey];
    [self refreshIntervalLabel];
}
- (void)refreshIntervalLabel {
    self.intervalLabel.text = [NSString stringWithFormat:@"%.0f", self.interval];
}

- (void)onSelectAllTapped {
    BOOL allSelected = self.selected.count == self.contacts.count;
    [self.selected removeAllObjects];
    if (!allSelected) {
        for (NSInteger i = 0; i < self.contacts.count; i++)
            [self.selected addObject:@(i)];
    }
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
    if ([self.selected containsObject:k]) [self.selected removeObject:k];
    else [self.selected addObject:k];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    [self refreshDeleteButton];
}

#pragma mark 删除引擎 (逐个 + 自定义间隔)

- (void)onDeleteTapped {
    if (self.isDeleting || self.selected.count == 0) return;
    NSMutableArray *queue = [NSMutableArray array];
    for (NSNumber *n in self.selected) [queue addObject:self.contacts[n.integerValue]];

    NSString *msg = [NSString stringWithFormat:@"将逐个删除 %lu 个联系人, 间隔 %.0f 秒。删除后不可恢复, 是否继续?",
                     (unsigned long)queue.count, self.interval];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"确认删除"
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a){ [ws startDelete:queue]; }]];
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
    if (!logicCls) {
        [self finishWithError:@"ContactBatchModifyLogic 不存在 (版本不匹配)"];
        return;
    }
    self.batchLogic = [[logicCls alloc] init];
    if ([self.batchLogic respondsToSelector:@selector(setM_delegate:)])
        [self.batchLogic setM_delegate:self];

    WCBLLog(@"开始批量删除, 共 %lu 个, 间隔 %.0fs", (unsigned long)queue.count, self.interval);
    [self deleteNext];
}

- (void)deleteNext {
    if (self.deleteIndex >= self.deleteQueue.count) { [self finishDone]; return; }
    id contact = self.deleteQueue[self.deleteIndex];
    NSString *name = WCBLDisplayName(contact);
    WCBLLog(@"删除 %ld/%lu: %@", (long)(self.deleteIndex + 1), (unsigned long)self.deleteQueue.count, name);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = [NSString stringWithFormat:@"正在删除 %ld/%lu: %@",
                                 (long)(self.deleteIndex + 1), (unsigned long)self.deleteQueue.count, name];
        self.progressView.progress = (float)self.deleteIndex / (float)self.deleteQueue.count;
    });
    // modContactType=1 为删除 (实证自 deleteSelectedContacts 反汇编)
    [self.batchLogic batchModContactTypeWithAddContantctAr:nil
                                        deleteContantctAr:@[contact]
                                            modContactType:1];
}

// ContactBatchModifyLogicDelegate 回调
- (void)OnContactBatchModify:(id)arg1 withRet:(int)ret errorMsg:(id)msg isNetWorkError:(BOOL)isErr {
    NSInteger done = self.deleteIndex + 1;
    if (ret == 0) self.successCount++;
    else { self.failCount++; WCBLLog(@"删除失败 idx=%ld ret=%d msg=%@", (long)self.deleteIndex, ret, msg); }
    self.deleteIndex = done;

    if (self.deleteIndex >= self.deleteQueue.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishDone]; });
        return;
    }
    // 自定义间隔后删下一个
    NSTimeInterval iv = self.interval;
    WCBLLog(@"等待 %.0fs 后继续 (%ld/%lu)", iv, (long)(done + 1), (unsigned long)self.deleteQueue.count);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(iv * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self deleteNext]; });
}

- (void)finishDone {
    self.isDeleting = NO;
    self.batchLogic = nil;
    self.progressView.progress = 1.0;
    NSString *msg = [NSString stringWithFormat:@"完成: 成功 %ld, 失败 %ld",
                     (long)self.successCount, (long)self.failCount];
    self.statusLabel.text = msg;
    WCBLLog(@"%@", msg);
    [self refreshDeleteButton];
    self.navigationItem.rightBarButtonItem.enabled = YES;
    // 刷新列表 (重新拉取黑名单)
    if (self.successCount > 0) {
        NSArray *fresh = WCBLFetchBlackListContacts();
        self.contacts = fresh;
        [self.selected removeAllObjects];
        self.title = [NSString stringWithFormat:@"黑名单批量删除 (%lu)", (unsigned long)fresh.count];
        [self.tableView reloadData];
        [self refreshDeleteButton];
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"批量删除完成" message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)finishWithError:(NSString *)msg {
    self.isDeleting = NO;
    self.statusLabel.text = msg;
    [self refreshDeleteButton];
    self.navigationItem.rightBarButtonItem.enabled = YES;
}

@end

#pragma mark - 入口注入 (黑名单页面)

%hook UIViewController

%new
- (void)wcbl_maybeInject {
    static const void *kKey = &kKey;
    if (objc_getAssociatedObject(self, kKey)) return;
    objc_setAssociatedObject(self, kKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *clsName = NSStringFromClass([self class]);
    BOOL match = [clsName rangeOfString:@"BlackList" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (!match) {
        NSString *t = self.title ?: self.navigationItem.title;
        if ([t isEqualToString:@"通讯录黑名单"]) match = YES;
    }
    if (!match) return;

    WCBLLog(@"检测到黑名单页面: %@ (title=%@ navTitle=%@)", clsName, self.title, self.navigationItem.title);
    // 追加到现有右上角按钮后面, 不覆盖页面原有按钮
    NSMutableArray *items = [self.navigationItem.rightBarButtonItems mutableCopy];
    if (!items) {
        items = [NSMutableArray array];
        if (self.navigationItem.rightBarButtonItem) [items addObject:self.navigationItem.rightBarButtonItem];
    }
    for (UIBarButtonItem *it in items) {
        if ([it.title isEqualToString:@"批量删除"]) return; // 已加过
    }
    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"批量删除"
                                                            style:UIBarButtonItemStylePlain
                                                           target:self
                                                           action:@selector(wcbl_openBatchDelete)];
    [items addObject:btn];
    self.navigationItem.rightBarButtonItems = items;
    WCBLLog(@"已注入批量删除按钮");
}

%new
- (void)wcbl_openBatchDelete {
    NSArray *contacts = WCBLFetchBlackListContacts();
    if (contacts.count == 0) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"提示"
                                                                    message:@"未获取到黑名单联系人 (可能页面识别或接口不匹配, 详见日志)"
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }
    WCBLBatchDeleteViewController *vc = [[WCBLBatchDeleteViewController alloc] initWithContacts:contacts];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self wcbl_maybeInject];
}

%end

#pragma mark - 构造

%ctor {
    WCBLLog(@"WCBlackListBatchDelete 加载完成");
}
