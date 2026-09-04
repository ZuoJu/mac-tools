#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import "TrackpadBridge.h"

// Runtime-checked SPI from macOS OSD.framework. The system owns and renders the UI.
@protocol MacToolsSystemOSD
+ (id)sharedManager;
- (void)showImage:(int64_t)image onDisplayID:(uint32_t)display
         priority:(uint32_t)priority msecUntilFade:(uint32_t)milliseconds
   filledChiclets:(uint32_t)filled totalChiclets:(uint32_t)total locked:(BOOL)locked;
@end

int32_t MTShowSystemOSD(int64_t image, uint32_t display, uint32_t percentage, uint32_t fadeMilliseconds) {
    if (![NSThread isMainThread] || (image != 1 && image != 3 && image != 4)) return 0;
    static void *framework;
    if (!framework) framework = dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_NOW | RTLD_LOCAL);
    if (!framework) return 0;
    Class cls = NSClassFromString(@"OSDManager");
    if (![cls respondsToSelector:@selector(sharedManager)]) return 0;
    @try {
        id<MacToolsSystemOSD> manager = [(id<MacToolsSystemOSD>)cls sharedManager];
        SEL selector = @selector(showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:);
        if (![(NSObject *)manager respondsToSelector:selector]) return 0;
        [manager showImage:image onDisplayID:display priority:500 msecUntilFade:fadeMilliseconds
            filledChiclets:MIN(percentage, 100) totalChiclets:100 locked:NO];
        return 1;
    } @catch (NSException *exception) {
        return 0;
    }
}
