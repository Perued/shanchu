// WCBlackListBatchDelete v3
// 微信黑名单批量删除 + 自定义间隔
// Runtime Swizzle，无需 Substrate
// 适配 TrollFools 注入

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - 前向声明

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

#pragma mark - 常量

static NSString *const kWCBLIntervalKey = @"WCBLDeleteInterval";

static const NSTimeInterval kWCBLDefaultInterval = 5.0;
static const NSTimeInterval kWCBLMaxInterval = 300.0;
static const NSTimeInterval kWCBLCallbackTimeout = 30.0;

static const BOOL kWCBLShowLoadedToast = YES;

#pragma mark - 日志

static NSString *WCBLLogFilePath(void) {

    NSArray *dirs = @[
        NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory,
            NSUserDomainMask,
            YES
        ).firstObject ?: @"",

        NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory,
            NSUserDomainMask,
            YES
        ).firstObject ?: @"",

        NSTemporaryDirectory() ?: @""
    ];

    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *d in dirs) {

        if (d.length == 0) {
            continue;
        }

        NSString *p =
        [d stringByAppendingPathComponent:@"WCBL.log"];

        if ([fm fileExistsAtPath:p]) {
            return p;
        }

        if ([fm createFileAtPath:p
                         contents:nil
                       attributes:nil]) {
            return p;
        }
    }

    return nil;
}

static void WCBLWriteFileLog(NSString *msg) {

    static dispatch_queue_t q;
    static NSString *path;
    static NSDateFormatter *df;
    static dispatch_once_t once;

    dispatch_once(&once, ^{

        q = dispatch_queue_create(
            "com.wcbl.filelog",
            DISPATCH_QUEUE_SERIAL
        );

        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"MM-dd HH:mm:ss.SSS";

        path = WCBLLogFilePath();

        NSLog(@"[WCBL] 日志文件: %@",
              path ?: @"(创建失败)");

        if (path) {

            NSDictionary *attr =
            [[NSFileManager defaultManager]
             attributesOfItemAtPath:path
             error:nil];

            unsigned long long size =
            [attr[NSFileSize] unsignedLongLongValue];

            if (size > 2ULL * 1024ULL * 1024ULL) {

                [[NSFileManager defaultManager]
                 removeItemAtPath:path
                 error:nil];

                [[NSFileManager defaultManager]
                 createFileAtPath:path
                 contents:nil
                 attributes:nil];
            }
        }
    });

    if (!path || msg.length == 0) {
        return;
    }

    NSString *line =
    [NSString stringWithFormat:@"%@ %@\n",
     [df stringFromDate:[NSDate date]],
     msg];

    /*
     * 异步写日志，避免主线程因为磁盘 IO 阻塞。
     */
    dispatch_async(q, ^{

        @autoreleasepool {

            NSFileHandle *fh =
            [NSFileHandle fileHandleForWritingAtPath:path];

            if (!fh) {

                [[NSFileManager defaultManager]
                 createFileAtPath:path
                 contents:nil
                 attributes:nil];

                fh =
                [NSFileHandle fileHandleForWritingAtPath:path];
            }

            if (!fh) {
                return;
            }

            @try {

                [fh seekToEndOfFile];

                NSData *data =
                [line dataUsingEncoding:NSUTF8StringEncoding];

                if (data) {
                    [fh writeData:data];
                }

                [fh closeFile];

            } @catch (NSException *e) {

                NSLog(@"[WCBL] 写日志异常: %@", e);
            }
        }
    });
}

