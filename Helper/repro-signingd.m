//
//  repro-signingd.m
//  RePro 后台定时续签守护进程
//
//  以 root 身份由 launchd 拉起（RunAtLoad + KeepAlive），运行在 App jbroot
//  namespace 外。两个核心职责：
//  1. NSTimer 定时触发续签 → notify_post 通知 App
//  2. 直接写真实 TCC.db 授权通知权限（绕过 RootHide overlay）
//
//  RootHide namespace 会把 App 进程的 TCC.db 写操作重定向到 overlay，
//  导致 UNUserNotificationCenter.requestAuthorization 存不到真实系统。
//  本 daemon 在 namespace 外 → 写真实 /var/mobile/Library/TCC/TCC.db。
//

#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include <sqlite3.h>
#import <Foundation/Foundation.h>

// ─── 常量 ────────────────────────────────────────────────────────

static NSString *const kIpcDir          = @"/var/mobile/Library/RePro";
static NSString *const kConfigPath      = @"/var/mobile/Library/RePro/signingd-config.plist";
static NSString *const kRequestPath     = @"/var/mobile/Library/RePro/auto-resign-request";

static NSString *const kTCCDbPath       = @"/private/var/mobile/Library/TCC/TCC.db";
static NSString *const kOurBundleID     = @"com.reprovision.repro";
static NSString *const kTCCService      = @"kTCCServiceUserNotifications";

static const BOOL       kDefaultAutoResign    = YES;
static const NSInteger  kDefaultCheckInterval = 6;
static const NSInteger  kDefaultThreshold     = 2;
static const NSTimeInterval kMinTimerInterval = 3600.0;

// ─── 日志 ────────────────────────────────────────────────────────

static void SDLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[repro-signingd] %@", msg);
}

// ─── IPC 目录 ────────────────────────────────────────────────────

static BOOL SDEnsureIpcDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kIpcDir]) return YES;
    NSError *err;
    if (![fm createDirectoryAtPath:kIpcDir withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions: @0755} error:&err]) {
        SDLog(@"创建 IPC 目录失败: %@", err);
        return NO;
    }
    chown(kIpcDir.UTF8String, 501, 501);
    return YES;
}

// ─── 配置 ────────────────────────────────────────────────────────

static NSDictionary *SDLoadConfig(void) {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    return cfg ?: @{
        @"autoResign":     @(kDefaultAutoResign),
        @"checkInterval":  @(kDefaultCheckInterval),
        @"resignThreshold":@(kDefaultThreshold),
    };
}

// ─── TCC 权限写入（绕过 RootHide overlay）───────────────────────
//
// RootHide namespace 下 App 进程对 /var/mobile/Library/TCC/ 的写被重定向到
// overlay → 真实系统认为权限未授权 → 每次启动都弹请求 + 通知发不出去。
// daemon 在 namespace 外，写的是真实 TCC.db。
//
// TCC.db access 表结构（iOS 15+）:
//   service TEXT        - 'kTCCServiceUserNotifications'
//   client TEXT         - bundle ID
//   client_type INTEGER - 0
//   auth_value INTEGER  - 2 (allowed)
//   auth_reason INTEGER - 1 (user set)
//   auth_version INTEGER- 1
//   indirect_object_identifier_type INTEGER - 0
//   indirect_object_identifier TEXT - 'UNUserNotificationCenter'
//   flags INTEGER       - 0
//   last_modified INTEGER - timestamp
//

static void SDEnsureNotificationPermission(void) {
    // 检查 TCC.db 是否存在
    if (access(kTCCDbPath.UTF8String, W_OK) != 0) {
        SDLog(@"TCC.db 不可写: %s", strerror(errno));
        return;
    }

    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(kTCCDbPath.UTF8String, &db,
                              SQLITE_OPEN_READWRITE, NULL);
    if (rc != SQLITE_OK) {
        SDLog(@"打开 TCC.db 失败: %s", sqlite3_errmsg(db));
        if (db) sqlite3_close(db);
        return;
    }

    // 先查询是否已有记录，避免重复 INSERT
    const char *checkSQL = "SELECT auth_value FROM access "
                            "WHERE service=?1 AND client=?2 LIMIT 1;";
    sqlite3_stmt *stmt = NULL;
    BOOL alreadyHavePermission = NO;

    if (sqlite3_prepare_v2(db, checkSQL, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, kTCCService.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, kOurBundleID.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            int val = sqlite3_column_int(stmt, 0);
            alreadyHavePermission = (val == 2); // 2 = allowed
        }
        sqlite3_finalize(stmt);
    }

    if (alreadyHavePermission) {
        SDLog(@"TCC 通知权限已存在（auth_value=2），跳过");
        sqlite3_close(db);
        return;
    }

    // 先删后插（避免重复键）
    const char *delSQL = "DELETE FROM access WHERE service=?1 AND client=?2;";
    if (sqlite3_prepare_v2(db, delSQL, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, kTCCService.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, kOurBundleID.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }

    // 插入新记录
    const char *insSQL =
        "INSERT INTO access "
        "(service, client, client_type, auth_value, auth_reason, auth_version, "
        " indirect_object_identifier_type, indirect_object_identifier, flags, last_modified) "
        "VALUES "
        "(?1, ?2, 0, 2, 1, 1, 0, 'UNUserNotificationCenter', 0, "
        " CAST(strftime('%%s','now') AS INTEGER));";

    if (sqlite3_prepare_v2(db, insSQL, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, kTCCService.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, kOurBundleID.UTF8String, -1, SQLITE_TRANSIENT);
        rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) {
            SDLog(@"✅ 已写入 TCC 通知权限（bundle=%@）到真实 TCC.db", kOurBundleID);
        } else {
            SDLog(@"⚠ TCC INSERT 返回: %d (%s)", rc, sqlite3_errmsg(db));
        }
        sqlite3_finalize(stmt);
    } else {
        SDLog(@"⚠ TCC INSERT 准备失败: %s", sqlite3_errmsg(db));
    }

    sqlite3_close(db);
}

