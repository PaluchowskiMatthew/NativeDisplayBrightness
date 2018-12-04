//
//  AppDelegate.m
//  NativeDisplayBrightness
//
//  Created by Benno Krauss on 19.10.16.
//  Copyright © 2016 Benno Krauss. All rights reserved.
//

#import "AppDelegate.h"
#import "BezelServices.h"
#import "OSD.h"
#include <dlfcn.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/sys_domain.h>
#include <sys/kern_event.h>
#include <sys/socket.h>
#include <sys/time.h>


static const int kCommandSetBrightness = 1;
static const char* kCtlName = "github.com.TankTheFrank.nvdagpuhandler";

@import Carbon;

#pragma mark - constants

static NSString *brightnessValuePreferenceKey = @"brightness";
static const int MIN_BRIGHTNESS = 50;
static const int MAX_BRIGHTNESS = 900;
static const float brightnessStep = 100/16.f;

#pragma mark - variables

void *(*_BSDoGraphicWithMeterAndTimeout)(CGDirectDisplayID arg0, BSGraphic arg1, int arg2, float v, int timeout) = NULL;

#pragma mark - functions

CGEventRef keyboardCGEventCallback(CGEventTapProxy proxy,
                                   CGEventType type,
                                   CGEventRef event,
                                   void *refcon)
{
    if (type != NX_SYSDEFINED)
        return event;
    
    NSEvent* keyEvent = [NSEvent eventWithCGEvent: event];
    if (keyEvent.type != NSEventTypeSystemDefined || keyEvent.subtype != 8)
        return event;
    
    int keyCode = (([keyEvent data1] & 0xFFFF0000) >> 16);
    int keyFlags = ([keyEvent data1] & 0x0000FFFF);
    int keyState = (((keyFlags & 0xFF00) >> 8)) == 0xA;
    
    // Ignore everything except brightness
    if (keyCode != NX_KEYTYPE_BRIGHTNESS_DOWN && keyCode != NX_KEYTYPE_BRIGHTNESS_UP)
        return event;
    
    // don't handle key up
    if (keyState == 0)
        return NULL;
    
    // we receive twice the same event so we need to check delay so we ignore everything less than 10 ms
    static struct timeval lastEvent = {0, 0};
    struct timeval now;
    gettimeofday(&now, NULL);
    if (now.tv_sec * 1000 + now.tv_usec/1000 - lastEvent.tv_sec * 1000 - lastEvent.tv_usec/1000 < 10)
        return NULL;
    
    lastEvent = now;
    
    // handle the brightness change
    switch (keyCode)
    {
        case NX_KEYTYPE_BRIGHTNESS_DOWN:
            dispatch_async(dispatch_get_main_queue(), ^{
                [(__bridge AppDelegate*)refcon decreaseBrightness];
            });
            break;
        case NX_KEYTYPE_BRIGHTNESS_UP:
            dispatch_async(dispatch_get_main_queue(), ^{
                [(__bridge AppDelegate*)refcon increaseBrightness];
            });
            break;
        default:
            break;
    }
    
    return NULL;
}


int connectKextSocket()
{
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    
    /* get the utun control id */
    struct ctl_info info;
    memset(&info, 0, sizeof(info));
    strncpy(info.ctl_name, kCtlName, strlen(kCtlName));
    if (ioctl(fd, CTLIOCGINFO, &info) < 0) {
        int err = errno;
        close(fd);
        fprintf(stderr, "getting kext device id [%s]", strerror(err));
        return -1;
    }
    
    /* (initialize addr here) */
    struct sockaddr_ctl addr;
    addr.sc_len = sizeof(struct sockaddr_ctl);
    addr.sc_family = AF_SYSTEM;
    addr.ss_sysaddr = SYSPROTO_CONTROL;
    addr.sc_id = info.ctl_id;     // set to value of ctl_id registered by the NKE in
    addr.sc_unit = 0; // set to the unit number registered by the NKE
    
    int result = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (result) {
        fprintf(stderr, "connect failed %d\n", result);
        close(fd);
        return -1;
    }
    
    return fd;
}

#pragma mark - AppDelegate

@interface AppDelegate ()

@property (weak) IBOutlet NSWindow *window;
@property (nonatomic) float brightness;
@property (strong, nonatomic) dispatch_source_t signalHandlerSource;
@end

@implementation AppDelegate
@synthesize brightness=_brightness;

- (BOOL)_loadBezelServices
{
    // Load BezelServices framework
    void *handle = dlopen("/System/Library/PrivateFrameworks/BezelServices.framework/Versions/A/BezelServices", RTLD_GLOBAL);
    if (!handle) {
        NSLog(@"Error opening framework");
        return NO;
    }
    else {
        _BSDoGraphicWithMeterAndTimeout = dlsym(handle, "BSDoGraphicWithMeterAndTimeout");
        return _BSDoGraphicWithMeterAndTimeout != NULL;
    }
}

