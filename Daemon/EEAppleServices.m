//
//  EEAppleServices.m
//  RePro Daemon
//
//  Apple 开发者服务实现 - 精简移植版
//

#import "EEAppleServices.h"
#import <zlib.h>

#pragma mark - 常量定义

/// Apple 客户端标识符
static NSString *const REClientID = @"XABBG36SBA";

/// 协议版本
static NSString *const REProtocolVersion = @"QH65B2";

#pragma mark - 私有接口

@interface EEAppleServices ()

@property (nonatomic, strong) NSString *teamid;                    // 当前 Team ID
@property (nonatomic, strong) NSURLCredential *credentials;        // 认证凭证
@property (nonatomic, copy, readonly) NSURL *baseURL;              // 基础 URL（旧版 API）
@property (nonatomic, copy, readonly) NSURL *servicesBaseURL;      // 服务基础 URL（新版 API）

@end

#pragma mark - 实现

@implementation EEAppleServices

#pragma mark - 单例与初始化

+ (instancetype)sharedInstance {
    static EEAppleServices *sharedInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sharedInstance = [[EEAppleServices alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];

    if (self) {
        _teamid = @"";
        _baseURL = [[NSURL URLWithString:[NSString stringWithFormat:
            @"https://developerservices2.apple.com/services/%@/", REProtocolVersion]] copy];
        _servicesBaseURL = [[NSURL URLWithString:
            @"https://developerservices2.apple.com/services/v1/"] copy];
    }

    return self;
}

#pragma mark - GZIP 工具方法

/// 检测数据是否为 GZIP 格式
- (BOOL)isGzippedData:(NSData *)data {
    if (data.length < 2) return NO;

    const UInt8 *bytes = data.bytes;
    return (bytes[0] == 0x1f && bytes[1] == 0x8b);
}

/// 解压 GZIP 数据
- (NSData *)gunzippedData:(NSData *)data {
    if (![self isGzippedData:data]) return data;

    z_stream stream;
    memset(&stream, 0, sizeof(stream));

    // 初始化 inflate（支持 gzip 格式）
    if (inflateInit2(&stream, 16 + MAX_WBITS) != Z_OK) return nil;

    stream.next_in = (Bytef *)data.bytes;
    stream.avail_in = (uInt)data.length;

    NSMutableData *output = [NSMutableData dataWithLength:4096];
    NSUInteger outputSize = 0;

    int status;
    do {
        // 扩展输出缓冲区
        [output increaseLengthBy:4096];
        stream.next_out = (Bytef *)(output.bytes + outputSize);
        stream.avail_out = (uInt)(output.length - outputSize);

        status = inflate(&stream, Z_NO_FLUSH);
        outputSize += (4096 - stream.avail_out);

    } while (status == Z_OK);

    inflateEnd(&stream);

    if (status != Z_STREAM_END) return nil;

    output.length = outputSize;
    return output;
}

#pragma mark - HTTP 请求构建

/// 构建请求头（包含认证信息）
- (NSMutableURLRequest *)populateHeaders:(NSMutableURLRequest *)request
                                  method:(NSString *)method {
    // 基础 HTTP 头
    NSDictionary<NSString *, NSString *> *httpHeaders = @{
        @"Content-Type": [method isEqualToString:@"POST"] ?
            @"text/x-xml-plist" : @"application/vnd.api+json",
        @"User-Agent": @"Xcode",
        @"Accept": [method isEqualToString:@"POST"] ?
            @"text/x-xml-plist" : @"application/vnd.api+json",
        @"Accept-Language": @"en-us",
        @"Connection": @"keep-alive",
        @"X-Xcode-Version": @"11.2 (11B52)",
        @"X-Apple-I-Identity-Id": [[self.credentials user]
            componentsSeparatedByString:@"|"][0] ?: @"",
        @"X-Apple-GS-Token": [self.credentials password] ?: @"",
        @"X-Mme-Device-Id": @"",  // 设备标识（新项目由外部提供）
        @"X-HTTP-Method-Override": method,
    };

    // 设置请求头
    [httpHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key,
                                                     NSString *value,
                                                     BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];

    return request;
}

/// 发送 HTTP 请求并处理响应
- (void)_sendRequest:(NSMutableURLRequest *)request
              method:(NSString *)method
                data:(NSData *)data
   andCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    request.HTTPMethod = @"POST";
    request = [self populateHeaders:request method:method];
    request.HTTPBody = data;

    NSURLSessionConfiguration *sessionConfig =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session =
        [NSURLSession sessionWithConfiguration:sessionConfig
                                      delegate:nil
                                 delegateQueue:nil];

    NSURLSessionDataTask *task =
        [session dataTaskWithRequest:request
                   completionHandler:^(NSData *data,
                                       NSURLResponse *response,
                                       NSError *error) {

            if (error || !data) {
                completionHandler(error, nil);
                return;
            }

            // 自动解压 GZIP 数据
            NSData *unpacked = [self isGzippedData:data] ?
                [self gunzippedData:data] : data;

            // 根据请求方式解析响应格式
            NSError *parseError = nil;
            NSDictionary *plist = nil;

            if ([method isEqualToString:@"POST"]) {
                plist = [NSPropertyListSerialization
                    propertyListWithData:unpacked
                                 options:NSPropertyListImmutable
                                  format:nil
                                   error:&parseError];
            } else {
                plist = [NSJSONSerialization JSONObjectWithData:unpacked
                                                       options:0
                                                         error:&parseError];
            }

            if (parseError || !plist) {
                completionHandler(parseError, nil);
            } else {
                completionHandler(nil, plist);
            }
        }];

    [task resume];
}