#define WCBLLog(fmt, ...)                                      \
do {                                                           \
    NSString *_m = [NSString stringWithFormat:@"[WCBL] " fmt, \
                    ##__VA_ARGS__];                            \
    NSLog(@"%@", _m);                                          \
    WCBLWriteFileLog(_m);                                       \
} while (0)

#pragma mark - Window

static UIWindow *WCBLKeyWindow(void) {

    UIWindow *fallback = nil;

    UIApplication *app =
    [UIApplication sharedApplication];

    if (@available(iOS 13.0, *)) {

        for (UIScene *scene in app.connectedScenes) {

            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *ws =
            (UIWindowScene *)scene;

            for (UIWindow *win in ws.windows) {

                if (win.isKeyWindow) {
                    return win;
                }

                if (!fallback) {
                    fallback = win;
                }
            }
        }

    } else {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

        for (UIWindow *win in app.windows) {

            if (win.isKeyWindow) {
                return win;
            }

            if (!fallback) {
                fallback = win;
            }
        }

#pragma clang diagnostic pop
    }

    return fallback;
}

#pragma mark - Toast

static void WCBLToast(NSString *text) {

    dispatch_async(dispatch_get_main_queue(), ^{

        UIWindow *w = WCBLKeyWindow();

        if (!w) {
            return;
        }

        UILabel *label =
        [[UILabel alloc] init];

        label.text =
        [NSString stringWithFormat:@"  %@  ", text];

        label.font =
        [UIFont systemFontOfSize:14];

        label.textColor =
        [UIColor whiteColor];

        label.backgroundColor =
        [UIColor colorWithWhite:0 alpha:0.8];

        label.layer.cornerRadius = 8.0;
        label.clipsToBounds = YES;

        [label sizeToFit];

        CGRect f = label.frame;

        f.size.height = 34.0;
        f.size.width += 8.0;

        f.origin.x =
        (w.bounds.size.width - f.size.width) / 2.0;

        f.origin.y =
        w.safeAreaInsets.top + 60.0;

        label.frame = f;

        label.alpha = 1.0;

        [w addSubview:label];

        [UIView animateWithDuration:0.4
                              delay:3.0
                            options:0
                         animations:^{
            label.alpha = 0.0;
        }
                         completion:^(BOOL finished) {
            [label removeFromSuperview];
        }];
    });
}

#pragma mark - 联系人名称

static NSString *WCBLDisplayName(id contact) {

    if (!contact) {
        return @"(未知)";
    }

    NSArray *keys = @[
        @"m_nsRemark",
        @"m_nsNickName",
        @"nickName",
        @"remark",
        @"m_nsUsrName",
        @"usrName",
        @"m_nsUserName",
        @"userName"
    ];

    for (NSString *key in keys) {

        @try {

            id value =
            [contact valueForKey:key];

            if ([value isKindOfClass:[NSString class]]) {

                NSString *s = (NSString *)value;

                if (s.length > 0) {
                    return s;
                }
            }

        } @catch (NSException *e) {
        }
    }

    return @"(未知)";
}

#pragma mark - ContactMgr

static CContactMgr *WCBLContactMgr(void) {

    Class centerCls =
    objc_getClass("MMServiceCenter");

    Class mgrCls =
    objc_getClass("CContactMgr");

    if (!centerCls || !mgrCls) {

        WCBLLog(
            @"MMServiceCenter/CContactMgr 不存在"
        );

        return nil;
    }

    id center = nil;

    @try {

        center =
        [centerCls defaultCenter];

    } @catch (NSException *e) {

        WCBLLog(
            @"MMServiceCenter defaultCenter 异常: %@",
            e
        );

        return nil;
    }

    if (!center ||
        ![center respondsToSelector:@selector(getService:)]) {

        WCBLLog(@"MMServiceCenter getService 不存在");

        return nil;
    }

    id service = nil;

    @try {

        service =
        [center getService:mgrCls];

    } @catch (NSException *e) {

        WCBLLog(
            @"getService 异常: %@",
            e
        );

        return nil;
    }

    if (![service isKindOfClass:mgrCls]) {

        WCBLLog(
            @"CContactMgr 获取失败，实际对象=%@",
            service
        );

        return nil;
    }

    return service;
}

#pragma mark - 获取黑名单

static NSArray *WCBLFetchBlackListContacts(void) {

    CContactMgr *mgr =
    WCBLContactMgr();

    if (!mgr) {
        return @[];
    }

    WCBLLog(
        @"mgr=%@ class=%@",
        mgr,
        NSStringFromClass([mgr class])
    );

    NSMutableArray *all =
    [NSMutableArray array];

    BOOL hasGet =
    [mgr respondsToSelector:
     @selector(getAllContactList:listType:)];

    WCBLLog(
        @"respondsTo getAllContactList:listType: %d",
        hasGet
    );

    if (!hasGet) {

        WCBLLog(
            @"当前 CContactMgr 不支持 getAllContactList:listType:"
        );

        return @[];
    }

    for (int type = 0; type <= 3; type++) {

        @try {

            NSUInteger before =
            all.count;

            WCBLLog(
                @"调用 getAllContactList listType:%d",
                type
            );

            [mgr getAllContactList:all
                          listType:type];

            NSUInteger after =
            all.count;

            WCBLLog(
                @"listType:%d 新增 %lu",
                type,
                (unsigned long)(after - before)
            );

        } @catch (NSException *e) {

            WCBLLog(
                @"listType:%d 异常: %@",
                type,
                e
            );
        }
    }

    WCBLLog(
        @"共获取联系人 %lu 个",
        (unsigned long)all.count
    );

    if (all.count == 0) {
        return @[];
    }

    /*
     * 这里仍然使用对象指针去重，
     * 不擅自猜测微信联系人对象的唯一 ID 字段。
     */
    NSHashTable *seen =
    [NSHashTable hashTableWithOptions:
     NSPointerFunctionsOpaquePersonality |
     NSPointerFunctionsObjectPointerPersonality];

    NSMutableArray *black =
    [NSMutableArray array];

    BOOL canCheck =
    [mgr respondsToSelector:
     @selector(isContactBlack:)];

    if (!canCheck) {

        WCBLLog(
            @"isContactBlack: 不存在"
        );

        return @[];
    }

    NSUInteger index = 0;

    for (id contact in all) {

        if (index % 100 == 0) {

            WCBLLog(
                @"isContactBlack 检查 %lu/%lu",
                (unsigned long)index,
                (unsigned long)all.count
            );
        }

        index++;

        @try {

            BOOL isBlack =
            [mgr isContactBlack:contact];

            if (isBlack &&
                ![seen containsObject:contact]) {

                [seen addObject:contact];

                [black addObject:contact];
            }

        } @catch (NSException *e) {

            WCBLLog(
                @"isContactBlack 异常: %@",
                e
            );
        }
    }

    WCBLLog(
        @"黑名单联系人 %lu 个",
        (unsigned long)black.count
    );

    return black;
}

#pragma mark - 批量删除 VC

@interface WCBLBatchDeleteViewController :
UIViewController
<UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, strong) NSArray *contacts;