- (BOOL)_loadOSDFramework
{
    return [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/OSD.framework"] load];
}

- (void)_configureLoginItem
{
    NSURL *bundleURL = [NSURL fileURLWithPath:[[NSBundle mainBundle] bundlePath]];
    LSSharedFileListRef loginItemsListRef = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    NSDictionary *properties = @{@"com.apple.loginitem.HideOnLaunch": @YES};
    LSSharedFileListInsertItemURL(loginItemsListRef, kLSSharedFileListItemLast, NULL, NULL, (__bridge CFURLRef)bundleURL, (__bridge CFDictionaryRef)properties,NULL);
}

- (void)_checkTrusted
{
    BOOL isTrusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @true});
    NSLog(@"istrusted: %i",isTrusted);
}

- (void)_registerGlobalKeyboardEvents
{
    CFRunLoopRef runloop = (CFRunLoopRef)CFRunLoopGetCurrent();
    CGEventMask interestedEvents = NX_SYSDEFINEDMASK;
    CFMachPortRef eventTap = CGEventTapCreate(kCGAnnotatedSessionEventTap, kCGHeadInsertEventTap,
                                              kCGEventTapOptionDefault, interestedEvents, keyboardCGEventCallback, (__bridge void * _Nullable)(self));
    // by passing self as last argument, you can later send events to this class instance
    
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
    CFRunLoopAddSource((CFRunLoopRef)runloop, source, kCFRunLoopCommonModes);
    CGEventTapEnable(eventTap, true);
}

- (void)_saveBrightness
{
    [[NSUserDefaults standardUserDefaults] setFloat:self.brightness forKey:brightnessValuePreferenceKey];
}

- (void)_loadBrightness
{
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
                                                              brightnessValuePreferenceKey: @(8*brightnessStep)
                                                              }];
    
    _brightness = [[NSUserDefaults standardUserDefaults] floatForKey:brightnessValuePreferenceKey];
    NSLog(@"Loaded value: %f",_brightness);
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    if (![self _loadBezelServices])
    {
        [self _loadOSDFramework];
    }
    [self _configureLoginItem];
    [self _checkTrusted];
    [self _registerGlobalKeyboardEvents];
    [self _loadBrightness];
    [self _registerSignalHandling];
}

void shutdownSignalHandler(int signal)
{
    //Don't do anything
}

- (void)_registerSignalHandling
{
    //Register signal callback that will gracefully shut the application down
    self.signalHandlerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.signalHandlerSource, ^{
        NSLog(@"Caught SIGTERM");
        [[NSApplication sharedApplication] terminate:self];
    });
    dispatch_resume(self.signalHandlerSource);
    //Register signal handler that will prevent the app from being killed
    signal(SIGTERM, shutdownSignalHandler);
}


- (void)applicationWillTerminate:(NSNotification *)aNotification
{
    [self _willTerminate];
}

- (void)_willTerminate
{
    NSLog(@"willTerminate");
    [self _saveBrightness];
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed: (NSApplication*) sender
{
    return NO;
}

- (void)setBrightness:(float)value
{
    _brightness = value;
    
    NSLog(@"set brightness: %f", value);
    
    // Sierra+ visual feedback
    [[NSClassFromString(@"OSDManager") sharedManager] showImage:OSDGraphicBacklight onDisplayID:CGSMainDisplayID() priority:OSDPriorityDefault msecUntilFade:1000 filledChiclets:value/brightnessStep totalChiclets:100.f/brightnessStep locked:NO];
    
    
    // set the brightness
    uint32_t normalizedBrightness = (MAX_BRIGHTNESS - MIN_BRIGHTNESS) * value / 100 + MIN_BRIGHTNESS;
    NSLog(@"brighness: %d", normalizedBrightness);
    
    static int fd = -1;
    if (fd < 0)
        fd = connectKextSocket();
    
    if (fd < 0)
    {
        NSLog(@"Cannot connect to the kext socket");
        return;
    }
    
    int result = setsockopt(fd, SYSPROTO_CONTROL, kCommandSetBrightness, &normalizedBrightness, sizeof(normalizedBrightness));
    if (result)
        NSLog(@"setsockopt failed: %d", result);
}

- (float)brightness
{
    return _brightness;
}

- (void)increaseBrightness
{
    self.brightness = MIN(self.brightness+brightnessStep,100);
}

- (void)decreaseBrightness
{
    self.brightness = MAX(self.brightness-brightnessStep,0);
}


@end
