//
// Copyright (c) 2020. TikTok Inc.
//
// This source code is licensed under the MIT license found in
// the LICENSE file in the root directory of this source tree.
//

#import <UIKit/UIKit.h>
#import "TikTokAppEventStore.h"
#import "TikTokAppEventQueue.h"
#import "TikTokErrorHandler.h"
#import "TikTokBusiness.h"
#import "TikTokBusiness+private.h"

#define DISK_LIMIT 500

// Optimization to skip check if we know there are no persisted events
static BOOL canSkipAppEventDiskCheck = NO;
static BOOL canSkipMonitorEventDiskCheck = NO;
// Total number of events dumped as a result of exceeding max number of events in disk
static long numberOfEventsDumped = 0;

NSString * const appEventsFileName = @"com-tiktok-sdk-AppEventsPersistedEvents.json";
NSString * const monitorEventsFileName = @"com-tiktok-sdk-MonitorEventsPersistedEvents.json";

@implementation TikTokAppEventStore

+ (void)clearPersistedAppEvents {
    [self clearPersistedEventsAtFile:[self getAppEventsFilePath]];
}

+ (void)clearPersistedMonitorEvents {
    [self clearPersistedEventsAtFile:[self getMonitorEventsFilePath]];
}


+ (void)persistAppEvents:(NSArray *)queue {
    [self persistEvents:queue toFile:[self getAppEventsFilePath]];
}

+ (void)persistMonitorEvents:(NSArray *)queue {
    [self persistEvents:queue toFile:[self getMonitorEventsFilePath]];
}


+ (NSArray *)retrievePersistedAppEvents {
    NSNumber *fileReadStartTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];
    NSArray *events = [self retrievePersistedEventsFromFile:[self getAppEventsFilePath]];
    NSNumber *fileReadEndTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];
    if (!canSkipAppEventDiskCheck) {
        NSDictionary *fileReadMeta = @{
            @"ts": fileReadEndTime,
            @"latency": [NSNumber numberWithInt:[fileReadEndTime intValue] - [fileReadStartTime intValue]],
            @"size":@(events.count)
        };
        NSDictionary *monitorFileReadProperties = @{
            @"monitor_type": @"metric",
            @"monitor_name": @"file_r",
            @"meta": fileReadMeta
        };
        TikTokAppEvent *monitorFileReadEvent = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:monitorFileReadProperties withType:@"monitor"];
        @synchronized (self) {
            [[TikTokBusiness getQueue] addEvent:monitorFileReadEvent];
        }
    }
    return events;
}

+ (NSArray *)retrievePersistedMonitorEvents {
    return [self retrievePersistedEventsFromFile:[self getMonitorEventsFilePath]];
}


#pragma mark - Private Helpers
+ (void)clearPersistedEventsAtFile:(NSString *)path {
    [[NSFileManager defaultManager] removeItemAtPath:path
                                               error:NULL];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"inDiskEventQueueUpdated" object:nil];
    
    if ([path containsString:appEventsFileName]) {
        canSkipAppEventDiskCheck = YES;
    } else if ([path containsString:monitorEventsFileName]) {
        canSkipMonitorEventDiskCheck = YES;
    }
}

