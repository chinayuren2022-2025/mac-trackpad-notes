#ifndef CMULTITOUCH_SHIM_H
#define CMULTITOUCH_SHIM_H

// Struct layout for the private MultitouchSupport.framework contact callback.
// Everything is resolved via dlopen/dlsym at runtime; nothing here links
// against the framework. Layout is the canonical one used by open-source
// trackpad tools (fingertools, Middle, trackpad-weight demos).

typedef struct { float x, y; } MTShimPoint;
typedef struct { MTShimPoint pos, vel; } MTShimReadout;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;
    int fingerID;
    int handID;
    MTShimReadout normalized; // position/velocity in [0,1], origin bottom-left
    float size;               // capacitive contact size (a.u.) — "weight-ish"
    float pressure;           // force on Force Touch pads (a.u.); 0 elsewhere
    float angle;              // ellipse angle, radians
    float majorAxis;          // mm
    float minorAxis;          // mm
    MTShimReadout absolute;   // mm
    int zero2[2];
    float density;
} MTShimTouch;

typedef void *MTShimDeviceRef;
typedef int (*MTShimContactCallback)(int device, MTShimTouch *touches, int numTouches,
                                     double timestamp, int frame);

typedef MTShimDeviceRef (*MTShimCreateDefaultFn)(void);
typedef void (*MTShimRegisterContactFrameCallbackFn)(MTShimDeviceRef, MTShimContactCallback);
typedef void (*MTShimDeviceStartFn)(MTShimDeviceRef, int);
typedef void (*MTShimDeviceStopFn)(MTShimDeviceRef);
typedef void (*MTShimDeviceReleaseFn)(MTShimDeviceRef);

#endif
