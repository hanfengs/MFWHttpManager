//
//  MFWHttpTaskAFNEngine.m
//  HttpManager
//
//  Created by MFWMobile on 15/10/13.
//  Copyright © 2015年 MFWMobile. All rights reserved.
//

#import "MFWHttpTaskAFNEngine.h"
#import "AFNetworking.h"
#import "MFWRequest.h"
#import "MFWResponse.h"
#import "MFWRequestBuilderPipeline.h"
#import "MFWResponseHandlerPipeline.h"
#import  <objc/runtime.h>
#import "MFWHttpManager.h"
#import "AFgzipRequestSerializer.h"
#import <AFHTTPSessionManager.h>

@interface MFWHttpDataTask (PackageMethods)
- (void)weak_setHttpEngine:(MFWHttpTaskEngine *)engine;
@end

#define LOCK(...) OSSpinLockLock(&_lock); \
__VA_ARGS__; \
OSSpinLockUnlock(&_lock);


typedef enum{
    MapTaskStatusNone  =     0,
    MapTaskStatusAdded =     1,
    MapTaskStatusStarted =   2,
    MapTaskStatusSucceeded = 3,
    MapTaskStatusFailed =    4,
}MapTaskStatus;

typedef NS_ENUM(NSUInteger, MapTaskType)
{
    MapTaskTypeRequest = 0,
    MapTaskTypeDownload ,
    MapTaskTypeUpload
};

const char *MFWHttpTaskResponseKEY = "_response";
@interface MFWHttpDataTask(MFWHttpTaskAFNEngine)
//获取对应的资源ID
@property (nonatomic, assign) MFWHttpTaskStatus taskStatus;                     //task 状态
@end


@implementation MFWHttpDataTask(MFWHttpTaskAFNEngine)

@dynamic taskStatus;