/// 发送原始 JSON 服务请求
- (void)_sendRawServiceRequestWithName:(NSString *)name
                                method:(NSString *)method
                             systemType:(EESystemType)systemType
                       extraDictionary:(NSDictionary *)extra
                  andCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSString *urlStr = [NSString stringWithFormat:@"%@%@", self.servicesBaseURL, name];
    NSMutableURLRequest *request =
        [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:urlStr]];

    NSError *serializationError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:extra
                                                   options:0
                                                     error:&serializationError];

    if (!data) {
        completionHandler(serializationError, nil);
        return;
    }

    [self _sendRequest:request method:method data:data andCompletionHandler:completionHandler];
}

/// 发送服务请求（参数编码为查询字符串）
- (void)_sendServiceRequestWithName:(NSString *)name
                             method:(NSString *)method
                          systemType:(EESystemType)systemType
                    extraDictionary:(NSDictionary *)extra
               andCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    // 将字典转换为 URL 编码的查询字符串
    NSMutableArray<NSURLQueryItem *> *queryItems = [NSMutableArray array];
    [extra enumerateKeysAndObjectsUsingBlock:^(NSString *key,
                                               NSString *value,
                                               BOOL *stop) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:key value:value]];
    }];

    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.queryItems = queryItems;
    NSString *queryString = components.query ?: @"";

    [self _sendRawServiceRequestWithName:name
                                  method:method
                               systemType:systemType
                         extraDictionary:@{@"urlEncodedQueryParams": queryString}
                    andCompletionHandler:completionHandler];
}

