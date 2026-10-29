#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <dlfcn.h>
#include <stdint.h>

// Read-only IOSurface reachability probe: no IOConnectCallMethod or payloads.
typedef CFMutableDictionaryRef (*MatchingFn)(const char *);
typedef uint32_t (*GetServiceFn)(mach_port_t, CFDictionaryRef);
typedef kern_return_t (*OpenFn)(uint32_t, task_t, uint32_t, uint32_t *);
typedef kern_return_t (*CloseFn)(uint32_t);
typedef kern_return_t (*ReleaseFn)(uint32_t);
typedef kern_return_t (*GetClassFn)(uint32_t, char *);
typedef kern_return_t (*RegistryIDFn)(uint32_t, uint64_t *);
typedef kern_return_t (*ConnectGetServiceFn)(uint32_t, uint32_t *);
typedef CFTypeRef (*TaskFromSelfFn)(CFAllocatorRef);
typedef CFTypeRef (*TaskEntitlementFn)(CFTypeRef, CFStringRef, CFErrorRef *);

static void AppendOwnEntitlements(NSMutableString *out) {
    // Query only this application's *effective* code-signing entitlements.
    void *lib = dlopen("/System/Library/Frameworks/Security.framework/Security",
                      RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        [out appendString:@"Code-signing entitlement inspection: Security framework unavailable.\n\n"];
        return;
    }
    TaskFromSelfFn fromSelf = (TaskFromSelfFn)dlsym(lib, "SecTaskCreateFromSelf");
    TaskEntitlementFn getEnt = (TaskEntitlementFn)dlsym(lib, "SecTaskCopyValueForEntitlement");
    if (!fromSelf || !getEnt) {
        [out appendString:@"Code-signing entitlement inspection: API unavailable.\n\n"];
        dlclose(lib);
        return;
    }
    CFTypeRef task = fromSelf(kCFAllocatorDefault);
    if (!task) {
        [out appendString:@"Code-signing entitlement inspection: self task unavailable.\n\n"];
        dlclose(lib);
        return;
    }
    NSArray<NSString *> *names = @[
        @"com.apple.private.gpu-restricted",
        @"com.apple.developer.gpu-restricted",
        @"com.apple.private.iosurfaceinfo",
        @"com.apple.private.IOSurface.protected-access"
    ];
    [out appendString:@"Own effective code-signing entitlements:\n"];
    for (NSString *name in names) {
        CFErrorRef error = NULL;
        CFTypeRef value = getEnt(task, (__bridge CFStringRef)name, &error);
        NSString *description = @"absent / not accessible";
        if (value) {
            if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
                description = CFBooleanGetValue((CFBooleanRef)value) ? @"TRUE" : @"FALSE";
            } else {
                description = @"present (non-Boolean)";
            }
        }
        [out appendFormat:@"  %@: %@\n", name, description];
        if (value) CFRelease(value);
        if (error) CFRelease(error);
    }
    CFRelease(task);
    dlclose(lib);
    [out appendString:@"\n"];
}