- (void)setResponse:(MFWResponse *)response
{
    objc_setAssociatedObject(self, &MFWHttpTaskResponseKEY, response, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (MFWResponse *)response
{
    return objc_getAssociatedObject(self, &MFWHttpTaskResponseKEY);
}
@end


#define MFWMAPTASK_DESTROY_NOTIFICATION @"MFWMAPTASK_DESTROY_NOTIFICATION"

const char *NSURLSessionDownloadTaskResourceIDKEY = "NSURLSessionDownloadTaskResourceIDKEY";
@interface NSObject(MFWHttpTaskAFNEngine)
@property(nonatomic,strong)NSString * mFWHttpTaskAFNEngine_resourceID;
@end

@implementation NSObject(MFWHttpTaskAFNEngine)

- (void)setMFWHttpTaskAFNEngine_resourceID:(NSString *)mFWHttpTaskAFNEngine_resourceID
{
     objc_setAssociatedObject(self, &NSURLSessionDownloadTaskResourceIDKEY, mFWHttpTaskAFNEngine_resourceID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSString *)mFWHttpTaskAFNEngine_resourceID
{
     return  objc_getAssociatedObject(self, &NSURLSessionDownloadTaskResourceIDKEY);
}
@end


/////////////////////////////////////////////////////////////////////////////////////////////////////
@interface __MFWAFNMapTask : NSObject

@property(nonatomic,  copy) NSString *identifier;
@property(nonatomic,strong) NSURLSessionTask *sessionTask;
@property(nonatomic,strong) NSMutableArray<MFWHttpDataTask *> *tasks;
@property(nonatomic,assign) MapTaskStatus mapTaskStatus;
@property(nonatomic,  copy) NSString *url;
@property(nonatomic,strong) NSDictionary *parameters;
@property(nonatomic,strong) NSDictionary<NSString*,NSString*> *requestHeaders;
@property(nonatomic,  copy) NSString *httpMethodString;
@property(nonatomic,strong) NSData *responseData;
@property(nonatomic,strong) NSError *error;
@property(nonatomic,assign) MapTaskType type;
@property(nonatomic,  copy) MFWResponseHandlerPipeline *responsePlugin;//公有后插件
@property(nonatomic,assign) NSTimeInterval timeOut;
@property(nonatomic,strong) NSProgress *progress; // 上传下载用
@property(nonatomic,strong) NSURL *downLoadFilePath; //下载下来的文件地址;
@property(nonatomic,strong) NSDictionary<NSString *, id> *uploadData; //only uploadTaskType use
@property(nonatomic,assign) BOOL requestSupportGzip;


- (void)addHttpTask:(MFWHttpDataTask *)httpTask;

- (void)cancelHttpTask:(MFWHttpDataTask *)httpTask;

- (BOOL)isRunning;

- (BOOL)isEmpty;

@end

@implementation __MFWAFNMapTask

- (instancetype)init
{
    self = [super init];
    if(self){
        _tasks = [NSMutableArray array];
    }
    return self;
}

- (void)addHttpTask:(MFWHttpDataTask *)httpTask
{
    if (httpTask != nil && ![self.tasks containsObject:httpTask]) {
        [self.tasks addObject:httpTask];
        httpTask.taskStatus = self.sessionTask != nil ? MFWHttpTaskStatusStarted:MFWHttpTaskStatusAdded;
    }
}


- (void)cancelHttpTask:(MFWHttpDataTask *)httpTask
{
    if (httpTask == nil) {
        return;
    }
    
    dispatch_block_t block = ^{
        if([self.tasks containsObject:httpTask]){
            httpTask.error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            
            [self.class _runResponsePluginForTask:httpTask publicResponsePlugin:self.responsePlugin completion:^(MFWHttpDataTask *task) {
                if(task.compBlock != nil){
                    task.compBlock(task, NO, YES, nil, task.error);
                }
                
                task.taskStatus = MFWHttpTaskStatusCancelled;
            }];
            
            [self.tasks removeObject:httpTask];
        }
    };
    
    if(block != nil) {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}


- (BOOL)isRunning
{
    return self.sessionTask != nil ? YES:NO;
}

- (BOOL)isEmpty
{
    return [self.tasks count] == 0 ? YES:NO;
}

#pragma mark - 执行后插件
+ (void)_runResponsePluginForTask:(MFWHttpDataTask *)httpTask
             publicResponsePlugin:(MFWResponseHandlerPipeline *)publicResponsePlugin
                       completion:(void(^)(MFWHttpDataTask *task))completion
{
    MFWResponseBaseHandler *copiedPrivate = [httpTask.responsePlugin copyWithZone:nil];
    MFWResponseHandlerPipeline *copiedPublic = [publicResponsePlugin copy];
    
    MFWHttpResponseHandleBlock publicHandleBlock = ^(MFWHttpDataTask *task) {
        
        if (copiedPrivate) {
            MFWResponseHandlerPipeline *privatePipeline = nil;
            
            if ([copiedPrivate isKindOfClass:[MFWResponseHandlerPipeline class]]) {
                privatePipeline = (id)copiedPrivate;
            }
            else {
                privatePipeline = [MFWResponseHandlerPipeline handlerPipeline:@[copiedPrivate]];
            }
            
            [privatePipeline setPipelineHandleCompletionBlock:^(MFWHttpDataTask *task) {
                if (completion) completion(httpTask);
            }];
            
            privatePipeline.responseHandleBlock(httpTask);
            
        }
        else {
            if (completion) completion(httpTask);
        }
        
    };
    
    if (copiedPublic) {
        [copiedPublic setPipelineHandleCompletionBlock:publicHandleBlock];
        copiedPublic.responseHandleBlock(httpTask);
    }
    else {
        publicHandleBlock(httpTask);
    }
}


#pragma mark - 请求完成的回调
- (void)_completion
{
    MFWHttpManagerAssert([NSThread isMainThread], @"必须保证在主线程调用这个方法 %s", __PRETTY_FUNCTION__);//只是一个断言，AFN 会保证完成的回调一定在主线程当中
    
    NSArray *array = [self.tasks mutableCopy];
    
    [array enumerateObjectsUsingBlock:^(MFWHttpDataTask * _Nonnull aTask, NSUInteger idx, BOOL * _Nonnull stop) {
        MFWResponse *response = [[MFWResponse alloc] initWithUrlResponse:self.sessionTask.response responseData:self.responseData];
        aTask.response = response;
        aTask.error = self.error;
        
        if ([aTask.error.domain isEqualToString:NSURLErrorDomain]
            && aTask.error.code==NSURLErrorCancelled) {
            
            [self.class _runResponsePluginForTask:aTask publicResponsePlugin:self.responsePlugin completion:^(MFWHttpDataTask *task) {
                if(task.compBlock != nil){
                    task.compBlock(task, NO, YES, nil, task.error);
                }
                task.taskStatus = MFWHttpTaskStatusCancelled;
            }];
        }
        else {
            [self.class _runResponsePluginForTask:aTask publicResponsePlugin:self.responsePlugin completion:^(MFWHttpDataTask *task) {
                if(aTask.compBlock != nil){
                    aTask.compBlock(task, task.error == nil?YES:NO, NO, aTask.response.responseData, task.error);
                }
                
                if (task.error) {
                    task.taskStatus = MFWHttpTaskStatusFailed;
                }
                else {
                    task.taskStatus = MFWHttpTaskStatusSucceeded;
                }
            }];
        }
        
         [self.tasks removeObject:aTask];
    }];

    [self _destroy];
}


#pragma mark 销毁
- (void)_destroy
{
    [self.tasks removeAllObjects];
    [[NSNotificationCenter defaultCenter] postNotificationName:MFWMAPTASK_DESTROY_NOTIFICATION object:nil userInfo:@{@"identifier":self.identifier}];
}


#pragma mark - override setter
- (void)setMapTaskStatus:(MapTaskStatus)mapTaskStatus
{
    _mapTaskStatus  = mapTaskStatus;
    switch (_mapTaskStatus) {
        case MapTaskStatusAdded:
        {
            [self.tasks enumerateObjectsUsingBlock:^(MFWHttpDataTask * _Nonnull httpTask, NSUInteger idx, BOOL * _Nonnull stop) {
                if(httpTask.taskStatus != MFWHttpTaskStatusAdded){
                    httpTask.taskStatus = MFWHttpTaskStatusAdded;
                }
            }];
        } break;
        
        case MapTaskStatusStarted:
        {
            [self.tasks enumerateObjectsUsingBlock:^(MFWHttpDataTask * _Nonnull httpTask, NSUInteger idx, BOOL * _Nonnull stop) {
                if(httpTask.taskStatus != MFWHttpTaskStatusStarted){
                    httpTask.taskStatus = MFWHttpTaskStatusStarted;
                }
            }];
        } break;

        default://success or failure
        {
            dispatch_async(dispatch_get_main_queue(), ^{
              [self _completion];
            });
        }
        break;
    }
}

#pragma mark override downLoadFilePath
- (void)setDownLoadFilePath:(NSURL *)downLoadFilePath
{
    _downLoadFilePath = downLoadFilePath;
    if(downLoadFilePath != nil && self.type == MapTaskTypeDownload){
        NSString *fileName = [self.sessionTask.response suggestedFilename];
        [self.tasks enumerateObjectsUsingBlock:^(MFWHttpDataTask * _Nonnull aTask, NSUInteger idx, BOOL * _Nonnull stop) {
            if([aTask.saveDownloadFileName length]<1 && [fileName length]>0){
                aTask.saveDownloadFileName = fileName;
            }
            if([aTask.saveDownloadFileName length]>0 && [aTask.saveDownloadFilePath length]>0){
                NSFileManager *fileManager = [NSFileManager defaultManager];
                NSError *error = nil;
                NSURL *targetURL= [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/%@",aTask.saveDownloadFilePath,aTask.saveDownloadFileName]];
                if(![fileManager fileExistsAtPath:[NSString stringWithFormat:@"%@/%@",aTask.saveDownloadFilePath,aTask.saveDownloadFileName]]){
                    [fileManager copyItemAtURL:downLoadFilePath  toURL:targetURL error:&error];
                }
            }
        }];
    }
}


- (void)setProgress:(NSProgress *)progress
{
    dispatch_async(dispatch_get_main_queue(), ^{
        _progress = progress;
        [self.tasks enumerateObjectsUsingBlock:^(MFWHttpDataTask * _Nonnull httpTask, NSUInteger idx, BOOL * _Nonnull stop) {
            if(httpTask.progerssBlock != nil){
                httpTask.progerssBlock(httpTask,progress);
            }
        }];
    });
}

@end
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
static NSInteger afn_background_session_index = 0;
#define  BACKGROUND_SESSION_IDENTIFIER [NSString stringWithFormat:@"com.mafengwo.mobile.backgroundSession.%d", (int)afn_background_session_index++]
#define  TEMP_DOWNLOAD_TABLE_PATH @"/Documents/.TempDownloadTable"
#define  TEMP_DOWNLOAD_TABLE_FILE_NAME @"download.plist"
#define  TEMP_DOWNLOAD_FILE_PATH @"/Library/Caches/com.mafengwo.httpManager/.tempDownload"
#define  KEY_TEMP_PATH   @"temp_path"
#define  KEY_CREATE_TIME @"create_time"

@interface MFWHttpTaskAFNEngine()

@property (nonatomic,strong) AFHTTPSessionManager *sessionManager;
//@property (nonatomic,strong) AFHTTPSessionManager *backgroundSessionManager;
@property (nonatomic,strong) NSMutableDictionary  *tempDownloadTable; //临时下载表内存缓存
@property (nonatomic,strong) NSMutableDictionary<NSString *,__MFWAFNMapTask*> *repeatRequestFilter; //重复请求过滤器,当请求同一资源的MFWHttpTask已经在队列中存在了,那么就不再重复的发起请求,只同步该Task的状态。
@property (nonatomic,strong) NSPointerArray *taskList;
@property (nonatomic,strong) dispatch_semaphore_t  semaphore;
@end


@implementation MFWHttpTaskAFNEngine
@synthesize HTTPMaximumConnectionsPerHost = _HTTPMaximumConnectionsPerHost;
@synthesize maxConcurrentOperationCount = _maxConcurrentOperationCount;


- (instancetype)init
{
    self = [super init];
    if(self){
        _sessionManager = [AFHTTPSessionManager manager];
        if([NSURLSessionConfiguration respondsToSelector:@selector(backgroundSessionConfigurationWithIdentifier:)]){
//            _backgroundSessionManager = [[AFHTTPSessionManager alloc] initWithSessionConfiguration:[NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:BACKGROUND_SESSION_IDENTIFIER]];
        }
        else{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated"
//            _backgroundSessionManager = [[AFHTTPSessionManager alloc] initWithSessionConfiguration:[NSURLSessionConfiguration backgroundSessionConfiguration:BACKGROUND_SESSION_IDENTIFIER]];
#pragma clang diagnostic pop
        }
        
        _sessionManager.responseSerializer = [AFHTTPResponseSerializer serializer];
       // _backgroundSessionManager.responseSerializer = [AFHTTPResponseSerializer serializer];
        
        [self setHTTPMaximumConnectionsPerHost:_sessionManager.session.configuration.HTTPMaximumConnectionsPerHost]; // Default 4
        [self setMaxConcurrentOperationCount:_sessionManager.operationQueue.maxConcurrentOperationCount]; // Default 2
        
        [self _createTempDownloadTableDirectory];
        _tempDownloadTable = [self _readTempDownloadTablePlist];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_synchronizedTempDownloadTable) name:UIApplicationDidEnterBackgroundNotification object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_filterRemoveMapTask:) name:MFWMAPTASK_DESTROY_NOTIFICATION object:nil];
        _repeatRequestFilter = [[NSMutableDictionary alloc] init];
        //_lock = OS_SPINLOCK_INIT;
        _taskList = [NSPointerArray weakObjectsPointerArray];
        _semaphore = dispatch_semaphore_create(1);
    }
    return self;
}

#pragma mark 获取MapTask
- (__MFWAFNMapTask*)_getMapTaskByHttpTask:(MFWHttpDataTask *)httpTask
{
    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
    if ([httpTask.identifier length]<1) {
        MFWHttpManagerAssert(NO, @"httpTask resourceID can't be a  nil");
        dispatch_semaphore_signal(self.semaphore);
        return nil;
    }else {
        if ([self.repeatRequestFilter objectForKey:httpTask.identifier] != nil
           && [[self.repeatRequestFilter objectForKey:httpTask.identifier] isMemberOfClass:[__MFWAFNMapTask class]]) {
            __MFWAFNMapTask *mapTask = [self.repeatRequestFilter objectForKey:httpTask.identifier];
            
            if(![mapTask.tasks containsObject:httpTask]){
                [mapTask addHttpTask:httpTask];
                [self.taskList addPointer:(__bridge void*)httpTask];
            }
            dispatch_semaphore_signal(self.semaphore);
            return mapTask;
        }
        else {
            __MFWAFNMapTask *mapTask = [[__MFWAFNMapTask alloc] init];
            
            mapTask.identifier = httpTask.identifier;
            mapTask.url = httpTask.request.URLString;
            mapTask.parameters = httpTask.request.params;
            mapTask.requestHeaders = httpTask.request.header.httpRequestHeaderFields;
            mapTask.httpMethodString = httpTask.request.httpMethodString;
            mapTask.type = (int)httpTask.taskType;
            mapTask.requestSupportGzip = httpTask.requestSupportGzip; //requst httpBody Gzip support ---> Content-Encoding = gzip
            if (self.responsePlugin) {
                // 全部转换成pipeline，让pipeline处理runningInBackground的状况
                if ([self.responsePlugin isKindOfClass:[MFWResponseHandlerPipeline class]]) {
                    mapTask.responsePlugin = (MFWResponseHandlerPipeline *)self.responsePlugin;
                }
                else {
                    mapTask.responsePlugin = [MFWResponseHandlerPipeline handlerPipeline:@[self.responsePlugin]];
                }
            }
            
            mapTask.timeOut = httpTask.request.requestTimeout;
            [mapTask addHttpTask:httpTask];
            
            [self.taskList addPointer:(__bridge void*)httpTask];
            
            if(httpTask.taskType == MFWHttpTaskTypeUpload){
                mapTask.uploadData = httpTask.uploadData;
            }
            [self.repeatRequestFilter setObject:mapTask forKey:httpTask.identifier];
            dispatch_semaphore_signal(self.semaphore);
            return mapTask;
        }
    }
}

#pragma mark - 入口

- (void)executeTask:(MFWHttpDataTask *)httpTask completion:(MFWHttpTaskCompletion)completion
{
    if (httpTask == nil || [httpTask.request.URLString length] ==0)
    {
        return;
    }
    if(completion != nil)
    {
        httpTask.compBlock = completion;
    }
    
    if(httpTask.requestPlugin != nil &&
       httpTask.requestPlugin.requestBuildBlock !=nil)
    {
        httpTask.requestPlugin.requestBuildBlock(httpTask);
    }
    
    if(self.requestPlugin != nil &&
       self.requestPlugin.requestBuildBlock !=nil)
    {
        self.requestPlugin.requestBuildBlock(httpTask);
    }
    
    __MFWAFNMapTask *mapTask = [self _getMapTaskByHttpTask:httpTask];
    switch (httpTask.taskType) {
        case MFWHttpTaskTypeRequest:
        {
           [self _requestMapTask:mapTask];
        }
            break;
        case MFWHttpTaskTypeDownload:
        {
           [self _downloadMapTask:mapTask];
        }
            break;
        case MFWHttpTaskTypeUpload:
        {
            [self _uploadMapTask:mapTask];
        }
            break;
        default:
        {
            MFWHttpManagerAssert(NO, @"taskType is unkonw");
        }
            break;
    }
    
    // 设置engine
    [httpTask weak_setHttpEngine:self];
}

#pragma mark 普通请求
- (void)_requestMapTask:(__MFWAFNMapTask *)mapTask
{
    if(![mapTask isRunning]){
        mapTask.mapTaskStatus = MapTaskStatusAdded;
        NSURLSessionDataTask *dataTask = nil;
        NSError *error = nil;
        NSMutableURLRequest *request;
        if(mapTask.requestSupportGzip){
            AFgzipRequestSerializer *gzip_serializer = [AFgzipRequestSerializer serializerWithSerializer:self.sessionManager.requestSerializer];
            request = [gzip_serializer requestWithMethod:mapTask.httpMethodString URLString:mapTask.url parameters:mapTask.parameters error:&error];
        }else{
            request = [self.sessionManager.requestSerializer requestWithMethod:mapTask.httpMethodString URLString:mapTask.url parameters:mapTask.parameters error:&error];
        }
        request.timeoutInterval = mapTask.timeOut;
        
        [[mapTask.requestHeaders allKeys] enumerateObjectsUsingBlock:^(NSString *key, NSUInteger idx, BOOL * _Nonnull stop) {
            NSString *value = [mapTask.requestHeaders valueForKey:key];
            [request addValue:value forHTTPHeaderField:key];
        }];
        if(error == nil){
//            dataTask = [self.sessionManager dataTaskWithRequest:request completionHandler:^(NSURLResponse * _Nonnull response, id  _Nonnull responseObject, NSError * _Nonnull error) {
//                mapTask.responseData = responseObject;
//                mapTask.error = error;
//                mapTask.mapTaskStatus =  error == nil ? MapTaskStatusSucceeded : MapTaskStatusFailed;
//            }];
            
            dataTask = [self.sessionManager dataTaskWithRequest:request uploadProgress:^(NSProgress * _Nonnull uploadProgress) {

            } downloadProgress:^(NSProgress * _Nonnull downloadProgress) {

            } completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
                mapTask.responseData = responseObject;
                mapTask.error = error;
                mapTask.mapTaskStatus =  error == nil ? MapTaskStatusSucceeded : MapTaskStatusFailed;
            }];
            dataTask.mFWHttpTaskAFNEngine_resourceID = mapTask.identifier;
            mapTask.sessionTask = dataTask;
            [dataTask resume];
            mapTask.mapTaskStatus = MapTaskStatusStarted;
        }else{
            MFWHttpManagerAssert(NO, @"创建普通请求失败");
        }
    }
}


#pragma mark 下载请求
- (void)_downloadMapTask:(__MFWAFNMapTask *)mapTask
{
    if(![mapTask isRunning]){
        NSString *resourceID = mapTask.identifier;
        NSString *path = [NSString stringWithFormat:@"%@%@/%@.plist",NSHomeDirectory(),TEMP_DOWNLOAD_FILE_PATH,resourceID];
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSURLSessionDownloadTask *downloadSessionTask = nil;
        mapTask.mapTaskStatus = MapTaskStatusAdded;
        MFWHttpTaskAFNEngine *wself = self;
        
        if(data != nil){
            downloadSessionTask =  [self.sessionManager downloadTaskWithResumeData:data progress:^(NSProgress *progress){
                mapTask.progress = progress;
            } destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
                //只有下载成功才会走这里
                mapTask.downLoadFilePath = targetPath;
                return targetPath;
            } completionHandler:^(NSURLResponse * response, NSURL * filePath, NSError * error) {
                MFWHttpTaskAFNEngine *sself = wself;
                mapTask.error = error;
                mapTask.mapTaskStatus = error == nil?MapTaskStatusSucceeded:MapTaskStatusFailed;
                if(error == nil){
                    [sself _clearDownloadLogByResourceId:mapTask.identifier];
                }
            }];
        }else{
            NSError *error = nil;
            NSMutableURLRequest *request = [self.sessionManager.requestSerializer requestWithMethod:mapTask.httpMethodString URLString:mapTask.url parameters:mapTask.parameters error:&error];
            request.timeoutInterval = mapTask.timeOut;
            [[mapTask.requestHeaders allKeys] enumerateObjectsUsingBlock:^(NSString *key, NSUInteger idx, BOOL * _Nonnull stop) {
                NSString *value = [mapTask.requestHeaders valueForKey:key];
                [request addValue:value forHTTPHeaderField:key];
            }];
            if(error == nil){
                [self _clearDownloadLogByResourceId:mapTask.identifier];
                downloadSessionTask =  [self.sessionManager downloadTaskWithRequest:request progress:^(NSProgress *progress){
                    mapTask.progress = progress;
                } destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
                    //只有下载成功才会走这里
                    mapTask.downLoadFilePath = targetPath;
                    return targetPath;
                } completionHandler:^(NSURLResponse * response, NSURL * filePath, NSError * error) {
                    MFWHttpTaskAFNEngine *sself = wself;
                    mapTask.error = error;
                    mapTask.mapTaskStatus = error == nil?MapTaskStatusSucceeded:MapTaskStatusFailed;
                    if(error == nil){
                        [sself _clearDownloadLogByResourceId:mapTask.identifier];
                    }
                }];
            }else{
                MFWHttpManagerAssert(NO, @"创建下载请求失败");
            }
        }
        downloadSessionTask.mFWHttpTaskAFNEngine_resourceID = mapTask.identifier;
        mapTask.sessionTask = downloadSessionTask;
        [downloadSessionTask resume];
        mapTask.mapTaskStatus = MapTaskStatusStarted;
    }
}