/// 执行开发者服务操作（XML Plist 格式）
- (void)_doActionWithName:(NSString *)action
               systemType:(EESystemType)systemType
           extraDictionary:(NSDictionary *)extra
      andCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    // 根据系统类型确定 URL 路径前缀
    NSString *os = @"";
    if (systemType != EESystemTypeUndefined) {
        os = (systemType == EESystemTypeiOS ||
              systemType == EESystemTypewatchOS) ? @"ios/" : @"tvos/";
    }

    NSString *urlStr = [NSString stringWithFormat:
        @"%@%@%@?clientId=%@", self.baseURL, os, action, REClientID];

    NSMutableURLRequest *request =
        [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:urlStr]];

    // 构建请求体
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"clientId"] = REClientID;
    dict[@"protocolVersion"] = REProtocolVersion;
    dict[@"requestId"] = [[NSUUID UUID] UUIDString];
    dict[@"userLocale"] = @[@"en_US"];

    // 根据系统类型设置平台标识
    switch (systemType) {
        case EESystemTypeiOS:
            dict[@"DTDK_Platform"] = @"ios";
            break;
        case EESystemTypewatchOS:
            dict[@"DTDK_Platform"] = @"watchos";
            break;
        case EESystemTypetvOS:
            dict[@"DTDK_Platform"] = @"tvos";
            dict[@"subPlatform"] = @"tvOS";
            break;
        default:
            break;
    }

    // 合并额外参数
    if (extra) {
        for (NSString *key in extra.allKeys) {
            id value = extra[key];
            if (value) dict[key] = value;
        }
    }

    // 序列化为 XML Plist 格式
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:dict
                     format:NSPropertyListXMLFormat_v1_0
                    options:0
                      error:nil];

    [self _sendRequest:request method:@"POST" data:data andCompletionHandler:completionHandler];
}

#pragma mark - 会话管理

/// 使用外部凭证建立会话（推荐使用此方法）
- (void)ensureSessionWithIdentity:(NSString *)identity
                          gsToken:(NSString *)token
              andCompletionHandler:(void (^)(NSError *error,
                                             NSDictionary *plist))completionHandler {

    // 保存凭证
    self.credentials = [[NSURLCredential alloc]
        initWithUser:identity
             password:token
     persistence:NSURLCredentialPersistencePermanent];

    // 返回成功结果
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"reason"] = @"authenticated";
    result[@"userString"] = @"";

    completionHandler(nil, result);
}

/// 使用用户名密码登录（兼容性保留，建议改用 ensureSessionWithIdentity）
- (void)signInWithUsername:(NSString *)username
                  password:(NSString *)password
       andCompletionHandler:(void (^)(NSError *,
                                      NSDictionary *,
                                      NSURLCredential *))completionHandler {

    // 新项目不再直接处理登录，需通过 AnisetteManager 获取凭证后调用 ensureSessionWithIdentity
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"请使用 ensureSessionWithIdentity 方法传入从 AnisetteManager 获取的凭证"
    };
    NSError *error = [NSError errorWithDomain:@"EEAppleServices"
                                         code:-1
                                     userInfo:userInfo];

    completionHandler(error, nil, nil);
}

/// 请求双因素认证代码（兼容性保留）
- (void)requestTwoFactorLoginCodeWithCompletionHandler:(void (^)(NSError *))completion {
    // 新项目通过 AnisetteManager 处理 2FA
    completion(nil);
}

/// 验证登录代码（兼容性保留）
- (void)validateLoginCode:(NSString *)code
      andCompletionHandler:(void (^)(NSError *,
                                     NSDictionary *,
                                     NSURLCredential *))completionHandler {

    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"请使用 ensureSessionWithIdentity 方法"
    };
    NSError *error = [NSError errorWithDomain:@"EEAppleServices"
                                         code:-1
                                     userInfo:userInfo];

    completionHandler(error, nil, nil);
}

/// 双因素认证备用请求（兼容性保留）
- (void)fallback2FACodeRequest:(void (^)(NSError *,
                                        NSDictionary *,
                                        NSURLCredential *))completionHandler {

    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"请使用 ensureSessionWithIdentity 方法"
    };
    NSError *error = [NSError errorWithDomain:@"EEAppleServices"
                                         code:-1
                                     userInfo:userInfo];

    completionHandler(error, nil, nil);
}

#pragma mark - Team ID 管理

/// 获取当前 Team ID
- (NSString *)currentTeamID {
    return self.teamid;
}