// ─── NSTimer ────────────────────────────────────────────────────

static NSTimer *gSigningTimer;
static time_t   gLastFireTime;

static void SDFireResignRequest(void) {
    NSDictionary *cfg = SDLoadConfig();
    if (![cfg[@"autoResign"] boolValue]) {
        SDLog(@"自动续签已关闭，跳过");
        return;
    }

    time_t now = time(NULL);
    SDEnsureIpcDir();

    NSString *ts = [NSString stringWithFormat:@"%lld", (long long)now];
    [ts writeToFile:kRequestPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chown(kRequestPath.UTF8String, 501, 501);

    notify_post("com.reprovision.schedule-resign");

    NSInteger threshold = [cfg[@"resignThreshold"] integerValue];
    if (threshold < 1) threshold = kDefaultThreshold;
    SDLog(@"已触发自动续签请求（阈值 %ld 天）", (long)threshold);
}

static void SDScheduleTimer(NSTimeInterval interval) {
    [gSigningTimer invalidate];
    gSigningTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                    repeats:YES
                                                      block:^(NSTimer *timer) {
        time_t now = time(NULL);
        if (now - gLastFireTime < 60) return;
        gLastFireTime = now;
        SDFireResignRequest();
    }];
}

// ─── main ───────────────────────────────────────────────────────

int main(void) {
    SDLog(@"启动，pid=%d，uid=%d", getpid(), getuid());
    SDEnsureIpcDir();

    // 核心：写真实 TCC.db 授权通知权限（RootHide 下这是唯一可靠路径）
    SDLog(@"确保真实 TCC.db 中通知权限…");
    SDEnsureNotificationPermission();

    NSDictionary *cfg = SDLoadConfig();
    NSInteger intervalHours = [cfg[@"checkInterval"] integerValue];
    if (intervalHours < 1) intervalHours = kDefaultCheckInterval;
    NSTimeInterval interval = MAX((NSTimeInterval)intervalHours * 3600.0, kMinTimerInterval);

    SDLog(@"自动续签: %@, 间隔: %.0f 分钟, 阈值: %@ 天",
          [cfg[@"autoResign"] boolValue] ? @"开启" : @"关闭",
          interval / 60.0,
          cfg[@"resignThreshold"] ?: @(kDefaultThreshold));

    if ([cfg[@"autoResign"] boolValue]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            SDFireResignRequest();
        });
    }

    SDScheduleTimer(interval);

    // 监听配置更新
    int configToken;
    notify_register_dispatch("com.reprovision.signingd-config-updated", &configToken,
        dispatch_get_main_queue(), ^(int unused) {
            SDLog(@"收到配置更新通知，重新加载");
            NSDictionary *c = SDLoadConfig();
            NSInteger ih = [c[@"checkInterval"] integerValue];
            if (ih < 1) ih = kDefaultCheckInterval;
            NSTimeInterval inv = MAX((NSTimeInterval)ih * 3600.0, kMinTimerInterval);
            SDScheduleTimer(inv);
        });

    // 监听 App 续签完成
    int completeToken;
    notify_register_dispatch("com.reprovision.signing-complete", &completeToken,
        dispatch_get_main_queue(), ^(int unused) {
            SDLog(@"App 续签完成");
        });

    // App 请求重新确保通知权限（设置页测试按钮触发）
    int permToken;
    notify_register_dispatch("com.reprovision.ensure-notification-permission", &permToken,
        dispatch_get_main_queue(), ^(int unused) {
            SDLog(@"收到确保通知权限请求");
            SDEnsureNotificationPermission();
        });

    [[NSRunLoop mainRunLoop] run];
    return 0;
}