//清理下载记录
- (void)_clearDownloadLogByResourceId:(NSString *)resourceID
{
    if([resourceID length]>0){
        [self.tempDownloadTable removeObjectForKey:resourceID];
        [self _synchronizedTempDownloadTable];
        [self _removeTempDownloadFileByFileName:resourceID];
    }
}

//创建临时下载表文件夹
- (void)_createTempDownloadTableDirectory
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *path = [NSString stringWithFormat:@"%@%@",NSHomeDirectory(),TEMP_DOWNLOAD_TABLE_PATH];
    if(![fileManager fileExistsAtPath:path]){
        NSError *error =nil;
        [fileManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
    }
}


//把临时下载表读进内存
- (NSMutableDictionary *)_readTempDownloadTablePlist
{
     NSFileManager *fileManager = [NSFileManager defaultManager];
     NSString *path = [NSString stringWithFormat:@"%@%@/%@",NSHomeDirectory(),TEMP_DOWNLOAD_TABLE_PATH,TEMP_DOWNLOAD_TABLE_FILE_NAME];
    if([fileManager fileExistsAtPath:path]){
        NSMutableDictionary *plist = [[NSMutableDictionary alloc] initWithContentsOfFile:path];
        //检查一下下载缓存表的数据时间，如果大于一周就丢弃下载缓存记录数据
        if([plist count]>0){
            for(NSString *resourceId in [plist allKeys]){
                NSString *timeStr = [plist objectForKey:resourceId];
                if([timeStr length]>0){
                    NSTimeInterval createTime = [timeStr floatValue];
                    NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970];
                    if((nowTime - createTime)> 3600*24*7){
                        [plist removeObjectForKey:resourceId];
                        [self _removeTempDownloadFileByFileName:resourceId];
                    }
                }
            }
        }
        return plist;
    }else{
        return [NSMutableDictionary dictionary];
    }
}

