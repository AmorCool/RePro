//
//  repro-signingd.m — 极简版
//  步骤1: 启动，读 /var/mobile/Library/RePro/signingd-config.plist
//  步骤2: 按 checkIntervalMin 设 NSTimer
//  步骤3: 到点 → 写触发标记 + 日志 → notify_post
//  步骤4: 等 App 同步新配置 → 重设定时器
//
//  日志: fopen/fprintf 同步写入 <jbroot>/var/log/reprorefresh_at.log
//

#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#import <Foundation/Foundation.h>

static NSString *const kIpcDir      = @"/var/mobile/Library/RePro";
static NSString *const kConfigPath  = @"/var/mobile/Library/RePro/signingd-config.plist";
static NSString *const kTriggerPath = @"/var/mobile/Library/RePro/auto-resign-trigger";

static const NSInteger  kFallbackMinutes = 360;
static const NSInteger  kFallbackDays    = 2;

static FILE     *gLogFile  = NULL;
static NSTimer  *gTimer    = nil;
static time_t    gLastFire = 0;

// ─── 日志 ────────────────────────────────────────────────────────

static void s_log(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a);
    time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    char ts[64]; strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm);
    if (gLogFile) { fprintf(gLogFile, "[%s] %s\n", ts, s.UTF8String); fflush(gLogFile); }
    NSLog(@"[repro-signingd] %@", s);
}

static void s_open_log(void) {
    NSString *dir = nil, *jb = nil;
    // 从 argv[0] 推 jbroot
    NSString *a0 = [[[NSProcessInfo processInfo] arguments] firstObject];
    if (a0) {
        NSRange r = [a0 rangeOfString:@"/usr/libexec/" options:NSBackwardsSearch];
        if (r.location != NSNotFound) jb = [a0 substringToIndex:r.location];
    }
    if (!jb) jb = @"/var/jb";
    dir = [jb stringByAppendingPathComponent:@"var/log"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    NSString *p = [dir stringByAppendingPathComponent:@"reprorefresh_at.log"];
    gLogFile = fopen(p.UTF8String, "a");
    if (gLogFile) chmod(p.UTF8String, 0666);
    if (!gLogFile) NSLog(@"[repro-signingd] 无法打开 %@", p);
}

// ─── 配置 ────────────────────────────────────────────────────────

typedef struct { BOOL enabled; NSInteger minutes; NSInteger days; } sd_config;

static sd_config s_cfg(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    if (!d) return (sd_config){YES, kFallbackMinutes, kFallbackDays};
    NSInteger m = [d[@"checkIntervalMin"] integerValue]; if (m < 1) m = kFallbackMinutes;
    NSInteger dy = [d[@"resignThreshold"] integerValue]; if (dy < 1) dy = kFallbackDays;
    BOOL en = d[@"autoResign"] ? [d[@"autoResign"] boolValue] : YES;
    return (sd_config){en, m, dy};
}

// ─── 触发 ────────────────────────────────────────────────────────

static void s_fire(void) {
    sd_config c = s_cfg();
    if (!c.enabled) { s_log(@"自动续签关闭，跳过"); return; }
    time_t now = time(NULL);
    [@{
        @"timestamp": @(now),
        @"threshold": @(c.days),
    } writeToFile:kTriggerPath atomically:YES];
    chown(kTriggerPath.UTF8String, 501, 501);
    notify_post("com.reprovision.schedule-resign");
    s_log(@"到达续签时间 — 阈值 %ld 天 — 已触发", (long)c.days);
}

static void s_start_timer(NSTimeInterval sec) {
    [gTimer invalidate];
    gTimer = [NSTimer scheduledTimerWithTimeInterval:sec repeats:YES block:^(NSTimer *t) {
        time_t n = time(NULL); if (n - gLastFire < 60) return; gLastFire = n;
        s_fire();
    }];
}

// ─── main ────────────────────────────────────────────────────────

int main(void) {
    s_open_log();
    s_log(@"启动 pid=%d uid=%d", getpid(), getuid());
    [[NSFileManager defaultManager] createDirectoryAtPath:kIpcDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    chown(kIpcDir.UTF8String, 501, 501);

    sd_config c = s_cfg();
    s_log(@"配置: 自动=%@ 间隔=%ld分 阈值=%ld天", c.enabled?@"是":@"否", (long)c.minutes, (long)c.days);
    if (c.enabled) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ s_fire(); });
    s_start_timer((NSTimeInterval)c.minutes * 60.0);

    int t; notify_register_dispatch("com.reprovision.signingd-config-updated", &t,
        dispatch_get_main_queue(), ^(int _){ sd_config nc = s_cfg();
            s_log(@"配置已刷新 — 间隔 %ld 分", (long)nc.minutes);
            s_start_timer((NSTimeInterval)nc.minutes * 60.0); });

    int t2; notify_register_dispatch("com.reprovision.signing-complete", &t2,
        dispatch_get_main_queue(), ^(int _){ s_log(@"续签完成"); });

    [[NSRunLoop mainRunLoop] run]; return 0;
}
