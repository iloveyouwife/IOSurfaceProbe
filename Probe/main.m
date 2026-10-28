#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <dlfcn.h>
#include <stdint.h>

// Non-exploit IOSurface reachability probe: no IOConnectCallMethod or payloads.
typedef CFMutableDictionaryRef (*MatchingFn)(const char *);
typedef uint32_t (*GetServiceFn)(mach_port_t, CFDictionaryRef);
typedef kern_return_t (*OpenFn)(uint32_t, task_t, uint32_t, uint32_t *);
typedef kern_return_t (*CloseFn)(uint32_t);
typedef kern_return_t (*ReleaseFn)(uint32_t);
typedef kern_return_t (*GetClassFn)(uint32_t, char *);
typedef kern_return_t (*RegistryIDFn)(uint32_t, uint64_t *);
typedef kern_return_t (*ConnectServiceFn)(uint32_t, uint32_t *);

static NSString *RunProbe(void) {
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"iOS: %@\nSigned-app IOSurface service-open diagnostic\nNo external method calls.\n\n",
        NSProcessInfo.processInfo.operatingSystemVersionString];
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
    ConnectServiceFn getConnectService = (ConnectServiceFn)dlsym(lib, "IOConnectGetService");
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
            if (idKR == KERN_SUCCESS) { originalEntryID = entryID; originalEntryIDValid = YES; }
            [out appendFormat:@"   IORegistryEntryID: 0x%016llx (status 0x%08x)\n",
                (unsigned long long)entryID, (unsigned)idKR];
        }
        uint32_t connection = MACH_PORT_NULL;
        kern_return_t kr = openService(service, mach_task_self(), 0, &connection);
        [out appendFormat:@"   Service visible; IOServiceOpen: 0x%08x (%d)\n",
            (unsigned)kr, (int)kr];
        if (kr == KERN_SUCCESS && connection != MACH_PORT_NULL) {
            [out appendString:@"   OPEN ALLOWED for this app.\n"];
            // Read-only connection identity: never dispatch an external method.
            if (getClass) {
                char connectionClass[128] = {0};
                kern_return_t classKR = getClass(connection, connectionClass);
                [out appendFormat:@"   Connection class: %@ (0x%08x)\n",
                    classKR == KERN_SUCCESS ? [NSString stringWithUTF8String:connectionClass] : @"unavailable",
                    (unsigned)classKR];
            }
            if (getConnectService) {
                uint32_t connectedService = MACH_PORT_NULL;
                kern_return_t connectionKR = getConnectService(connection, &connectedService);
                [out appendFormat:@"   IOConnectGetService: 0x%08x\n", (unsigned)connectionKR];
                if (connectionKR == KERN_SUCCESS && connectedService != MACH_PORT_NULL) {
                    if (getClass) {
                        char associatedClass[128] = {0};
                        kern_return_t classKR = getClass(connectedService, associatedClass);
                        [out appendFormat:@"   Connected service class: %@ (0x%08x)\n",
                            classKR == KERN_SUCCESS ? [NSString stringWithUTF8String:associatedClass] : @"unavailable",
                            (unsigned)classKR];
                    }
                    if (getRegistryID) {
                        uint64_t associatedID = 0;
                        kern_return_t idKR = getRegistryID(connectedService, &associatedID);
                        [out appendFormat:@"   Connected service ID: 0x%016llx (0x%08x)\n",
                            (unsigned long long)associatedID, (unsigned)idKR];
                        if (idKR == KERN_SUCCESS && originalEntryIDValid) {
                            [out appendFormat:@"   Connection service matches: %@\n",
                                associatedID == originalEntryID ? @"YES" : @"NO"];
                        }
                    }
                    release(connectedService);
                }
            } else {
                [out appendString:@"   IOConnectGetService unavailable on this OS.\n"];
            }
            kern_return_t closeKR = closeService(connection);
            [out appendFormat:@"   IOServiceClose: 0x%08x\n", (unsigned)closeKR];
        } else {
            [out appendString:@"   OPEN NOT CONFIRMED.\n"];
        }
        release(service);
        [out appendString:@"\n"];
    }
    [out appendString:@"Connection identity does not prove external-method dispatch or exploitation.\n"];
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
