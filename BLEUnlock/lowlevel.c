#include "lowlevel.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>

// SACLockScreenImmediate 位于私有框架 login.framework。新版 macOS 已不再提供
// 其链接期桩（tbd），但运行时符号仍存在于 dyld shared cache，因此这里改为
// dlopen + dlsym 转发，链接期无需任何私有框架依赖。
int SACLockScreenImmediate(void)
{
    typedef int (*SACLockScreenImmediateFn)(void);
    static SACLockScreenImmediateFn fn = NULL;
    static void *handle = NULL;
    if (!fn) {
        if (!handle) {
            handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY);
            if (!handle) return -1;
        }
        fn = (SACLockScreenImmediateFn)dlsym(handle, "SACLockScreenImmediate");
        if (!fn) return -1;
    }
    return fn();
}

void wakeDisplay(void)
{
    static IOPMAssertionID assertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("BLEUnlock"), kIOPMUserActiveLocal, &assertionID);
}

void sleepDisplay(void)
{
    io_registry_entry_t reg = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        IORegistryEntrySetCFProperty(reg, CFSTR("IORequestIdle"), kCFBooleanTrue);
        IOObjectRelease(reg);
    }
}
