// Declarations for private macOS APIs used by thermac.
//
// The HID and IOReport functions are exported by IOKit / libIOReport but have no
// public headers. They are declared under `tm_` names bound to the real symbols with
// asm labels, so they never clash with the public IOKit headers.
//
// Everything is typed as CoreFoundation objects so Swift manages their memory.

#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdbool.h>

CF_IMPLICIT_BRIDGING_ENABLED
CF_ASSUME_NONNULL_BEGIN

// MARK: - HID event system (thermal sensor hub)

enum {
    TM_HID_PAGE_APPLE_VENDOR = 0xff00,
    TM_HID_USAGE_TEMPERATURE = 0x0005,
    TM_HID_EVENT_TYPE_TEMPERATURE = 15,
};

CFTypeRef _Nullable tm_HIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator)
    CF_RETURNS_RETAINED __asm("_IOHIDEventSystemClientCreate");

int32_t tm_HIDEventSystemClientSetMatching(CFTypeRef client, CFDictionaryRef match)
    __asm("_IOHIDEventSystemClientSetMatching");

CFArrayRef _Nullable tm_HIDEventSystemClientCopyServices(CFTypeRef client)
    CF_RETURNS_RETAINED __asm("_IOHIDEventSystemClientCopyServices");

CFTypeRef _Nullable tm_HIDServiceClientCopyProperty(CFTypeRef service, CFStringRef key)
    CF_RETURNS_RETAINED __asm("_IOHIDServiceClientCopyProperty");

CFTypeRef _Nullable tm_HIDServiceClientCopyEvent(CFTypeRef service, int64_t type,
                                                 int32_t options, int64_t timestamp)
    CF_RETURNS_RETAINED __asm("_IOHIDServiceClientCopyEvent");

double tm_HIDEventGetFloatValue(CFTypeRef event, int32_t field)
    __asm("_IOHIDEventGetFloatValue");

// MARK: - IOReport (energy counters, no root required)

CFDictionaryRef _Nullable tm_IOReportCopyChannelsInGroup(CFStringRef _Nullable group,
                                                         CFStringRef _Nullable subgroup,
                                                         uint64_t a, uint64_t b, uint64_t c)
    CF_RETURNS_RETAINED __asm("_IOReportCopyChannelsInGroup");

CFTypeRef _Nullable tm_IOReportCreateSubscription(void * _Nullable unused,
                                                  CFMutableDictionaryRef desired,
                                                  CFMutableDictionaryRef _Nullable * _Nonnull subscribed,
                                                  uint64_t channelID,
                                                  CFTypeRef _Nullable unused2)
    CF_RETURNS_RETAINED __asm("_IOReportCreateSubscription");

CFDictionaryRef _Nullable tm_IOReportCreateSamples(CFTypeRef subscription,
                                                   CFMutableDictionaryRef subscribed,
                                                   CFTypeRef _Nullable unused)
    CF_RETURNS_RETAINED __asm("_IOReportCreateSamples");

CFDictionaryRef _Nullable tm_IOReportCreateSamplesDelta(CFDictionaryRef previous,
                                                        CFDictionaryRef current,
                                                        CFTypeRef _Nullable unused)
    CF_RETURNS_RETAINED __asm("_IOReportCreateSamplesDelta");

CFStringRef _Nullable tm_IOReportChannelGetGroup(CFDictionaryRef channel)
    __asm("_IOReportChannelGetGroup");
CFStringRef _Nullable tm_IOReportChannelGetSubGroup(CFDictionaryRef channel)
    __asm("_IOReportChannelGetSubGroup");
CFStringRef _Nullable tm_IOReportChannelGetChannelName(CFDictionaryRef channel)
    __asm("_IOReportChannelGetChannelName");
CFStringRef _Nullable tm_IOReportChannelGetUnitLabel(CFDictionaryRef channel)
    __asm("_IOReportChannelGetUnitLabel");
int64_t tm_IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t index)
    __asm("_IOReportSimpleGetIntegerValue");

CF_ASSUME_NONNULL_END
CF_IMPLICIT_BRIDGING_DISABLED

// MARK: - AppleSMC user client (implemented in smc.c)

typedef struct {
    uint32_t key;        // FourCC, big-endian packed ('T','B','0','T')
    uint32_t dataType;   // FourCC of the data type, e.g. 'flt '
    uint32_t dataSize;   // bytes valid in `bytes`
    uint8_t  bytes[32];
} tm_smc_value;

/// Opens a connection to AppleSMC. Returns 0 on success.
int tm_smc_open(uint32_t * _Nonnull connection);
void tm_smc_close(uint32_t connection);
/// Reads one key. Returns 0 on success.
int tm_smc_read(uint32_t connection, uint32_t key, tm_smc_value * _Nonnull out);
/// Reads one key when its size and type are already known (one kernel call instead of two).
int tm_smc_read_known(uint32_t connection, uint32_t key, uint32_t dataSize, uint32_t dataType,
                      tm_smc_value * _Nonnull out);
/// Returns the FourCC of the key at `index` (0 ..< "#KEY"). Returns 0 on success.
int tm_smc_key_at_index(uint32_t connection, uint32_t index, uint32_t * _Nonnull key);