+ (void)persistEvents:(NSArray *)queue toFile:(NSString *)path
{
    if (!queue.count) {
        return;
    }
    @try {
        NSNumber *fileWriteStartTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];
        BOOL result;
        BOOL isMonitor = [path containsString:monitorEventsFileName];
        NSMutableArray *existingEvents = [NSMutableArray array];
        if (isMonitor) {
            existingEvents = [NSMutableArray arrayWithArray:[[self class] retrievePersistedMonitorEvents]];
            [[self class] clearPersistedMonitorEvents];
        } else {
            existingEvents = [NSMutableArray arrayWithArray:[[self class] retrievePersistedAppEvents]];
            [[self class] clearPersistedAppEvents];
        }
        [existingEvents addObjectsFromArray:queue];
        
        // if number of events to store is greater than DISK_LIMIT, store the later events with length of DISK_LIMIT
        if(existingEvents.count > DISK_LIMIT) {
            long difference = existingEvents.count - DISK_LIMIT;
            numberOfEventsDumped += difference;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"eventsDumped" object:nil userInfo:@{@"numberOfEventsDumped":@(numberOfEventsDumped)}];
            NSArray *existingEventsSliced = [existingEvents subarrayWithRange:NSMakeRange(difference, DISK_LIMIT)];
            // converts back to NSMutableArray type
            existingEvents = [existingEventsSliced mutableCopy];
        }
        
        if (@available(iOS 11, *)) {
            NSError *errorArchiving = nil;
            // archivedDataWithRootObject:requiringSecureCoding: available iOS 11.0+
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:existingEvents requiringSecureCoding:NO error:&errorArchiving];
            if (data && errorArchiving == nil) {
                NSError *errorWriting = nil;
                result = [data writeToFile:path options:NSDataWritingAtomic error:&errorWriting];
                result = result && (errorWriting == nil);
            } else {
                result = NO;
            }
        } else {
            // archiveRootObject used for iOS versions below 11.0
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            result = [NSKeyedArchiver archiveRootObject:existingEvents toFile:path];
#pragma clang diagnostic pop
        }
        
        if(result == YES) {
            if (isMonitor) {
                canSkipMonitorEventDiskCheck = NO;
            } else {
                canSkipAppEventDiskCheck = NO;
                NSNumber *fileWriteEndTime = [TikTokAppEventUtility getCurrentTimestampAsNumber];
                NSDictionary *fileWriteMeta = @{
                    @"ts": fileWriteEndTime,
                    @"latency": [NSNumber numberWithInt:[fileWriteEndTime intValue] - [fileWriteStartTime intValue]],
                    @"size":@(existingEvents.count)
                };
                NSDictionary *monitorFileWriteProperties = @{
                    @"monitor_type": @"metric",
                    @"monitor_name": @"file_w",
                    @"meta": fileWriteMeta
                };
                TikTokAppEvent *monitorFileWriteEvent = [[TikTokAppEvent alloc] initWithEventName:@"MonitorEvent" withProperties:monitorFileWriteProperties withType:@"monitor"];
                [[TikTokBusiness getQueue] addEvent:monitorFileWriteEvent];
            }
        } else {
            [TikTokErrorHandler handleErrorWithOrigin:NSStringFromClass([self class]) message:@"Failed to persist to disk"];
        }
    } @catch (NSException *exception) {
        [TikTokErrorHandler handleErrorWithOrigin:NSStringFromClass([self class]) message:@"Failed to persist to disk" exception:exception];
    }
}


+ (NSArray *)retrievePersistedEventsFromFile:(NSString *)path
{
    BOOL canSkipDiskCheck = ([path containsString:appEventsFileName] && canSkipAppEventDiskCheck) || ([path containsString:monitorEventsFileName] && canSkipMonitorEventDiskCheck);
    NSMutableArray *events = [NSMutableArray array];
    if (!canSkipDiskCheck) {
        @try {
            if (@available(iOS 11, *)) {
                NSData *data = [NSData dataWithContentsOfFile:path];
                NSError *errorUnarchiving = nil;
                // initForReadingFromData:error: available iOS 11.0+
                NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&errorUnarchiving];
                [unarchiver setRequiresSecureCoding:NO];
                [events addObjectsFromArray:[unarchiver decodeObjectOfClass:[NSArray class] forKey:NSKeyedArchiveRootObjectKey]];
            } else {
                // unarchiveObjectWithFile used for iOS versions below 11.0
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                [events addObjectsFromArray:[NSKeyedUnarchiver unarchiveObjectWithFile:path]];
#pragma clang diagnostic pop
            }
        } @catch (NSException *exception) {
            [TikTokErrorHandler handleErrorWithOrigin:NSStringFromClass([self class]) message:@"Failed to read from disk" exception:exception];
            // if exception is caused and failed to read from disk, delete the file
            [[self class] clearPersistedEventsAtFile:path];
        }
    }
    
    return events;
}

+ (NSString *)getFileDirectory {
    NSSearchPathDirectory directory = NSLibraryDirectory;
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(directory, NSUserDomainMask, YES);
    NSString *docDirectory = [paths objectAtIndex:0];
    return docDirectory;
}

+ (NSString *)getAppEventsFilePath
{
    return [[self getFileDirectory]  stringByAppendingPathComponent:appEventsFileName];
}

+ (NSString *)getMonitorEventsFilePath
{
    return [[self getFileDirectory]  stringByAppendingPathComponent:monitorEventsFileName];
}

+ (NSUInteger)persistedAppEventsCount {
    @try {
        NSMutableArray *events = [NSMutableArray array];
        if (@available(iOS 11, *)) {
            NSData *data = [NSData dataWithContentsOfFile:[self getAppEventsFilePath]];
            NSError *errorUnarchiving = nil;
            // initForReadingFromData:error: available iOS 11.0+
            NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&errorUnarchiving];
            [unarchiver setRequiresSecureCoding:NO];
            [events addObjectsFromArray:[unarchiver decodeObjectOfClass:[NSArray class] forKey:NSKeyedArchiveRootObjectKey]];
        } else {
            // unarchiveObjectWithFile used for iOS versions below 11.0
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [events addObjectsFromArray:[NSKeyedUnarchiver unarchiveObjectWithFile:[self getAppEventsFilePath]]];
#pragma clang diagnostic pop
        }
        return events.count;
    } @catch (NSException *exception) {
        [TikTokErrorHandler handleErrorWithOrigin:NSStringFromClass([self class]) message:@"Failed to read from disk" exception:exception];
        return 0;
    }
}

@end