//把内存中的临时下载表持久化
-(void)_synchronizedTempDownloadTable
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
       NSString *path = [NSString stringWithFormat:@"%@%@/%@",NSHomeDirectory(),TEMP_DOWNLOAD_TABLE_PATH,TEMP_DOWNLOAD_TABLE_FILE_NAME];
       [self.tempDownloadTable writeToFile:path atomically:YES];
    });
}




- (NSDictionary *)_changeDictByPlistData:(NSData *)plistData
{
    if(plistData != nil){
        NSPropertyListFormat format;
        NSDictionary* dict = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:&format error:nil];
        return dict;
    }else{
        return nil;
    }
}

//保存临时下载数据
- (void)_saveTempDownloadFileBy:(NSData *)data fileName:(NSString *)fileName
{
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *path = [NSString stringWithFormat:@"%@%@",NSHomeDirectory(),TEMP_DOWNLOAD_FILE_PATH];
    if(data != nil && [fileName length]>0){
       if(![fileManager fileExistsAtPath:path]){
            [fileManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
       }
        [self.tempDownloadTable setObject:[NSString stringWithFormat:@"%f",[[NSDate date] timeIntervalSince1970]] forKey:fileName];
        [data writeToFile:[NSString stringWithFormat:@"%@/%@.plist",path,fileName] atomically:YES];
        [self _synchronizedTempDownloadTable];
    }
}




//删除临时下载数据
- (void)_removeTempDownloadFileByFileName:(NSString *)fileName
{
    if([fileName length]<1){
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *path = [NSString stringWithFormat:@"%@%@/%@.plist",NSHomeDirectory(),TEMP_DOWNLOAD_FILE_PATH,fileName];
        if([fileManager fileExistsAtPath:path]){
            [fileManager removeItemAtPath:path error:nil];
        }
    });
}