@property (nonatomic, strong)
NSMutableSet<NSNumber *> *selected;

@property (nonatomic, strong)
UITableView *tableView;

@property (nonatomic, strong)
UIView *bottom;

@property (nonatomic, strong)
UILabel *capLabel;

@property (nonatomic, strong)
UIStepper *stepper;

@property (nonatomic, strong)
UILabel *intervalLabel;

@property (nonatomic, strong)
UIButton *deleteButton;

@property (nonatomic, strong)
UIProgressView *progressView;

@property (nonatomic, strong)
UILabel *statusLabel;

@property (nonatomic, assign)
NSTimeInterval interval;

@property (nonatomic, strong)
ContactBatchModifyLogic *batchLogic;

@property (nonatomic, strong)
NSArray *deleteQueue;

@property (nonatomic, assign)
NSInteger deleteIndex;

@property (nonatomic, assign)
NSInteger successCount;

@property (nonatomic, assign)
NSInteger failCount;

/*
 * 当前删除请求 token
 */
@property (nonatomic, assign)
NSUInteger token;

/*
 * 当前批量任务 ID
 */
@property (nonatomic, assign)
NSUInteger batchID;

/*
 * 当前请求是否正在等待回调
 */
@property (nonatomic, assign)
BOOL waitingCallback;

@property (nonatomic, assign)
BOOL isDeleting;

- (instancetype)initWithContacts:(NSArray *)contacts;

- (void)OnContactBatchModify:(id)arg1
                     withRet:(int)ret
                    errorMsg:(id)msg
              isNetWorkError:(BOOL)isErr;

@end

#pragma mark - Implementation

@implementation WCBLBatchDeleteViewController

- (instancetype)initWithContacts:(NSArray *)contacts {

    if (self = [super init]) {

        _contacts =
        [contacts copy] ?: @[];

        _selected =
        [NSMutableSet set];

        _interval =
        [[NSUserDefaults standardUserDefaults]
         doubleForKey:kWCBLIntervalKey];

        if (_interval < 1.0) {
            _interval = kWCBLDefaultInterval;
        }

        if (_interval > kWCBLMaxInterval) {
            _interval = kWCBLMaxInterval;
        }

        _token = 0;
        _batchID = 0;
        _waitingCallback = NO;
        _isDeleting = NO;
    }

    return self;
}

#pragma mark 生命周期

- (void)viewDidLoad {

    [super viewDidLoad];

    self.title =
    [NSString stringWithFormat:
     @"黑名单批量删除 (%lu)",
     (unsigned long)self.contacts.count];

    self.view.backgroundColor =
    [UIColor systemBackgroundColor];

    self.navigationItem.rightBarButtonItem =
    [[UIBarButtonItem alloc]
     initWithTitle:@"全选"
     style:UIBarButtonItemStylePlain
     target:self
     action:@selector(onSelectAllTapped)];

    self.tableView =
    [[UITableView alloc]
     initWithFrame:CGRectZero
     style:UITableViewStylePlain];

    self.tableView.delegate = self;
    self.tableView.dataSource = self;

    [self.view addSubview:self.tableView];

    self.bottom =
    [[UIView alloc] init];

    self.bottom.backgroundColor =
    [UIColor secondarySystemBackgroundColor];

    [self.view addSubview:self.bottom];

    self.capLabel =
    [[UILabel alloc] init];

    self.capLabel.text =
    @"删除间隔(秒)";

    self.capLabel.font =
    [UIFont systemFontOfSize:14];

    [self.bottom addSubview:self.capLabel];

    self.intervalLabel =
    [[UILabel alloc] init];

    self.intervalLabel.font =
    [UIFont boldSystemFontOfSize:16];

    [self.bottom addSubview:self.intervalLabel];

    self.stepper =
    [[UIStepper alloc] init];

    self.stepper.minimumValue = 1;
    self.stepper.maximumValue =
    kWCBLMaxInterval;

    self.stepper.stepValue = 1;
    self.stepper.value = self.interval;

    [self.stepper addTarget:self
                     action:@selector(onStepperChanged)
           forControlEvents:UIControlEventValueChanged];

    [self.bottom addSubview:self.stepper];

    [self refreshIntervalLabel];

    self.progressView =
    [[UIProgressView alloc] init];

    [self.bottom addSubview:self.progressView];

    self.statusLabel =
    [[UILabel alloc] init];

    self.statusLabel.font =
    [UIFont systemFontOfSize:12];

    self.statusLabel.textColor =
    [UIColor secondaryLabelColor];

    self.statusLabel.text =
    @"就绪";

    self.statusLabel.numberOfLines = 1;

    [self.bottom addSubview:self.statusLabel];

    self.deleteButton =
    [UIButton buttonWithType:UIButtonTypeSystem];

    self.deleteButton.backgroundColor =
    [UIColor systemRedColor];

    [self.deleteButton
     setTitleColor:[UIColor whiteColor]
     forState:UIControlStateNormal];

    self.deleteButton.titleLabel.font =
    [UIFont boldSystemFontOfSize:17];

    self.deleteButton.layer.cornerRadius = 8;

    [self.deleteButton addTarget:self
                          action:@selector(onDeleteTapped)
                forControlEvents:UIControlEventTouchUpInside];

    [self.bottom addSubview:self.deleteButton];

    [self refreshDeleteButton];
}