static NSString *RunProbe(void) {
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"iOS: %@\nSigned-app IOSurface v1.3 read-only diagnostic\nNo external method calls.\n\n",
        NSProcessInfo.processInfo.operatingSystemVersionString];
    AppendOwnEntitlements(out);
    void *lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        [out appendFormat:@"IOKit unavailable: %s\n", dlerror() ?: "unknown"];
        return out;
    }
    MatchingFn matchClass = (MatchingFn)dlsym(lib, "IOServiceMatching");
    MatchingFn matchName = (MatchingFn)dlsym(lib, "IOServiceNameMatching");
    GetServiceFn getService = (GetServiceFn)dlsym(lib, "IOServiceGetMatchingService");
    OpenFn openService = (OpenFn)dlsym(lib, "IOServiceOpen");
    CloseFn closeService = (CloseFn)dlsym(lib, "IOServiceClose");
    ReleaseFn release = (ReleaseFn)dlsym(lib, "IOObjectRelease");
    GetClassFn getClass = (GetClassFn)dlsym(lib, "IOObjectGetClass");
    RegistryIDFn getRegistryID = (RegistryIDFn)dlsym(lib, "IORegistryEntryGetRegistryEntryID");
    ConnectGetServiceFn connectGetService = (ConnectGetServiceFn)dlsym(lib, "IOConnectGetService");
    if (!matchClass || !matchName || !getService || !openService || !closeService || !release) {
        [out appendString:@"Required IOKit symbol unavailable.\n"];
        dlclose(lib);
        return out;
    }
    const char *names[] = {"IOSurfaceRoot", "IOCoreSurfaceRoot", "IOSurfaceRoot", "IOCoreSurfaceRoot"};
    for (int n = 0; n < 4; n++) {
        BOOL byClass = n < 2;
        [out appendFormat:@"%d. %@ matching: %s\n", n + 1, byClass ? @"Class" : @"Name", names[n]];
        CFMutableDictionaryRef dictionary = (byClass ? matchClass : matchName)(names[n]);
        if (!dictionary) {
            [out appendString:@"   Matching dictionary unavailable.\n\n"];
            continue;
        }
        // IOServiceGetMatchingService consumes the dictionary.
        uint32_t service = getService(MACH_PORT_NULL, dictionary);
        if (service == MACH_PORT_NULL) {
            [out appendString:@"   Service not visible (may be absent or sandbox denied).\n\n"];
            continue;
        }
        if (getClass) {
            char className[128] = {0};
            kern_return_t classKR = getClass(service, className);
            [out appendFormat:@"   IOObjectGetClass: %@ (0x%08x)\n",
                classKR == KERN_SUCCESS ? [NSString stringWithUTF8String:className] : @"unavailable",
                (unsigned)classKR];
        }
        uint64_t originalEntryID = 0;
        BOOL originalEntryIDValid = NO;
        if (getRegistryID) {
            uint64_t entryID = 0;
            kern_return_t idKR = getRegistryID(service, &entryID);
            if (idKR == KERN_SUCCESS) {
                originalEntryID = entryID;
                originalEntryIDValid = YES;
            }
            [out appendFormat:@"   IORegistryEntryID: 0x%016llx (status 0x%08x)\n",
                (unsigned long long)entryID, (unsigned)idKR];
        }
        uint32_t connection = MACH_PORT_NULL;
        kern_return_t kr = openService(service, mach_task_self(), 0, &connection);
        [out appendFormat:@"   Service visible; IOServiceOpen: 0x%08x (%d)\n",
            (unsigned)kr, (int)kr];
        if (kr == KERN_SUCCESS && connection != MACH_PORT_NULL) {
            [out appendString:@"   OPEN ALLOWED for this app.\n"];
            if (getClass) {
                char clientClass[128] = {0};
                kern_return_t clientKR = getClass(connection, clientClass);
                [out appendFormat:@"   Connection class: %@ (0x%08x)\n",
                    clientKR == KERN_SUCCESS ? [NSString stringWithUTF8String:clientClass] : @"unavailable",
                    (unsigned)clientKR];
            }
            if (connectGetService) {
                uint32_t ownerService = MACH_PORT_NULL;
                kern_return_t serviceKR = connectGetService(connection, &ownerService);
                [out appendFormat:@"   IOConnectGetService: 0x%08x\n", (unsigned)serviceKR];
                if (serviceKR == KERN_SUCCESS && ownerService != MACH_PORT_NULL) {
                    if (getClass) {
                        char ownerClass[128] = {0};
                        kern_return_t classKR = getClass(ownerService, ownerClass);
                        [out appendFormat:@"   Connected service class: %@ (0x%08x)\n",
                            classKR == KERN_SUCCESS ? [NSString stringWithUTF8String:ownerClass] : @"unavailable",
                            (unsigned)classKR];
                    }
                    uint64_t ownerID = 0;
                    kern_return_t ownerKR = getRegistryID
                        ? getRegistryID(ownerService, &ownerID) : KERN_FAILURE;
                    [out appendFormat:@"   Connection owner Registry ID: 0x%016llx (0x%08x)\n",
                        (unsigned long long)ownerID, (unsigned)ownerKR];
                    if (ownerKR == KERN_SUCCESS && originalEntryIDValid) {
                        [out appendFormat:@"   Connection service matches: %@\n",
                            ownerID == originalEntryID ? @"YES" : @"NO"];
                    }
                    release(ownerService);
                }
            } else {
                [out appendString:@"   IOConnectGetService symbol unavailable.\n"];
            }
            kern_return_t closeKR = closeService(connection);
            [out appendFormat:@"   IOServiceClose: 0x%08x\n", (unsigned)closeKR];
        } else {
            [out appendString:@"   OPEN NOT CONFIRMED.\n"];
        }
        release(service);
        [out appendString:@"\n"];
    }
    [out appendString:@"A successful open does not prove specific external methods or exploitation are available.\n"];
    dlclose(lib);
    return out;
}

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UITextView *results;
@end
@implementation ProbeAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    (void)app; (void)opts;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *title = [UILabel new];
    title.text = @"IOSurface 访问检测";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *run = [UIButton buttonWithType:UIButtonTypeSystem];
    [run setTitle:@"检测服务" forState:UIControlStateNormal];
    [run addTarget:self action:@selector(runTap:) forControlEvents:UIControlEventTouchUpInside];
    run.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:@"复制结果" forState:UIControlStateNormal];
    [copy addTarget:self action:@selector(copyTap:) forControlEvents:UIControlEventTouchUpInside];
    copy.translatesAutoresizingMaskIntoConstraints = NO;
    self.results = [UITextView new];
    self.results.editable = NO;
    self.results.text = @"点击「检测服务」开始。\n只做常规服务连接检查，不触发漏洞。";
    self.results.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.results.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.results.layer.cornerRadius = 12;
    self.results.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:title];
    [vc.view addSubview:run];
    [vc.view addSubview:copy];
    [vc.view addSubview:self.results];
    UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:24],
        [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [run.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18],
        [run.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [run.heightAnchor constraintEqualToConstant:44],
        [copy.centerYAnchor constraintEqualToAnchor:run.centerYAnchor],
        [copy.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.results.topAnchor constraintEqualToAnchor:run.bottomAnchor constant:18],
        [self.results.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.results.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.results.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16]
    ]];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}
- (void)runTap:(UIButton *)button { button.enabled = NO; self.results.text = RunProbe(); button.enabled = YES; }
- (void)copyTap:(UIButton *)button { (void)button; UIPasteboard.generalPasteboard.string = self.results.text; }
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([ProbeAppDelegate class])); }
}