#pragma mark 上传请求
- (void)_uploadMapTask:(__MFWAFNMapTask *)mapTask
{
    if(![mapTask isRunning]){
        NSError *error = nil;
        NSMutableURLRequest *request =  [self.sessionManager.requestSerializer multipartFormRequestWithMethod:mapTask.httpMethodString URLString:mapTask.url parameters:mapTask.parameters constructingBodyWithBlock:^(id<AFMultipartFormData>  _Nonnull formData) {
            [[mapTask.uploadData allKeys] enumerateObjectsUsingBlock:^(NSString * _Nonnull key, NSUInteger idx, BOOL * _Nonnull stop) {
                id data = [mapTask.uploadData objectForKey:key];
                if([data isKindOfClass:[NSData class]]){
                    [formData appendPartWithFileData:data name:key fileName:key mimeType:@"application/octet-stream"];
                }else if([data isKindOfClass:[NSURL class]]){
                    [formData appendPartWithFileURL:data name:key error:nil];
                }else{
                     MFWHttpManagerAssert(NO, @"上传的数据必须为 NSData 或者 NSURL  的类型", __PRETTY_FUNCTION__);
                }
            }];
        } error:&error];
        request.timeoutInterval = mapTask.timeOut;
        [[mapTask.requestHeaders allKeys] enumerateObjectsUsingBlock:^(NSString *key, NSUInteger idx, BOOL * _Nonnull stop) {
            NSString *value = [mapTask.requestHeaders valueForKey:key];
            [request addValue:value forHTTPHeaderField:key];
        }];
        if(error == nil){
            mapTask.mapTaskStatus = MapTaskStatusAdded;
            NSURLSessionUploadTask *uploadDataTask = nil;
            uploadDataTask = [self.sessionManager uploadTaskWithStreamedRequest:request  progress:^(NSProgress *aProgress){
               mapTask.progress = aProgress;
            }completionHandler:^(NSURLResponse * _Nonnull response, id  _Nonnull responseObject, NSError * _Nonnull error){
                mapTask.responseData = responseObject;
                mapTask.error = error;
                mapTask.mapTaskStatus =  error == nil ? MapTaskStatusSucceeded : MapTaskStatusFailed;
            }];
            uploadDataTask.mFWHttpTaskAFNEngine_resourceID = mapTask.identifier;
            mapTask.sessionTask = uploadDataTask;
            [uploadDataTask resume];
            mapTask.mapTaskStatus = MapTaskStatusStarted;
        }else{
            MFWHttpManagerAssert(NO, @"创建上传请求失败");
        }
    }
}