- (void)viewDidLayoutSubviews {

    [super viewDidLayoutSubviews];

    CGFloat width =
    self.view.bounds.size.width;

    CGFloat height =
    self.view.bounds.size.height;

    CGFloat safeBottom =
    self.view.safeAreaInsets.bottom;

    CGFloat bottomHeight =
    140.0 + safeBottom;

    self.tableView.frame =
    CGRectMake(
        0,
        0,
        width,
        MAX(0, height - bottomHeight)
    );

    self.bottom.frame =
    CGRectMake(
        0,
        height - bottomHeight,
        width,
        bottomHeight
    );

    self.capLabel.frame =
    CGRectMake(
        16,
        8,
        120,
        30
    );

    self.intervalLabel.frame =
    CGRectMake(
        140,
        8,
        60,
        30
    );

    self.stepper.frame =
    CGRectMake(
        210,
        8,
        100,
        30
    );

    self.progressView.frame =
    CGRectMake(
        16,
        48,
        MAX(0, width - 32),
        10
    );

    self.statusLabel.frame =
    CGRectMake(
        16,
        60,
        MAX(0, width - 32),
        20
    );

    self.deleteButton.frame =
    CGRectMake(
        16,
        86,
        MAX(0, width - 32),
        44
    );
}

#pragma mark 设置

- (void)onStepperChanged {

    self.interval =
    MIN(
        MAX(self.stepper.value, 1.0),
        kWCBLMaxInterval
    );

    [[NSUserDefaults standardUserDefaults]
     setDouble:self.interval
     forKey:kWCBLIntervalKey];

    [self refreshIntervalLabel];
}

- (void)refreshIntervalLabel {

    self.intervalLabel.text =
    [NSString stringWithFormat:
     @"%.0f",
     self.interval];
}

#pragma mark 全选

- (void)onSelectAllTapped {

    BOOL allSelected =
    self.contacts.count > 0 &&
    self.selected.count == self.contacts.count;

    [self.selected removeAllObjects];

    if (!allSelected) {

        for (NSUInteger i = 0;
             i < self.contacts.count;
             i++) {

            [self.selected addObject:@(i)];
        }
    }

    self.navigationItem.rightBarButtonItem.title =
    allSelected ? @"全选" : @"取消全选";

    [self.tableView reloadData];

    [self refreshDeleteButton];
}

- (void)refreshDeleteButton {

    [self.deleteButton
     setTitle:
     [NSString stringWithFormat:
      @"删除选中 (%lu)",
      (unsigned long)self.selected.count]
     forState:UIControlStateNormal];

    BOOL enabled =
    !self.isDeleting &&
    self.selected.count > 0;

    self.deleteButton.enabled =
    enabled;

    self.deleteButton.alpha =
    enabled ? 1.0 : 0.5;
}