/// 更新当前 Team ID（支持多团队选择回调）
- (void)updateCurrentTeamIDWithTeamIDCheck:(NSString * (^)(NSArray *))teamIDCallback
                                andCallback:(void (^)(NSError *, NSString *))completionHandler {

    [self listTeamsWithCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            self.teamid = @"";
            completionHandler(error, @"");
            return;
        }

        NSArray *teams = plist[@"teams"];
        if (!teams || teams.count == 0) {
            completionHandler(error, @"");
            return;
        }

        NSString *teamId = nil;

        if (teams.count > 1) {
            // 多团队时调用选择回调
            teamId = teamIDCallback(teams);
        } else if (teams.count == 1) {
            // 单团队时自动选择
            teamId = teams[0][@"teamId"];
        } else {
            completionHandler(error, @"");
            return;
        }

        self.teamid = teamID;
        completionHandler(error, self.teamid);
    }];
}

/// 查看开发者信息
- (void)viewDeveloperWithCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {
    [self _doActionWithName:@"viewDeveloper.action"
                 systemType:EESystemTypeUndefined
             extraDictionary:nil
        andCompletionHandler:completionHandler];
}

/// 列出所有团队
- (void)listTeamsWithCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {
    [self _doActionWithName:@"listTeams.action"
                 systemType:EESystemTypeUndefined
             extraDictionary:nil
        andCompletionHandler:completionHandler];
}

#pragma mark - 设备管理

/// 添加设备到团队
- (void)addDevice:(NSString *)udid
       deviceName:(NSString *)name
         forTeamID:(NSString *)teamID
        systemType:(EESystemType)systemType
withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID;
    extra[@"deviceNumber"] = udid;
    extra[@"name"] = name;

    [self _doActionWithName:@"addDevice.action"
                 systemType:systemType
             extraDictionary:extra
        andCompletionHandler:completionHandler];
}

/// 列出团队中的设备
- (void)listDevicesForTeamID:(NSString *)teamID
                  systemType:(EESystemType)systemType
      withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID;
    extra[@"pageSize"] = @"500";
    extra[@"pageNumber"] = @"1";
    extra[@"sort"] = @"name=asc";
    extra[@"includeRemovedDevices"] = @"false";

    [self _doActionWithName:@"listDevices.action"
                 systemType:systemType
             extraDictionary:extra
        andCompletionHandler:completionHandler];
}

#pragma mark - App ID 管理

/// 列出所有 App ID
- (void)listAllApplicationsForTeamID:(NSString *)teamID
                          systemType:(EESystemType)systemType
              withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID;

    [self _doActionWithName:@"listAppIds.action"
                 systemType:systemType
             extraDictionary:extra
        andCompletionHandler:completionHandler];
}

/// 添加 App ID
- (void)addApplicationId:(NSString *)applicationIdentifier
                    name:(NSString *)applicationName
          enabledFeatures:(NSDictionary *)enabledFeatures
                   teamID:(NSString *)teamID
             entitlements:(NSDictionary *)entitlements
               systemType:(EESystemType)systemType
     withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID ?: @"";
    extra[@"identifier"] = applicationIdentifier ?: @"";
    extra[@"name"] = applicationName ?: @"";
    extra[@"type"] = @"explicit";

    // 添加功能开关
    for (NSString *key in enabledFeatures.allKeys) {
        id value = enabledFeatures[key];
        if (value) extra[key] = value;
    }

    extra[@"entitlements"] = entitlements;

    [self _doActionWithName:@"addAppId.action"
                 systemType:systemType
             extraDictionary:extra
        andCompletionHandler:completionHandler];
}

/// 更新 App ID
- (void)updateApplicationIdId:(NSString *)appIdId
              enabledFeatures:(NSDictionary *)enabledFeatures
                       teamID:(NSString *)teamID
                 entitlements:(NSDictionary *)entitlements
                   systemType:(EESystemType)systemType
       withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID;
    extra[@"appIdId"] = appIdId;
    extra[@"type"] = @"explicit";

    // 更新功能开关
    for (NSString *key in enabledFeatures.allKeys) {
        id value = enabledFeatures[key];
        if (value) extra[key] = value;
    }

    extra[@"entitlements"] = entitlements;

    [self _doActionWithName:@"updateAppId.action"
                 systemType:systemType
             extraDictionary:extra
        andCompletionHandler:completionHandler];
}

