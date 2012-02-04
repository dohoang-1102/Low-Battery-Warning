//
//  main.m
//  LowBatteryWarning
//
//  Created by Nicholas Hutchinson on 7/01/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//
#undef __APPLE_API_PRIVATE // FIXME: This is a workaround for a problem on the 10.7's SDK. 
#include <sandbox.h>

#import <Foundation/Foundation.h>
#import <getopt.h>
#import <notify.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/ps/IOPSKeys.h>
#import <IOKit/ps/IOPowerSources.h>


@interface CriticalBatteryMonitor : NSObject
- (void)startMonitoring;

@property (readonly) double criticalThreshold;
@end


@interface CriticalBatteryMonitor ()
- (void)systemPowerInfoDidChange;
- (void)putSystemToSleep;
- (void)performBeep;
- (void)registerForPowerNotifications;
@end


@implementation CriticalBatteryMonitor {
    @private
    int _notifyToken;
    BOOL _isRegistered;
    double _lastSeenPercentageCapacity;
}

- (double)criticalThreshold
{
    return 1.0;
}

- (id)init {    
    self = [super init];
    if (self) {
        _lastSeenPercentageCapacity = 100.0;
    }
    return self;
}

- (void)dealloc {
    if (_isRegistered) {
        notify_cancel(_notifyToken);
        _isRegistered = NO;
    }
}

#pragma  mark -

- (void)registerForPowerNotifications
{
    assert(!_isRegistered);

    _isRegistered = YES;
    __weak CriticalBatteryMonitor* weakself = self;
    notify_register_dispatch(kIOPSTimeRemainingNotificationKey, &_notifyToken, dispatch_get_main_queue(), ^(int token) {
        @autoreleasepool {
            [weakself systemPowerInfoDidChange];
        }
    });
}

- (void)startMonitoring
{
    [self registerForPowerNotifications];
    
    /* Send initial notification */
    [self systemPowerInfoDidChange];
}


#pragma  mark -


- (void)performBeep
{
    printf("\007");
    fflush(stdout);
}


- (void)putSystemToSleep
{
    io_connect_t port = IOPMFindPowerManagement(MACH_PORT_NULL);
    IOPMSleepSystem(port);
    IOServiceClose(port);
}


- (void)askUserToSleepSystem
{
    [self performBeep];
    
    CFOptionFlags response;
    CFUserNotificationDisplayAlert(10 /* timeout in seconds */,
                                   kCFUserNotificationStopAlertLevel /*flags*/, 
                                   NULL /*icon*/,
                                   NULL /*sound*/,
                                   NULL /*localisation*/,
                                   CFSTR("Low battery") /*title*/,
                                   CFSTR("You should really sleep your laptop before something bad happens.") /*message*/,
                                   CFSTR("Sleep now") /*default button*/,
                                   CFSTR("Don't sleep") /* alternate button*/,
                                   NULL /* other */,
                                   &response /* response out */);
    
    /* response values: default => sleep now, alternate => don't sleep, cancel => timeout. */
    
    /* Explicit cancel by user */
    if (response == kCFUserNotificationAlternateResponse)
        return;
    
    NSLog(@"MnLowBatteryWarning: low battery. Sending system to sleep...");
    [self putSystemToSleep];
}

#pragma  mark -


/* see IOKit/ps/IOPSKeys.h for possible keys/values in the dictionary */
- (NSDictionary*)primaryBatteryInfo
{
    id powerInfoBlob = (__bridge_transfer id)IOPSCopyPowerSourcesInfo();
    NSArray* sources = (__bridge_transfer NSArray*)IOPSCopyPowerSourcesList((__bridge CFTypeRef)powerInfoBlob);
    
    NSUInteger idx = [sources indexOfObjectPassingTest:^BOOL(id sourceBlob, NSUInteger idx, BOOL *stop) {
                      NSDictionary* sourceInfo = (__bridge NSDictionary*)IOPSGetPowerSourceDescription((__bridge CFTypeRef)powerInfoBlob,
                                                                                                       (__bridge CFTypeRef)sourceBlob);
                      
                      NSString* batteryType = [sourceInfo objectForKey:@kIOPSTypeKey];
                      return (batteryType && [batteryType isEqualToString:@kIOPSInternalBatteryType]);
                      }];
    
    if (idx == NSNotFound)
        return nil;
    
    return (__bridge NSDictionary*)IOPSGetPowerSourceDescription((__bridge CFTypeRef)powerInfoBlob,
                                                                 (__bridge CFTypeRef)[sources objectAtIndex:idx]);
}

- (void)systemPowerInfoDidChange
{
    NSDictionary* info = [self primaryBatteryInfo];
    
    if (!info) {
        NSLog(@"Could not find primary battery -- perhaps there is none.");
        return;
    }
    
    NSNumber* capacity = [info objectForKey:@kIOPSCurrentCapacityKey];
    NSNumber* maxCapacity = [info objectForKey:@kIOPSMaxCapacityKey];
    
    if (!capacity || !maxCapacity) {
        NSLog(@"Can't calculate capacity.");
        return;
    }
    
    double capacityAsPercentage = 100.0 * [capacity doubleValue] / [maxCapacity doubleValue];
    
    /* Did out battery level decrease such that the critical threshold was crossed */
    BOOL didCrossThreshold = _lastSeenPercentageCapacity > self.criticalThreshold && capacityAsPercentage <= self.criticalThreshold;
    
    _lastSeenPercentageCapacity = capacityAsPercentage;
    
    if (didCrossThreshold) {
//        printf("*Notifying*: Capacity is %.1f%%; last seen was %.1f%%, threshold is %.1f%%.\n", capacityAsPercentage, _lastSeenPercentageCapacity, self.criticalThreshold);
        
        [self askUserToSleepSystem];
    } else {
//        printf("Not notifying: Capacity is %.1f%%; last seen was %.1f%%, threshold is %.1f%%.\n", capacityAsPercentage, _lastSeenPercentageCapacity, self.criticalThreshold);
    }
    
}

@end


int main (int argc, char * argv[])
{
    @autoreleasepool {
        CriticalBatteryMonitor* monitor = [CriticalBatteryMonitor new];

        char* error;
        int result = sandbox_init(kSBXProfileNoNetwork, SANDBOX_NAMED, &error);
        assert(result==0);
        
        NSLog(@"Starting monitoring of battery levels...\n");
        
        BOOL usingDebugMode = NO;
        
        struct option kArgFlags[] = {
            { "debug", no_argument, NULL, 'd'},
            { NULL, 0, NULL, 0 }
        };
        
        int ch;
        while ((ch=getopt_long(argc, argv, ""/*opt string*/, kArgFlags, NULL)) != -1) {
            switch (ch) {
                case 'd':
                    usingDebugMode = YES;
                    break;
            }
        }
        
        if (usingDebugMode) {
            NSLog(@"Debug mode");
            [monitor askUserToSleepSystem];
            return EXIT_SUCCESS;
        }
        
        [monitor startMonitoring];
        
        dispatch_main();

    }
  
    
    return 0;
}