#pragma mark TableView

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {

    return self.contacts.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    static NSString *identifier =
    @"wcbl_cell";

    UITableViewCell *cell =
    [tableView
     dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {

        cell =
        [[UITableViewCell alloc]
         initWithStyle:UITableViewCellStyleDefault
         reuseIdentifier:identifier];
    }

    if (indexPath.row <
        (NSInteger)self.contacts.count) {

        cell.textLabel.text =
        WCBLDisplayName(
            self.contacts[indexPath.row]
        );
    } else {

        cell.textLabel.text =
        @"(未知)";
    }

    cell.accessoryType =
    [self.selected
     containsObject:@(indexPath.row)]
    ?
    UITableViewCellAccessoryCheckmark
    :
    UITableViewCellAccessoryNone;

    return cell;
}

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {

    [tableView deselectRowAtIndexPath:indexPath
                              animated:YES];

    if (self.isDeleting) {
        return;
    }

    NSNumber *key =
    @(indexPath.row);

    if ([self.selected containsObject:key]) {

        [self.selected removeObject:key];

    } else {

        [self.selected addObject:key];
    }

    [tableView reloadRowsAtIndexPaths:@[indexPath]
                     withRowAnimation:UITableViewRowAnimationNone];

    [self refreshDeleteButton];
}

#pragma mark 删除

- (void)onDeleteTapped {

    if (self.isDeleting ||
        self.selected.count == 0) {

        return;
    }

    NSMutableArray *queue =
    [NSMutableArray array];

    NSArray *sorted =
    [[self.selected allObjects]
     sortedArrayUsingSelector:@selector(compare:)];

    for (NSNumber *number in sorted) {

        NSInteger index =
        number.integerValue;

        if (index >= 0 &&
            index < (NSInteger)self.contacts.count) {

            [queue addObject:
             self.contacts[index]];
        }
    }

    if (queue.count == 0) {
        return;
    }

    NSString *message =
    [NSString stringWithFormat:
     @"将逐个删除 %lu 个联系人, 间隔 %.0f 秒。删除后不可恢复, 是否继续?",
     (unsigned long)queue.count,
     self.interval];

    UIAlertController *alert =
    [UIAlertController
     alertControllerWithTitle:@"确认删除"
     message:message
     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
     [UIAlertAction
      actionWithTitle:@"取消"
      style:UIAlertActionStyleCancel
      handler:nil]];

    __weak typeof(self) weakSelf =
    self;

    [alert addAction:
     [UIAlertAction
      actionWithTitle:@"删除"
      style:UIAlertActionStyleDestructive
      handler:^(UIAlertAction *action) {

        __strong typeof(weakSelf) strongSelf =
        weakSelf;

        if (!strongSelf) {
            return;
        }

        [strongSelf startDelete:queue];
    }]];

    [self presentViewController:alert
                       animated:YES
                     completion:nil];
}

#pragma mark 开始任务

- (void)startDelete:(NSArray *)queue {

    if (self.isDeleting ||
        queue.count == 0) {

        return;
    }

    self.isDeleting = YES;

    self.deleteQueue =
    [queue copy];

    self.deleteIndex = 0;
    self.successCount = 0;
    self.failCount = 0;

    /*
     * 每次新的批量任务生成新的 batchID。
     */
    self.batchID++;

    self.token++;

    self.waitingCallback = NO;

    [self refreshDeleteButton];

    self.navigationItem.rightBarButtonItem.enabled =
    NO;

    Class logicClass =
    objc_getClass(
        "ContactBatchModifyLogic"
    );

    if (!logicClass) {

        [self finishWithError:
         @"ContactBatchModifyLogic 不存在 (版本不匹配)"];

        return;
    }

    @try {

        self.batchLogic =
        [[logicClass alloc] init];

    } @catch (NSException *exception) {

        [self finishWithError:
         [NSString stringWithFormat:
          @"创建 ContactBatchModifyLogic 失败: %@",
          exception.reason ?: @"unknown"]];

        return;
    }

    if (!self.batchLogic) {

        [self finishWithError:
         @"ContactBatchModifyLogic 初始化失败"];

        return;
    }

    if ([self.batchLogic
         respondsToSelector:
         @selector(setM_delegate:)]) {

        @try {

            [self.batchLogic
             setM_delegate:self];

        } @catch (NSException *exception) {

            WCBLLog(
                @"setM_delegate 异常: %@",
                exception
            );
        }

    } else {

        WCBLLog(
            @"ContactBatchModifyLogic 不支持 setM_delegate:"
        );
    }

    WCBLLog(
        @"开始批量删除 batchID=%lu，共 %lu 个，间隔 %.0fs",
        (unsigned long)self.batchID,
        (unsigned long)queue.count,
        self.interval
    );

    [self deleteNext];
}

#pragma mark 下一条

- (void)deleteNext {

    if (!self.isDeleting) {
        return;
    }

    if (self.deleteIndex >=
        (NSInteger)self.deleteQueue.count) {

        [self finishDone];

        return;
    }

    id contact =
    self.deleteQueue[self.deleteIndex];

    if (!contact) {

        [self handleResult:
         -3
         message:@"contact=nil"
         requestToken:self.token];

        return;
    }

    NSString *name =
    WCBLDisplayName(contact);

    WCBLLog(
        @"删除 %ld/%lu: %@",
        (long)(self.deleteIndex + 1),
        (unsigned long)self.deleteQueue.count,
        name
    );

    self.statusLabel.text =
    [NSString stringWithFormat:
     @"正在删除 %ld/%lu: %@",
     (long)(self.deleteIndex + 1),
     (unsigned long)self.deleteQueue.count,
     name];

    self.progressView.progress =
    (float)self.deleteIndex /
    (float)self.deleteQueue.count;

    /*
     * 每个请求拥有独立 token。
     */
    NSUInteger requestToken =
    ++self.token;

    self.waitingCallback = YES;

    NSUInteger currentBatchID =
    self.batchID;

    __weak typeof(self) weakSelf =
    self;

    /*
     * 超时保护。
     */
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(
                kWCBLCallbackTimeout *
                NSEC_PER_SEC
            )
        ),
        dispatch_get_main_queue(),
        ^{

            __strong typeof(weakSelf) strongSelf =
            weakSelf;

            if (!strongSelf) {
                return;
            }

            if (!strongSelf.isDeleting) {
                return;
            }

            if (strongSelf.batchID != currentBatchID) {
                return;
            }

            if (strongSelf.token != requestToken) {
                return;
            }

            if (!strongSelf.waitingCallback) {
                return;
            }

            WCBLLog(
                @"删除回调超时 batchID=%lu index=%ld token=%lu",
                (unsigned long)currentBatchID,
                (long)strongSelf.deleteIndex,
                (unsigned long)requestToken
            );

            [strongSelf
             handleResult:-1
             message:@"timeout"
             requestToken:requestToken];
        }
    );

    @try {

        [self.batchLogic
         batchModContactTypeWithAddContantctAr:nil
         deleteContantctAr:@[contact]
         modContactType:1];

    } @catch (NSException *exception) {

        WCBLLog(
            @"调用删除接口异常: %@",
            exception
        );

        [self
         handleResult:-2
         message:exception.reason ?: @"exception"
         requestToken:requestToken];
    }
}