/// 删除 App ID
- (void)deleteApplicationIdId:(NSString *)appIdId
                       teamID:(NSString *)teamID
                   systemType:(EESystemType)systemType
       withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID;
    extra[@"appIdId"] = appIdId;

    [self _doActionWithName:@"deleteAppId.action"
                 systemType:systemType
             extraDictionary:extra
        andCompletionHandler:completionHandler];
}

#pragma mark - App Group 管理

/// 列出所有 App Group
- (void)listAllApplicationGroupsForTeamID:(NSString *)teamID
                               systemType:(EESystemType)systemType
                   withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID;

    [self _doActionWithName:@"listApplicationGroups.action"
                 systemType:systemType
             extraDictionary:extra
        andCompletionHandler:completionHandler];
}

/// 添加 App Group
- (void)addApplicationGroupWithIdentifier:(NSString *)identifier
                                  andName:(NSString *)groupName
                                forTeamID:(NSString *)teamID
                               systemType:(EESystemType)systemType
                   withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID;
    extra[@"identifier"] = identifier;
    extra[@"name"] = groupName;

    [self _doActionWithName:@"addApplicationGroup.action"
                 systemType:systemType
             extraDictionary:extra
        andCompletionHandler:completionHandler];
}

/// 分配 App Group 到 App ID
- (void)assignApplicationGroup:(NSString *)applicationGroup
              toApplicationIdId:(NSString *)appIdId
                         teamID:(NSString *)teamID
                     systemType:(EESystemType)systemType
           withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID ?: @"";
    extra[@"appIdId"] = appIdId ?: @"";
    extra[@"applicationGroups"] = applicationGroup ?: @"";

    [self _doActionWithName:@"assignApplicationGroupToAppId.action"
                 systemType:systemType
             extraDictionary:extra
        andCompletionHandler:completionHandler];
}

#pragma mark - 证书管理

/// 列出开发证书（带过滤选项）
- (void)listAllDevelopmentCertificatesWithFiltering:(BOOL)useFilter
                                            teamID:(NSString *)teamID
                                         systemType:(EESystemType)systemType
                             withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID;

    if (useFilter) {
        extra[@"filter[certificateType]"] = @"IOS_DEVELOPMENT";
    }

    [self _sendServiceRequestWithName:@"certificates"
                               method:@"GET"
                            systemType:systemType
                      extraDictionary:extra
                 andCompletionHandler:completionHandler];
}

/// 列出所有开发证书
- (void)listAllDevelopmentCertificatesForTeamID:(NSString *)teamID
                                     systemType:(EESystemType)systemType
                         withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    [self listAllDevelopmentCertificatesWithFiltering:NO
                                              teamID:teamID
                                           systemType:systemType
                               withCompletionHandler:completionHandler];
}

#pragma mark - 描述文件管理

/// 列出所有描述文件
- (void)listAllProvisioningProfilesForTeamID:(NSString *)teamID
                                 systemType:(EESystemType)systemType
                     withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID;

    [self _doActionWithName:@"listProvisioningProfiles.action"
                 systemType:systemType
             extraDictionary:extra
        andCompletionHandler:completionHandler];
}

/// 下载描述文件
- (void)getProvisioningProfileForAppIdId:(NSString *)appIdId
                              withTeamID:(NSString *)teamId
                              systemType:(EESystemType)systemType
                  andCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID;
    extra[@"appIdId"] = appIdId;

    [self _doActionWithName:@"downloadTeamProvisioningProfile.action"
                 systemType:systemType
             extraDictionary:extra
        andCompletionHandler:completionHandler];
}

