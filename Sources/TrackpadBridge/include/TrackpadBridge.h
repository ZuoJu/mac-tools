#pragma once
#include <stdint.h>

typedef struct { int32_t identifier; float x; float y; } MTEdgeTouch;
typedef void (*MTEdgeFrameHandler)(uint64_t deviceID, int32_t builtIn, const MTEdgeTouch *, int32_t, double, void *);
// Subscribe to all connected trackpads; device IDs keep their gestures isolated. The callback data is valid only during the call.
int32_t MTEdgeStart(MTEdgeFrameHandler handler, void *context);
void MTEdgeStop(void);
int32_t MTEdgeDeviceCount(int32_t builtIn);

// Show Apple's OSD without posting media keys or changing the system value again.
int32_t MTShowSystemOSD(int64_t image, uint32_t display, uint32_t percentage, uint32_t fadeMilliseconds);