#pragma mark 回调

- (void)OnContactBatchModify:(id)arg1
                     withRet:(int)ret
                    errorMsg:(id)msg
              isNetWorkError:(BOOL)isErr {

    /*
     * 微信内部回调线程不确定，因此统一切主线程。
     */
    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            if (!self.isDeleting) {
                return;
            }

            if (!self.waitingCallback) {

                WCBLLog(
                    @"收到回调，但当前没有等待中的请求 ret=%d",
                    ret
                );

                return;
            }

            /*
             * 注意：
             *
             * 当前微信接口没有从回调参数中明确提供
             * requestToken，因此这里只能使用
             * “当前正在等待的请求”进行匹配。
             *
             * 如果后续逆向确认 arg1 中存在请求标识，
             * 可以进一步做到严格的一一对应。
             */
            NSUInteger currentToken =
            self.token;

            [self
             handleResult:ret
             message:msg
             requestToken:currentToken];
        }
    );
}

#pragma mark 处理结果

- (void)handleResult:(int)ret
             message:(id)msg
        requestToken:(NSUInteger)requestToken {

    /*
     * 必须在主线程。
     */
    if (![NSThread isMainThread]) {

        __weak typeof(self) weakSelf =
        self;

        dispatch_async(
            dispatch_get_main_queue(),
            ^{

                __strong typeof(weakSelf) strongSelf =
                weakSelf;

                if (!strongSelf) {
                    return;
                }

                [strongSelf
                 handleResult:ret
                 message:msg
                 requestToken:requestToken];
            }
        );

        return;
    }

    if (!self.isDeleting) {
        return;
    }

    /*
     * 不是当前请求的结果。
     */
    if (!self.waitingCallback) {

        WCBLLog(
            @"忽略重复/迟到回调 ret=%d",
            ret
        );

        return;
    }

    /*
     * token 不匹配，说明已经被新的请求推进。
     */
    if (self.token != requestToken) {

        WCBLLog(
            @"忽略旧回调 token=%lu current=%lu",
            (unsigned long)requestToken,
            (unsigned long)self.token
        );

        return;
    }

    /*
     * 先关闭当前请求的等待状态。
     */
    self.waitingCallback = NO;

    /*
     * 立即推进 token。
     *
     * 这样当前请求之后再来的重复回调
     * 就不会再次进入这里。
     */
    self.token++;

    NSInteger currentIndex =
    self.deleteIndex;

    if (ret == 0) {

        self.successCount++;

        WCBLLog(
            @"删除成功 index=%ld",
            (long)currentIndex
        );

    } else {

        self.failCount++;

        WCBLLog(
            @"删除失败 index=%ld ret=%d msg=%@ network=%d",
            (long)currentIndex,
            ret,
            msg,
            self.waitingCallback
        );
    }

    self.deleteIndex++;

    self.progressView.progress =
    (float)self.deleteIndex /
    (float)self.deleteQueue.count;

    if (self.deleteIndex >=
        (NSInteger)self.deleteQueue.count) {

        [self finishDone];

        return;
    }

    NSTimeInterval interval =
    MIN(
        MAX(self.interval, 1.0),
        kWCBLMaxInterval
    );

    WCBLLog(
        @"等待 %.0fs 后继续 %ld/%lu",
        interval,
        (long)(self.deleteIndex + 1),
        (unsigned long)self.deleteQueue.count
    );

    NSUInteger currentBatchID =
    self.batchID;

    __weak typeof(self) weakSelf =
    self;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(
                interval * NSEC_PER_SEC
            )
        ),
        dispatch_get_main_queue(),
        ^{

            __strong typeof(weakSelf) strongSelf =
            weakSelf;

            if (!strongSelf) {
                return;
            }

            if (!strongSelf.isDeleting) {
                return;
            }

            if (strongSelf.batchID != currentBatchID) {
                return;
            }

            [strongSelf deleteNext];
        }
    );
}

#pragma mark 完成