/// 删除描述文件（按 Bundle ID 匹配）
- (void)deleteProvisioningProfileForApplication:(NSString *)applicationId
                                      andTeamID:(NSString *)teamID
                                      systemType:(EESystemType)systemType
                          withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    // 先列出所有描述文件，找到匹配的 Profile ID
    [self listAllProvisioningProfilesForTeamID:teamID
                                    systemType:systemType
                        withCompletionHandler:^(NSError *error, NSDictionary *plist) {

        if (error) {
            completionHandler(error, nil);
            return;
        }

        NSArray *profiles = plist[@"provisioningProfiles"];
        NSString *profileId = @"";

        // 查找匹配的描述文件
        for (NSDictionary *profile in profiles) {
            NSString *appId = profile[@"identifier"];
            BOOL matches = [appId rangeOfString:applicationId].location != NSNotFound;

            if (matches) {
                profileId = profile[@"provisioningProfileId"];
                break;
            }
        }

        if (profileId.length > 0) {
            // 执行删除操作
            NSMutableDictionary *extra = [NSMutableDictionary dictionary];
            extra[@"teamId"] = teamID;
            extra[@"provisioningProfileId"] = profileId;

            [self _doActionWithName:@"deleteProvisioningProfile.action"
                         systemType:systemType
                     extraDictionary:extra
                andCompletionHandler:completionHandler];
        } else {
            // 未找到匹配的描述文件
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"未找到包含指定 Bundle ID 的描述文件",
                NSLocalizedFailureReasonErrorKey: @"未找到包含指定 Bundle ID 的描述文件"
            };
            NSError *notFoundError = [NSError errorWithDomain:NSInvalidArgumentException
                                                        code:-1
                                                    userInfo:userInfo];

            completionHandler(notFoundError, nil);
        }
    }];
}

#pragma mark - 证书吊销

/// 按序列号吊销证书
- (void)revokeCertificateForSerialNumber:(NSString *)serialNumber
                              andTeamID:(NSString *)teamID
                              systemType:(EESystemType)systemType
                  withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID;
    extra[@"serialNumber"] = serialNumber;

    [self _doActionWithName:@"revokeDevelopmentCert.action"
                 systemType:systemType
             extraDictionary:extra
        andCompletionHandler:completionHandler];
}

/// 按标识符吊销证书（使用新版 API）
- (void)revokeCertificateForIdentifier:(NSString *)identifier
                            andTeamID:(NSString *)teamID
                            systemType:(EESystemType)systemType
                withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"teamId"] = teamID;

    [self _sendServiceRequestWithName:[NSString stringWithFormat:@"certificates/%@", identifier]
                               method:@"DELETE"
                            systemType:systemType
                      extraDictionary:extra
                 andCompletionHandler:completionHandler];
}

#pragma mark - CSR 提交

/// 提交代码签名请求以创建新证书
- (void)submitCodeSigningRequestForTeamID:(NSString *)teamId
                             machineName:(NSString *)machineName
                               machineID:(NSString *)machineID
                      codeSigningRequest:(NSData *)csr
                              systemType:(EESystemType)systemType
                  withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler {

    // 将 CSR 数据转为字符串
    NSString *stringifiedCSR = [[NSString alloc] initWithData:csr
                                                    encoding:NSUTF8StringEncoding];

    // 构建请求体（JSON API 格式）
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    attributes[@"certificateType"] = @"DEVELOPMENT";
    attributes[@"teamId"] = teamID;
    attributes[@"csrContent"] = stringifiedCSR;
    attributes[@"machineId"] = machineID;
    attributes[@"machineName"] = machineName;

    NSDictionary *requestBody = @{
        @"data": @{
            @"attributes": attributes,
            @"type": @"certificates"
        }
    };

    // 使用新版 JSON API 提交
    [self _sendRawServiceRequestWithName:@"certificates"
                                  method:@"post"
                               systemType:systemType
                         extraDictionary:requestBody
                    andCompletionHandler:completionHandler];
}

@end
