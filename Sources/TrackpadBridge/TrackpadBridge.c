#include "TrackpadBridge.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>

// MultitouchSupport's private contact ABI. Keep the layout in C, not Swift.
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier, state, fingerID, handID;
    MTVector normalized;
    float size;
    int32_t reserved1;
    float angle, majorAxis, minorAxis;
    MTVector absolute;
    int32_t reserved2, reserved3;
    float density;
} MTContact;
_Static_assert(sizeof(MTContact) == 96, "Unexpected multitouch contact layout");
_Static_assert(offsetof(MTContact, normalized) == 32, "Unexpected coordinate offset");
typedef void (*MTCallback)(void *, const MTContact *, int32_t, double, int32_t);
static void *library;
// The retained array owns device references for the whole subscription.
static CFArrayRef deviceList;
typedef struct { void *device; uint64_t identifier; bool builtIn; } Device;
static Device *devices;
static int32_t deviceCount;
static void (*registerFrame)(void *, MTCallback);
static void (*unregisterFrame)(void *, MTCallback);
static void (*startDevice)(void *, int32_t);
static void (*stopDevice)(void *);
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static MTEdgeFrameHandler client;
static void *clientContext;

static void frame(void *sender, const MTContact *contacts, int32_t count, double timestamp, int32_t sequence) {
    (void)sequence;
    MTEdgeTouch points[32];
    int32_t used = 0;
    if (count < 0 || count > 32 || (count && !contacts)) return;
    for (int32_t i = 0; i < count; ++i) {
        if (contacts[i].state == 3 || contacts[i].state == 4) {
            points[used++] = (MTEdgeTouch){contacts[i].identifier,
                contacts[i].normalized.position.x, contacts[i].normalized.position.y};
        }
    }
    pthread_mutex_lock(&mutex);
    if (client) {
        for (int32_t i = 0; i < deviceCount; ++i) {
            if (devices[i].device == sender) {
                client(devices[i].identifier, devices[i].builtIn, points, used, timestamp, clientContext);
                break;
            }
        }
    }
    pthread_mutex_unlock(&mutex);
}

// Start/stop are serialized by the Swift controller on the main thread.
int32_t MTEdgeStart(MTEdgeFrameHandler handler, void *context) {
    if (deviceList) return -3;
    if (!library) library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL);
    if (!library || !handler) return -1;
    CFArrayRef (*createList)(void) = dlsym(library, "MTDeviceCreateList");
    int (*sensorDimensions)(void *, int *, int *) = dlsym(library, "MTDeviceGetSensorDimensions");
    int (*getID)(void *, uint64_t *) = dlsym(library, "MTDeviceGetDeviceID");
    bool (*isBuiltIn)(void *) = dlsym(library, "MTDeviceIsBuiltIn");
    registerFrame = dlsym(library, "MTRegisterContactFrameCallback");
    unregisterFrame = dlsym(library, "MTUnregisterContactFrameCallback");
    startDevice = dlsym(library, "MTDeviceStart");
    stopDevice = dlsym(library, "MTDeviceStop");
    if (!createList || !sensorDimensions || !getID || !isBuiltIn || !registerFrame || !unregisterFrame || !startDevice || !stopDevice) return -1;
    CFArrayRef list = createList();
    if (!list) return -2;
    CFIndex count = CFArrayGetCount(list);
    Device *selected = calloc((size_t)count, sizeof(Device));
    if (!selected) { CFRelease(list); return -2; }
    int32_t used = 0;
    for (CFIndex i = 0; i < count; ++i) {
        void *device = (void *)CFArrayGetValueAtIndex(list, i);
        int rows = 0, columns = 0;
        uint64_t identifier = 0;
        // Exclude narrow multitouch surfaces such as Touch Bar (typically two rows).
        if (sensorDimensions(device, &rows, &columns) != 0 || rows < 10 || columns < 10) continue;
        if (getID(device, &identifier) != 0) continue;
        selected[used++] = (Device){device, identifier, isBuiltIn(device)};
    }
    if (!used) { free(selected); CFRelease(list); return -2; }
    pthread_mutex_lock(&mutex);
    deviceList = list;
    devices = selected;
    deviceCount = used;
    client = handler;
    clientContext = context;
    pthread_mutex_unlock(&mutex);
    for (int32_t i = 0; i < used; ++i) {
        registerFrame(selected[i].device, frame);
        startDevice(selected[i].device, 0);
    }
    return 0;
}

int32_t MTEdgeDeviceCount(int32_t builtIn) {
    pthread_mutex_lock(&mutex);
    int32_t count = 0;
    for (int32_t i = 0; i < deviceCount; ++i) {
        if (devices[i].builtIn == (builtIn != 0)) ++count;
    }
    pthread_mutex_unlock(&mutex);
    return count;
}

void MTEdgeStop(void) {
    if (!deviceList) return;
    pthread_mutex_lock(&mutex);
    client = NULL;
    clientContext = NULL;
    pthread_mutex_unlock(&mutex);
    for (int32_t i = 0; i < deviceCount; ++i) {
        unregisterFrame(devices[i].device, frame);
        stopDevice(devices[i].device);
    }
    pthread_mutex_lock(&mutex);
    free(devices);
    devices = NULL;
    deviceCount = 0;
    CFArrayRef list = deviceList;
    deviceList = NULL;
    pthread_mutex_unlock(&mutex);
    CFRelease(list);
}