#pragma mark ExecuteNotification
- (void)_filterRemoveMapTask:(NSNotification *)notfi
{
    NSDictionary *dict = notfi.userInfo;
    if([dict count]>0){
        NSString *identifier = dict[@"identifier"];
        if([identifier length]>0){
            [self.repeatRequestFilter removeObjectForKey:identifier];
        }
    }
}

#pragma mark- 取消请求
- (void)cancelTask:(MFWHttpDataTask *)httpTask
{
    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
    NSArray *tasks = [[self.taskList allObjects] copy];
    if (httpTask == nil || ![tasks containsObject:httpTask]) {
        dispatch_semaphore_signal(self.semaphore);
        return;
    }
    dispatch_semaphore_signal(self.semaphore);
    
    __MFWAFNMapTask *mapTask = [self _getMapTaskByHttpTask:httpTask];
    [mapTask cancelHttpTask:httpTask];
    if (mapTask != nil && [mapTask isEmpty]) {
        NSURLSessionTask *sessionTask = mapTask.sessionTask;
        __weak MFWHttpTaskAFNEngine *wself = self;
        
        if(mapTask.type == MapTaskTypeDownload && [sessionTask isKindOfClass:[NSURLSessionDownloadTask class]])
        {
            NSURLSessionDownloadTask *sessionDownloadTask = (NSURLSessionDownloadTask *)sessionTask;
            [sessionDownloadTask cancelByProducingResumeData:^(NSData *resumeData) {
                if(resumeData != nil){
                    MFWHttpTaskAFNEngine *sself = wself;
                    [sself _saveTempDownloadFileBy:resumeData fileName:sessionTask.mFWHttpTaskAFNEngine_resourceID];
                }
             }];
        }
        else{
            [sessionTask cancel];
        }
    }
}