- (void)finishDone {

    if (!self.isDeleting) {
        return;
    }

    self.isDeleting = NO;

    self.waitingCallback = NO;

    self.token++;

    self.batchLogic = nil;

    self.progressView.progress = 1.0;

    NSString *message =
    [NSString stringWithFormat:
     @"完成: 成功 %ld, 失败 %ld",
     (long)self.successCount,
     (long)self.failCount];

    self.statusLabel.text =
    message;

    WCBLLog(
        @"批量删除完成 batchID=%lu: %@",
        (unsigned long)self.batchID,
        message
    );

    self.navigationItem.rightBarButtonItem.enabled =
    YES;

    /*
     * 只有确实有成功删除时才重新读取黑名单。
     */
    if (self.successCount > 0) {

        NSArray *newContacts =
        WCBLFetchBlackListContacts();

        self.contacts =
        newContacts ?: @[];

        [self.selected removeAllObjects];

        self.title =
        [NSString stringWithFormat:
         @"黑名单批量删除 (%lu)",
         (unsigned long)self.contacts.count];

        self.navigationItem.rightBarButtonItem.title =
        @"全选";

        [self.tableView reloadData];
    }

    [self refreshDeleteButton];

    UIAlertController *alert =
    [UIAlertController
     alertControllerWithTitle:@"批量删除完成"
     message:message
     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
     [UIAlertAction
      actionWithTitle:@"好"
      style:UIAlertActionStyleDefault
      handler:nil]];

    [self presentViewController:alert
                       animated:YES
                     completion:nil];
}

#pragma mark 错误

- (void)finishWithError:(NSString *)message {

    self.isDeleting = NO;

    self.waitingCallback = NO;

    self.token++;

    self.batchLogic = nil;

    self.statusLabel.text =
    message ?: @"未知错误";

    WCBLLog(
        @"批量删除终止: %@",
        message
    );

    self.navigationItem.rightBarButtonItem.enabled =
    YES;

    [self refreshDeleteButton];

    UIAlertController *alert =
    [UIAlertController
     alertControllerWithTitle:@"操作失败"
     message:message ?: @"未知错误"
     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
     [UIAlertAction
      actionWithTitle:@"好"
      style:UIAlertActionStyleDefault
      handler:nil]];

    [self presentViewController:alert
                       animated:YES
                     completion:nil];
}

@end

#pragma mark - 入口 Target

@interface WCBLActionTarget : NSObject

@property (nonatomic, weak)
UIViewController *vc;

@property (nonatomic, weak)
UIButton *floatingButton;

- (void)open;

@end

@implementation WCBLActionTarget

- (void)open {

    UIViewController *host =
    self.vc;

    if (!host) {
        return;
    }

    /*
     * 防止当前 VC 已经被移除。
     */
    if (!host.viewIfLoaded.window) {

        WCBLLog(
            @"当前 VC 不在窗口层级，取消打开"
        );

        return;
    }

    NSArray *contacts =
    WCBLFetchBlackListContacts();

    if (contacts.count == 0) {

        UIAlertController *alert =
        [UIAlertController
         alertControllerWithTitle:@"提示"
         message:@"未获取到黑名单联系人 (接口可能不匹配, 详见 WCBL.log)"
         preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
         [UIAlertAction
          actionWithTitle:@"好"
          style:UIAlertActionStyleDefault
          handler:nil]];

        [host presentViewController:alert
                            animated:YES
                          completion:nil];

        return;
    }

    WCBLBatchDeleteViewController *vc =
    [[WCBLBatchDeleteViewController alloc]
     initWithContacts:contacts];

    if (host.navigationController) {

        [host.navigationController
         pushViewController:vc
         animated:YES];

    } else {

        UINavigationController *nav =
        [[UINavigationController alloc]
         initWithRootViewController:vc];

        [host presentViewController:nav
                           animated:YES
                         completion:nil];
    }
}

@end

#pragma mark - Associated Object

static const void *kWCBLInjectedKey =
&kWCBLInjectedKey;

#pragma mark - 黑名单页面检测

static BOOL WCBLIsBlackListPage(
    UIViewController *vc
) {

    if (!vc) {
        return NO;
    }

    NSString *className =
    NSStringFromClass([vc class]);

    if ([className
         rangeOfString:@"BlackList"
         options:NSCaseInsensitiveSearch].location
        != NSNotFound) {

        return YES;
    }

    NSString *title =
    vc.title ?: vc.navigationItem.title;

    if ([title isEqualToString:@"通讯录黑名单"] ||
        [title isEqualToString:@"黑名单"]) {

        return YES;
    }

    return NO;
}

#pragma mark - 布局悬浮按钮

static void WCBLLayoutFAB(
    UIButton *button,
    UIViewController *vc
) {

    if (!button || !vc) {
        return;
    }

    CGRect bounds =
    vc.view.bounds;

    UIEdgeInsets insets =
    vc.view.safeAreaInsets;

    CGFloat width = 96.0;
    CGFloat height = 40.0;

    CGFloat rightMargin = 14.0;
    CGFloat bottomMargin = 20.0;

    CGFloat x =
    CGRectGetWidth(bounds)
    - width
    - rightMargin;

    CGFloat y =
    CGRectGetHeight(bounds)
    - insets.bottom
    - height
    - bottomMargin;

    button.frame =
    CGRectMake(
        MAX(0, x),
        MAX(0, y),
        width,
        height
    );
}

#pragma mark - 注入