- (void)cancelAllTask
{
    [[self.taskList allObjects] enumerateObjectsUsingBlock:^(MFWHttpDataTask * _Nonnull aTask, NSUInteger idx, BOOL * _Nonnull stop) {
        if(aTask.taskStatus == MFWHttpTaskStatusAdded || aTask.taskStatus == MFWHttpTaskStatusStarted){
            [self cancelTask:aTask];
        }
    }];
}

#pragma mark override getter httpTasks
- (NSArray *)httpTasks
{
    return [self.taskList allObjects];
}

#pragma mark override setter HTTPMaximumConnectionsPerHost
- (void)setHTTPMaximumConnectionsPerHost:(NSUInteger)HTTPMaximumConnectionsPerHost
{
    if(HTTPMaximumConnectionsPerHost < 1){
        return;
    }
    _HTTPMaximumConnectionsPerHost = HTTPMaximumConnectionsPerHost;
    
    if(self.sessionManager.session.configuration != nil){
        self.sessionManager.session.configuration.HTTPMaximumConnectionsPerHost =HTTPMaximumConnectionsPerHost;
    }
    
//    if(self.backgroundSessionManager.session.configuration.HTTPMaximumConnectionsPerHost){
//        self.backgroundSessionManager.session.configuration.HTTPMaximumConnectionsPerHost =HTTPMaximumConnectionsPerHost;
//    }
}

#pragma mark override setter maxConcurrentOperationCount

-(void)setMaxConcurrentOperationCount:(NSUInteger)maxConcurrentOperationCount
{
    if(maxConcurrentOperationCount <1){
        return;
    }
    _maxConcurrentOperationCount = maxConcurrentOperationCount;
    if(self.sessionManager.operationQueue != nil){
        self.sessionManager.operationQueue.maxConcurrentOperationCount = _maxConcurrentOperationCount;
    }
//    if(self.backgroundSessionManager.operationQueue != nil){
//        self.backgroundSessionManager.operationQueue.maxConcurrentOperationCount = _maxConcurrentOperationCount;
//    }
}


@end