static void WCBLInject(
    UIViewController *vc
) {

    if (!vc) {
        return;
    }

    /*
     * 已经注入。
     */
    if (objc_getAssociatedObject(
            vc,
            kWCBLInjectedKey)) {

        /*
         * 即使已经注入，也重新布局一下 FAB。
         */
        id target =
        objc_getAssociatedObject(
            vc,
            kWCBLInjectedKey);

        if ([target isKindOfClass:
             [WCBLActionTarget class]]) {

            WCBLActionTarget *actionTarget =
            (WCBLActionTarget *)target;

            if (actionTarget.floatingButton) {

                WCBLLayoutFAB(
                    actionTarget.floatingButton,
                    vc
                );
            }
        }

        return;
    }

    /*
     * 当前不是黑名单页面。
     *
     * 不设置 associated object。
     */
    if (!WCBLIsBlackListPage(vc)) {
        return;
    }

    WCBLActionTarget *target =
    [[WCBLActionTarget alloc] init];

    target.vc = vc;

    /*
     * 先保存 target。
     */
    objc_setAssociatedObject(
        vc,
        kWCBLInjectedKey,
        target,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    WCBLLog(
        @"检测到黑名单页面: %@ title=%@",
        NSStringFromClass([vc class]),
        vc.title
    );

    #pragma mark 导航栏按钮

    NSMutableArray *items =
    [vc.navigationItem.rightBarButtonItems
     mutableCopy];

    if (!items) {
        items = [NSMutableArray array];
    }

    UIBarButtonItem *button =
    [[UIBarButtonItem alloc]
     initWithTitle:@"批量删除"
     style:UIBarButtonItemStylePlain
     target:target
     action:@selector(open)];

    [items addObject:button];

    vc.navigationItem.rightBarButtonItems =
    items;

    #pragma mark 悬浮按钮

    UIButton *fab =
    [UIButton buttonWithType:UIButtonTypeSystem];

    [fab setTitle:@"批量删除"
          forState:UIControlStateNormal];

    [fab setTitleColor:[UIColor whiteColor]
              forState:UIControlStateNormal];

    fab.titleLabel.font =
    [UIFont boldSystemFontOfSize:15];

    fab.backgroundColor =
    [UIColor systemRedColor];

    fab.layer.cornerRadius = 20.0;

    [fab addTarget:target
            action:@selector(open)
  forControlEvents:UIControlEventTouchUpInside];

    [vc.view addSubview:fab];

    target.floatingButton = fab;

    WCBLLayoutFAB(
        fab,
        vc
    );

    WCBLLog(
        @"已注入批量删除按钮"
    );
}

#pragma mark - Swizzle

static void (*orig_viewDidAppear)(
    id,
    SEL,
    BOOL
);

static void wcbl_viewDidAppear(
    UIViewController *self,
    SEL _cmd,
    BOOL animated
) {

    /*
     * 原始实现必须优先执行。
     */
    if (orig_viewDidAppear) {

        orig_viewDidAppear(
            self,
            _cmd,
            animated
        );
    }

    @try {

        WCBLInject(self);

        /*
         * 微信部分页面的 title 会在
         * viewDidAppear 后才设置。
         */
        __weak UIViewController *weakVC =
        self;

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(
                    0.6 *
                    NSEC_PER_SEC
                )
            ),
            dispatch_get_main_queue(),
            ^{

                UIViewController *strongVC =
                weakVC;

                if (!strongVC) {
                    return;
                }

                @try {

                    WCBLInject(strongVC);

                } @catch (NSException *e) {

                    WCBLLog(
                        @"延迟注入异常: %@",
                        e
                    );
                }
            }
        );

    } @catch (NSException *e) {

        WCBLLog(
            @"viewDidAppear 注入异常: %@",
            e
        );
    }
}

#pragma mark - Constructor

__attribute__((constructor))
static void WCBLInit(void) {

    @autoreleasepool {

        WCBLLog(
            @"================================"
        );

        WCBLLog(
            @"WCBlackListBatchDelete v3 加载"
        );

        WCBLLog(
            @"================================"
        );

        Method method =
        class_getInstanceMethod(
            [UIViewController class],
            @selector(viewDidAppear:)
        );

        if (!method) {

            WCBLLog(
                @"hook 失败: 找不到 UIViewController viewDidAppear:"
            );

            return;
        }

        IMP originalIMP =
        method_getImplementation(method);

        if (!originalIMP) {

            WCBLLog(
                @"hook 失败: original IMP=nil"
            );

            return;
        }

        orig_viewDidAppear =
        (void (*)(id, SEL, BOOL))originalIMP;

        method_setImplementation(
            method,
            (IMP)wcbl_viewDidAppear
        );

        WCBLLog(
            @"已 hook UIViewController viewDidAppear:"
        );

        /*
         * 加载提示。
         */
        if (kWCBLShowLoadedToast) {

            __block id observer = nil;

            observer =
            [[NSNotificationCenter defaultCenter]
             addObserverForName:
             UIApplicationDidBecomeActiveNotification
             object:nil
             queue:
             [NSOperationQueue mainQueue]
             usingBlock:^(NSNotification *notification) {

                if (observer) {

                    [[NSNotificationCenter defaultCenter]
                     removeObserver:observer];

                    observer = nil;
                }

                WCBLToast(
                    @"WCBL 已加载"
                );
            }];
        }
    }
}
