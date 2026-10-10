// ssw_usbtrace.c -- passive IOKit USB call tracer for the H-Mod StealthSwitch3 app.
//
// Build:  clang -arch x86_64 -dynamiclib -O1 -g -o ssw_usbtrace.dylib \
//             ssw_usbtrace.c ssw_tramp.s -framework IOKit -framework CoreFoundation
// Use:    SSW_LOG=/path/to/log DYLD_INSERT_LIBRARIES=/path/ssw_usbtrace.dylib <x86_64 app>
//
// What it does
//   * Interposes IOCreatePlugInInterfaceForService (and a few IOService/IOConnect
//     calls, log-only).
//   * For every IOCFPlugInInterface it returns, the *instance's* vtable pointer is
//     replaced by a private heap copy whose QueryInterface is wrapped.  The
//     system's shared static vtable is never written.
//   * When QueryInterface hands out an IOUSBDeviceInterface* / IOUSBInterfaceInterface*
//     (any version), that instance's vtable pointer is likewise swapped to a heap
//     copy sized for the queried version.  Important methods get fully-decoding
//     C wrappers (args, OUT data before the call, IN data + return code after).
//     Every other slot gets an asm trampoline that logs the slot name + raw
//     register args and tail-jumps to the original (return value not logged).
//   * The tracer never issues any USB traffic of its own.
//
// Env:
//   SSW_LOG            log file path (appended). Default: stderr.
//   SSW_TRACE_IOCONNECT  "0" disables the IOConnectCall* log lines (default on).

#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <sys/time.h>
#include <sys/sysctl.h>
#include <unistd.h>

// ---------------------------------------------------------------- logging
static FILE *g_log;
static pthread_mutex_t g_lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
static uint64_t g_t0;
static mach_timebase_info_data_t g_tb;
static unsigned long g_seq;
static int g_trace_ioconnect = 1;

static void logv(const char *fmt, va_list ap) {
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tm; localtime_r(&tv.tv_sec, &tm);
    double rel = (double)(mach_absolute_time() - g_t0) * g_tb.numer / g_tb.denom / 1e9;
    uint64_t tid = 0; pthread_threadid_np(NULL, &tid);
    FILE *f = g_log ? g_log : stderr;
    fprintf(f, "%04d-%02d-%02dT%02d:%02d:%02d.%06d +%10.6f [t%llu] ",
            tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min,
            tm.tm_sec, (int)tv.tv_usec, rel, (unsigned long long)tid);
    vfprintf(f, fmt, ap);
    fputc('\n', f);
    fflush(f);
}
static void LOG(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    pthread_mutex_lock(&g_lock); logv(fmt, ap); pthread_mutex_unlock(&g_lock);
    va_end(ap);
}
static void hexdump(const char *tag, const void *p, size_t n) {
    if (!p) { LOG("    %s: <NULL buffer>", tag); return; }
    const uint8_t *b = p;
    pthread_mutex_lock(&g_lock);
    for (size_t off = 0; off < n || (n == 0 && off == 0); off += 16) {
        char line[128]; int k = 0;
        for (size_t i = off; i < off + 16 && i < n; i++) k += snprintf(line + k, sizeof line - k, "%02x ", b[i]);
        line[k] = 0;
        LOG("    %s[%04zx]: %s", tag, off, n ? line : "(0 bytes)");
        if (n == 0) break;
    }
    pthread_mutex_unlock(&g_lock);
}
static const char *ioret(IOReturn r) {
    switch (r) {
    case kIOReturnSuccess: return "kIOReturnSuccess";
    case kIOReturnError: return "kIOReturnError";
    case kIOReturnNoDevice: return "kIOReturnNoDevice";
    case kIOReturnNotOpen: return "kIOReturnNotOpen";
    case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess";
    case kIOReturnNotPrivileged: return "kIOReturnNotPrivileged";
    case kIOReturnTimeout: return "kIOReturnTimeout";
    case kIOReturnAborted: return "kIOReturnAborted";
    case kIOReturnBadArgument: return "kIOReturnBadArgument";
    case kIOReturnUnsupported: return "kIOReturnUnsupported";
    case kIOReturnNotResponding: return "kIOReturnNotResponding";
    case kIOReturnOverrun: return "kIOReturnOverrun";
    case kIOReturnUnderrun: return "kIOReturnUnderrun";
    case kIOUSBPipeStalled: return "kIOUSBPipeStalled";
    case kIOUSBTransactionTimeout: return "kIOUSBTransactionTimeout";
    default: return "?";
    }
}
static const char *bmrt_desc(uint8_t t, char *buf, size_t n) {
    static const char *ty[] = {"standard", "class", "vendor", "reserved"};
    static const char *rc[] = {"device", "interface", "endpoint", "other"};
    snprintf(buf, n, "%s %s %s", (t & 0x80) ? "IN" : "OUT", ty[(t >> 5) & 3],
             (t & 0x1f) < 4 ? rc[t & 0x1f] : "recip?");
    return buf;
}

// ---------------------------------------------------------------- registry
enum Kind { K_PLUGIN = 1, K_DEVICE, K_INTERFACE };
typedef struct {
    void *self;          // the COM object pointer handed to the app (void** -> vtbl)
    int kind;
    int nslots;
    void **orig;         // original vtable (shared, never written)
    void **copy;         // our private copy, installed into *self
    int version;
} Entry;
#define MAXE 256
static Entry g_ent[MAXE];
static int g_nent;

static Entry *find(void *self) {
    pthread_mutex_lock(&g_lock);
    Entry *e = NULL;
    for (int i = g_nent - 1; i >= 0; i--)
        if (g_ent[i].self == self && g_ent[i].copy == *(void ***)self) { e = &g_ent[i]; break; }
    pthread_mutex_unlock(&g_lock);
    return e;
}
#define ORIG(e, T, field) ((__typeof__(((T *)0)->field))(e)->orig[offsetof(T, field) / sizeof(void *)])

static const char *DEV_NAMES[128] = {[0] = "_reserved", [offsetof(IOUSBDeviceInterface942, QueryInterface) / sizeof(void *)] = "QueryInterface", [offsetof(IOUSBDeviceInterface942, AddRef) / sizeof(void *)] = "AddRef", [offsetof(IOUSBDeviceInterface942, Release) / sizeof(void *)] = "Release", [offsetof(IOUSBDeviceInterface942, CreateDeviceAsyncEventSource) / sizeof(void *)] = "CreateDeviceAsyncEventSource", [offsetof(IOUSBDeviceInterface942, GetDeviceAsyncEventSource) / sizeof(void *)] = "GetDeviceAsyncEventSource", [offsetof(IOUSBDeviceInterface942, CreateDeviceAsyncPort) / sizeof(void *)] = "CreateDeviceAsyncPort", [offsetof(IOUSBDeviceInterface942, GetDeviceAsyncPort) / sizeof(void *)] = "GetDeviceAsyncPort", [offsetof(IOUSBDeviceInterface942, USBDeviceOpen) / sizeof(void *)] = "USBDeviceOpen", [offsetof(IOUSBDeviceInterface942, USBDeviceClose) / sizeof(void *)] = "USBDeviceClose", [offsetof(IOUSBDeviceInterface942, GetDeviceClass) / sizeof(void *)] = "GetDeviceClass", [offsetof(IOUSBDeviceInterface942, GetDeviceSubClass) / sizeof(void *)] = "GetDeviceSubClass", [offsetof(IOUSBDeviceInterface942, GetDeviceProtocol) / sizeof(void *)] = "GetDeviceProtocol", [offsetof(IOUSBDeviceInterface942, GetDeviceVendor) / sizeof(void *)] = "GetDeviceVendor", [offsetof(IOUSBDeviceInterface942, GetDeviceProduct) / sizeof(void *)] = "GetDeviceProduct", [offsetof(IOUSBDeviceInterface942, GetDeviceReleaseNumber) / sizeof(void *)] = "GetDeviceReleaseNumber", [offsetof(IOUSBDeviceInterface942, GetDeviceAddress) / sizeof(void *)] = "GetDeviceAddress", [offsetof(IOUSBDeviceInterface942, GetDeviceBusPowerAvailable) / sizeof(void *)] = "GetDeviceBusPowerAvailable", [offsetof(IOUSBDeviceInterface942, GetDeviceSpeed) / sizeof(void *)] = "GetDeviceSpeed", [offsetof(IOUSBDeviceInterface942, GetNumberOfConfigurations) / sizeof(void *)] = "GetNumberOfConfigurations", [offsetof(IOUSBDeviceInterface942, GetLocationID) / sizeof(void *)] = "GetLocationID", [offsetof(IOUSBDeviceInterface942, GetConfigurationDescriptorPtr) / sizeof(void *)] = "GetConfigurationDescriptorPtr", [offsetof(IOUSBDeviceInterface942, GetConfiguration) / sizeof(void *)] = "GetConfiguration", [offsetof(IOUSBDeviceInterface942, SetConfiguration) / sizeof(void *)] = "SetConfiguration", [offsetof(IOUSBDeviceInterface942, GetBusFrameNumber) / sizeof(void *)] = "GetBusFrameNumber", [offsetof(IOUSBDeviceInterface942, ResetDevice) / sizeof(void *)] = "ResetDevice", [offsetof(IOUSBDeviceInterface942, DeviceRequest) / sizeof(void *)] = "DeviceRequest", [offsetof(IOUSBDeviceInterface942, DeviceRequestAsync) / sizeof(void *)] = "DeviceRequestAsync", [offsetof(IOUSBDeviceInterface942, CreateInterfaceIterator) / sizeof(void *)] = "CreateInterfaceIterator", [offsetof(IOUSBDeviceInterface942, USBDeviceOpenSeize) / sizeof(void *)] = "USBDeviceOpenSeize", [offsetof(IOUSBDeviceInterface942, DeviceRequestTO) / sizeof(void *)] = "DeviceRequestTO", [offsetof(IOUSBDeviceInterface942, DeviceRequestAsyncTO) / sizeof(void *)] = "DeviceRequestAsyncTO", [offsetof(IOUSBDeviceInterface942, USBDeviceSuspend) / sizeof(void *)] = "USBDeviceSuspend", [offsetof(IOUSBDeviceInterface942, USBDeviceAbortPipeZero) / sizeof(void *)] = "USBDeviceAbortPipeZero", [offsetof(IOUSBDeviceInterface942, USBGetManufacturerStringIndex) / sizeof(void *)] = "USBGetManufacturerStringIndex", [offsetof(IOUSBDeviceInterface942, USBGetProductStringIndex) / sizeof(void *)] = "USBGetProductStringIndex", [offsetof(IOUSBDeviceInterface942, USBGetSerialNumberStringIndex) / sizeof(void *)] = "USBGetSerialNumberStringIndex", [offsetof(IOUSBDeviceInterface942, USBDeviceReEnumerate) / sizeof(void *)] = "USBDeviceReEnumerate", [offsetof(IOUSBDeviceInterface942, GetBusMicroFrameNumber) / sizeof(void *)] = "GetBusMicroFrameNumber", [offsetof(IOUSBDeviceInterface942, GetIOUSBLibVersion) / sizeof(void *)] = "GetIOUSBLibVersion", [offsetof(IOUSBDeviceInterface942, GetBusFrameNumberWithTime) / sizeof(void *)] = "GetBusFrameNumberWithTime", [offsetof(IOUSBDeviceInterface942, GetUSBDeviceInformation) / sizeof(void *)] = "GetUSBDeviceInformation", [offsetof(IOUSBDeviceInterface942, RequestExtraPower) / sizeof(void *)] = "RequestExtraPower", [offsetof(IOUSBDeviceInterface942, ReturnExtraPower) / sizeof(void *)] = "ReturnExtraPower", [offsetof(IOUSBDeviceInterface942, GetExtraPowerAllocated) / sizeof(void *)] = "GetExtraPowerAllocated", [offsetof(IOUSBDeviceInterface942, GetDeviceAsyncNotificationPort) / sizeof(void *)] = "GetDeviceAsyncNotificationPort", [offsetof(IOUSBDeviceInterface942, GetBandwidthAvailableForDevice) / sizeof(void *)] = "GetBandwidthAvailableForDevice", [offsetof(IOUSBDeviceInterface942, SetConfigurationV2) / sizeof(void *)] = "SetConfigurationV2", [offsetof(IOUSBDeviceInterface942, RegisterForNotification) / sizeof(void *)] = "RegisterForNotification", [offsetof(IOUSBDeviceInterface942, UnregisterNotification) / sizeof(void *)] = "UnregisterNotification", [offsetof(IOUSBDeviceInterface942, AcknowledgeNotification) / sizeof(void *)] = "AcknowledgeNotification"};
static const char *IF_NAMES[128] = {[0] = "_reserved", [offsetof(IOUSBInterfaceInterface942, QueryInterface) / sizeof(void *)] = "QueryInterface", [offsetof(IOUSBInterfaceInterface942, AddRef) / sizeof(void *)] = "AddRef", [offsetof(IOUSBInterfaceInterface942, Release) / sizeof(void *)] = "Release", [offsetof(IOUSBInterfaceInterface942, CreateInterfaceAsyncEventSource) / sizeof(void *)] = "CreateInterfaceAsyncEventSource", [offsetof(IOUSBInterfaceInterface942, GetInterfaceAsyncEventSource) / sizeof(void *)] = "GetInterfaceAsyncEventSource", [offsetof(IOUSBInterfaceInterface942, CreateInterfaceAsyncPort) / sizeof(void *)] = "CreateInterfaceAsyncPort", [offsetof(IOUSBInterfaceInterface942, GetInterfaceAsyncPort) / sizeof(void *)] = "GetInterfaceAsyncPort", [offsetof(IOUSBInterfaceInterface942, USBInterfaceOpen) / sizeof(void *)] = "USBInterfaceOpen", [offsetof(IOUSBInterfaceInterface942, USBInterfaceClose) / sizeof(void *)] = "USBInterfaceClose", [offsetof(IOUSBInterfaceInterface942, GetInterfaceClass) / sizeof(void *)] = "GetInterfaceClass", [offsetof(IOUSBInterfaceInterface942, GetInterfaceSubClass) / sizeof(void *)] = "GetInterfaceSubClass", [offsetof(IOUSBInterfaceInterface942, GetInterfaceProtocol) / sizeof(void *)] = "GetInterfaceProtocol", [offsetof(IOUSBInterfaceInterface942, GetDeviceVendor) / sizeof(void *)] = "GetDeviceVendor", [offsetof(IOUSBInterfaceInterface942, GetDeviceProduct) / sizeof(void *)] = "GetDeviceProduct", [offsetof(IOUSBInterfaceInterface942, GetDeviceReleaseNumber) / sizeof(void *)] = "GetDeviceReleaseNumber", [offsetof(IOUSBInterfaceInterface942, GetConfigurationValue) / sizeof(void *)] = "GetConfigurationValue", [offsetof(IOUSBInterfaceInterface942, GetInterfaceNumber) / sizeof(void *)] = "GetInterfaceNumber", [offsetof(IOUSBInterfaceInterface942, GetAlternateSetting) / sizeof(void *)] = "GetAlternateSetting", [offsetof(IOUSBInterfaceInterface942, GetNumEndpoints) / sizeof(void *)] = "GetNumEndpoints", [offsetof(IOUSBInterfaceInterface942, GetLocationID) / sizeof(void *)] = "GetLocationID", [offsetof(IOUSBInterfaceInterface942, GetDevice) / sizeof(void *)] = "GetDevice", [offsetof(IOUSBInterfaceInterface942, SetAlternateInterface) / sizeof(void *)] = "SetAlternateInterface", [offsetof(IOUSBInterfaceInterface942, GetBusFrameNumber) / sizeof(void *)] = "GetBusFrameNumber", [offsetof(IOUSBInterfaceInterface942, ControlRequest) / sizeof(void *)] = "ControlRequest", [offsetof(IOUSBInterfaceInterface942, ControlRequestAsync) / sizeof(void *)] = "ControlRequestAsync", [offsetof(IOUSBInterfaceInterface942, GetPipeProperties) / sizeof(void *)] = "GetPipeProperties", [offsetof(IOUSBInterfaceInterface942, GetPipeStatus) / sizeof(void *)] = "GetPipeStatus", [offsetof(IOUSBInterfaceInterface942, AbortPipe) / sizeof(void *)] = "AbortPipe", [offsetof(IOUSBInterfaceInterface942, ResetPipe) / sizeof(void *)] = "ResetPipe", [offsetof(IOUSBInterfaceInterface942, ClearPipeStall) / sizeof(void *)] = "ClearPipeStall", [offsetof(IOUSBInterfaceInterface942, ReadPipe) / sizeof(void *)] = "ReadPipe", [offsetof(IOUSBInterfaceInterface942, WritePipe) / sizeof(void *)] = "WritePipe", [offsetof(IOUSBInterfaceInterface942, ReadPipeAsync) / sizeof(void *)] = "ReadPipeAsync", [offsetof(IOUSBInterfaceInterface942, WritePipeAsync) / sizeof(void *)] = "WritePipeAsync", [offsetof(IOUSBInterfaceInterface942, ReadIsochPipeAsync) / sizeof(void *)] = "ReadIsochPipeAsync", [offsetof(IOUSBInterfaceInterface942, WriteIsochPipeAsync) / sizeof(void *)] = "WriteIsochPipeAsync", [offsetof(IOUSBInterfaceInterface942, ControlRequestTO) / sizeof(void *)] = "ControlRequestTO", [offsetof(IOUSBInterfaceInterface942, ControlRequestAsyncTO) / sizeof(void *)] = "ControlRequestAsyncTO", [offsetof(IOUSBInterfaceInterface942, ReadPipeTO) / sizeof(void *)] = "ReadPipeTO", [offsetof(IOUSBInterfaceInterface942, WritePipeTO) / sizeof(void *)] = "WritePipeTO", [offsetof(IOUSBInterfaceInterface942, ReadPipeAsyncTO) / sizeof(void *)] = "ReadPipeAsyncTO", [offsetof(IOUSBInterfaceInterface942, WritePipeAsyncTO) / sizeof(void *)] = "WritePipeAsyncTO", [offsetof(IOUSBInterfaceInterface942, USBInterfaceGetStringIndex) / sizeof(void *)] = "USBInterfaceGetStringIndex", [offsetof(IOUSBInterfaceInterface942, USBInterfaceOpenSeize) / sizeof(void *)] = "USBInterfaceOpenSeize", [offsetof(IOUSBInterfaceInterface942, ClearPipeStallBothEnds) / sizeof(void *)] = "ClearPipeStallBothEnds", [offsetof(IOUSBInterfaceInterface942, SetPipePolicy) / sizeof(void *)] = "SetPipePolicy", [offsetof(IOUSBInterfaceInterface942, GetBandwidthAvailable) / sizeof(void *)] = "GetBandwidthAvailable", [offsetof(IOUSBInterfaceInterface942, GetEndpointProperties) / sizeof(void *)] = "GetEndpointProperties", [offsetof(IOUSBInterfaceInterface942, LowLatencyReadIsochPipeAsync) / sizeof(void *)] = "LowLatencyReadIsochPipeAsync", [offsetof(IOUSBInterfaceInterface942, LowLatencyWriteIsochPipeAsync) / sizeof(void *)] = "LowLatencyWriteIsochPipeAsync", [offsetof(IOUSBInterfaceInterface942, LowLatencyCreateBuffer) / sizeof(void *)] = "LowLatencyCreateBuffer", [offsetof(IOUSBInterfaceInterface942, LowLatencyDestroyBuffer) / sizeof(void *)] = "LowLatencyDestroyBuffer", [offsetof(IOUSBInterfaceInterface942, GetBusMicroFrameNumber) / sizeof(void *)] = "GetBusMicroFrameNumber", [offsetof(IOUSBInterfaceInterface942, GetFrameListTime) / sizeof(void *)] = "GetFrameListTime", [offsetof(IOUSBInterfaceInterface942, GetIOUSBLibVersion) / sizeof(void *)] = "GetIOUSBLibVersion", [offsetof(IOUSBInterfaceInterface942, FindNextAssociatedDescriptor) / sizeof(void *)] = "FindNextAssociatedDescriptor", [offsetof(IOUSBInterfaceInterface942, FindNextAltInterface) / sizeof(void *)] = "FindNextAltInterface", [offsetof(IOUSBInterfaceInterface942, GetBusFrameNumberWithTime) / sizeof(void *)] = "GetBusFrameNumberWithTime", [offsetof(IOUSBInterfaceInterface942, GetInterfaceAsyncNotificationPort) / sizeof(void *)] = "GetInterfaceAsyncNotificationPort", [offsetof(IOUSBInterfaceInterface942, GetPipePropertiesV2) / sizeof(void *)] = "GetPipePropertiesV2", [offsetof(IOUSBInterfaceInterface942, GetPipePropertiesV3) / sizeof(void *)] = "GetPipePropertiesV3", [offsetof(IOUSBInterfaceInterface942, GetEndpointPropertiesV3) / sizeof(void *)] = "GetEndpointPropertiesV3", [offsetof(IOUSBInterfaceInterface942, SupportsStreams) / sizeof(void *)] = "SupportsStreams", [offsetof(IOUSBInterfaceInterface942, CreateStreams) / sizeof(void *)] = "CreateStreams", [offsetof(IOUSBInterfaceInterface942, GetConfiguredStreams) / sizeof(void *)] = "GetConfiguredStreams", [offsetof(IOUSBInterfaceInterface942, ReadStreamsPipeTO) / sizeof(void *)] = "ReadStreamsPipeTO", [offsetof(IOUSBInterfaceInterface942, WriteStreamsPipeTO) / sizeof(void *)] = "WriteStreamsPipeTO", [offsetof(IOUSBInterfaceInterface942, ReadStreamsPipeAsyncTO) / sizeof(void *)] = "ReadStreamsPipeAsyncTO", [offsetof(IOUSBInterfaceInterface942, WriteStreamsPipeAsyncTO) / sizeof(void *)] = "WriteStreamsPipeAsyncTO", [offsetof(IOUSBInterfaceInterface942, AbortStreamsPipe) / sizeof(void *)] = "AbortStreamsPipe", [offsetof(IOUSBInterfaceInterface942, RegisterForNotification) / sizeof(void *)] = "RegisterForNotification", [offsetof(IOUSBInterfaceInterface942, UnregisterNotification) / sizeof(void *)] = "UnregisterNotification", [offsetof(IOUSBInterfaceInterface942, AcknowledgeNotification) / sizeof(void *)] = "AcknowledgeNotification", [offsetof(IOUSBInterfaceInterface942, RegisterDriver) / sizeof(void *)] = "RegisterDriver", [offsetof(IOUSBInterfaceInterface942, SetDeviceIdlePolicy) / sizeof(void *)] = "SetDeviceIdlePolicy", [offsetof(IOUSBInterfaceInterface942, SetPipeIdlePolicy) / sizeof(void *)] = "SetPipeIdlePolicy"};
static const char *slotname(int kind, int slot) {
    if (slot < 0 || slot >= 128) return "slot?";
    if (kind == K_DEVICE && DEV_NAMES[slot]) return DEV_NAMES[slot];
    if (kind == K_INTERFACE && IF_NAMES[slot]) return IF_NAMES[slot];
    return "slot?";
}

// asm trampolines (ssw_tramp.s): ssw_tramp_table[i] loads i into r11 and jumps to common code,
// which calls ssw_generic_enter(self, i, regs) and tail-jumps to the returned pointer.
#define NTRAMP 128
extern void *ssw_tramp_table[NTRAMP];

void *ssw_generic_enter(void *self, long slot, uint64_t *regs) {
    // regs layout as pushed: [0]=r9 [1]=r8 [2]=rcx [3]=rdx [4]=rsi [5]=rdi
    Entry *e = find(self);
    if (!e) {
        // Should not happen; we cannot recover the original. Abort loudly.
        LOG("FATAL: generic trampoline slot %ld for unknown self %p", slot, self);
        abort();
    }
    unsigned long seq = __sync_add_and_fetch(&g_seq, 1);
    LOG("#%lu %s %s(slot %ld) self=%p args: rsi=0x%llx rdx=0x%llx rcx=0x%llx r8=0x%llx r9=0x%llx  [passthrough, return not logged]",
        seq, e->kind == K_DEVICE ? "DEV" : "IF", slotname(e->kind, (int)slot), slot, self,
        regs[4], regs[3], regs[2], regs[1], regs[0]);
    return e->orig[slot];
}

static Entry *install(void *self, int kind, int nslots, int version) {
    void **orig = *(void ***)self;
    Entry *ex = find(self);
    if (ex) return ex;  // already wrapped
    void **copy = calloc(nslots, sizeof(void *));
    memcpy(copy, orig, nslots * sizeof(void *));
    if (kind != K_PLUGIN)
        for (int i = 4; i < nslots && i < NTRAMP; i++) copy[i] = ssw_tramp_table[i];
    pthread_mutex_lock(&g_lock);
    if (g_nent >= MAXE) { pthread_mutex_unlock(&g_lock); LOG("registry full; not wrapping %p", self); free(copy); return NULL; }
    Entry *e = &g_ent[g_nent++];
    e->self = self; e->kind = kind; e->nslots = nslots; e->orig = orig; e->copy = copy; e->version = version;
    pthread_mutex_unlock(&g_lock);
    return e;
}
static void activate(Entry *e) { *(void ***)e->self = e->copy; }

// ---------------------------------------------------------------- IID tables
typedef struct { CFUUIDRef (*get)(void); int kind; int version; int nslots; const char *name; } IIDInfo;
#define DEVI(v) static CFUUIDRef iid_dev##v(void) { return kIOUSBDeviceInterfaceID##v; }
#define IFI(v)  static CFUUIDRef iid_if##v(void)  { return kIOUSBInterfaceInterfaceID##v; }
static CFUUIDRef iid_dev(void) { return kIOUSBDeviceInterfaceID; }
static CFUUIDRef iid_if(void) { return kIOUSBInterfaceInterfaceID; }
DEVI(182) DEVI(187) DEVI(197) DEVI(245) DEVI(300) DEVI(320) DEVI(400) DEVI(500) DEVI(650) DEVI(942)
IFI(182) IFI(183) IFI(190) IFI(192) IFI(197) IFI(220) IFI(245) IFI(300) IFI(400) IFI(500) IFI(550) IFI(650) IFI(700) IFI(800) IFI(942)
#define DS(v) (int)(sizeof(IOUSBDeviceInterface##v) / sizeof(void *))
#define IS(v) (int)(sizeof(IOUSBInterfaceInterface##v) / sizeof(void *))
static const IIDInfo IIDS[] = {
    {iid_dev, K_DEVICE, 100, (int)(sizeof(IOUSBDeviceInterface) / sizeof(void *)), "kIOUSBDeviceInterfaceID"},
    {iid_dev182, K_DEVICE, 182, DS(182), "kIOUSBDeviceInterfaceID182"},
    {iid_dev187, K_DEVICE, 187, DS(187), "kIOUSBDeviceInterfaceID187"},
    {iid_dev197, K_DEVICE, 197, DS(197), "kIOUSBDeviceInterfaceID197"},
    {iid_dev245, K_DEVICE, 245, DS(245), "kIOUSBDeviceInterfaceID245"},
    {iid_dev300, K_DEVICE, 300, DS(300), "kIOUSBDeviceInterfaceID300"},
    {iid_dev320, K_DEVICE, 320, DS(320), "kIOUSBDeviceInterfaceID320"},
    {iid_dev400, K_DEVICE, 400, DS(400), "kIOUSBDeviceInterfaceID400"},
    {iid_dev500, K_DEVICE, 500, DS(500), "kIOUSBDeviceInterfaceID500"},
    {iid_dev650, K_DEVICE, 650, DS(650), "kIOUSBDeviceInterfaceID650"},
    {iid_dev942, K_DEVICE, 942, DS(942), "kIOUSBDeviceInterfaceID942"},
    {iid_if, K_INTERFACE, 100, (int)(sizeof(IOUSBInterfaceInterface) / sizeof(void *)), "kIOUSBInterfaceInterfaceID"},
    {iid_if182, K_INTERFACE, 182, IS(182), "kIOUSBInterfaceInterfaceID182"},
    {iid_if183, K_INTERFACE, 183, IS(183), "kIOUSBInterfaceInterfaceID183"},
    {iid_if190, K_INTERFACE, 190, IS(190), "kIOUSBInterfaceInterfaceID190"},
    {iid_if192, K_INTERFACE, 192, IS(192), "kIOUSBInterfaceInterfaceID192"},
    {iid_if197, K_INTERFACE, 197, IS(197), "kIOUSBInterfaceInterfaceID197"},
    {iid_if220, K_INTERFACE, 220, IS(220), "kIOUSBInterfaceInterfaceID220"},
    {iid_if245, K_INTERFACE, 245, IS(245), "kIOUSBInterfaceInterfaceID245"},
    {iid_if300, K_INTERFACE, 300, IS(300), "kIOUSBInterfaceInterfaceID300"},
    {iid_if400, K_INTERFACE, 400, IS(400), "kIOUSBInterfaceInterfaceID400"},
    {iid_if500, K_INTERFACE, 500, IS(500), "kIOUSBInterfaceInterfaceID500"},
    {iid_if550, K_INTERFACE, 550, IS(550), "kIOUSBInterfaceInterfaceID550"},
    {iid_if650, K_INTERFACE, 650, IS(650), "kIOUSBInterfaceInterfaceID650"},
    {iid_if700, K_INTERFACE, 700, IS(700), "kIOUSBInterfaceInterfaceID700"},
    {iid_if800, K_INTERFACE, 800, IS(800), "kIOUSBInterfaceInterfaceID800"},
    {iid_if942, K_INTERFACE, 942, IS(942), "kIOUSBInterfaceInterfaceID942"},
};
static const IIDInfo *lookup_iid(REFIID iid) {
    for (size_t i = 0; i < sizeof IIDS / sizeof *IIDS; i++) {
        CFUUIDBytes b = CFUUIDGetUUIDBytes(IIDS[i].get());
        if (memcmp(&b, &iid, sizeof b) == 0) return &IIDS[i];
    }
    return NULL;
}
static void uuidstr(const void *p, char *out) {
    const uint8_t *b = p;
    sprintf(out, "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
}

static void wrap_device(void *obj, const IIDInfo *ii);
static void wrap_interface(void *obj, const IIDInfo *ii);

// ---------------------------------------------------------------- common QI handling
static void after_qi(const char *who, void *self, REFIID iid, LPVOID *ppv, HRESULT hr) {
    char u[40]; uuidstr(&iid, u);
    const IIDInfo *ii = lookup_iid(iid);
    LOG("#%lu %s QueryInterface self=%p iid=%s (%s) -> hr=0x%08x obj=%p", __sync_add_and_fetch(&g_seq, 1), who, self, u,
        ii ? ii->name : "not a USB IID", (unsigned)hr, ppv ? *ppv : NULL);
    if (hr != S_OK || !ppv || !*ppv || !ii) return;
    if (ii->kind == K_DEVICE) wrap_device(*ppv, ii);
    else wrap_interface(*ppv, ii);
}

// ---------------------------------------------------------------- plug-in wrapper
static HRESULT plug_QI(void *self, REFIID iid, LPVOID *ppv) {
    Entry *e = find(self);
    HRESULT hr = ORIG(e, IOCFPlugInInterface, QueryInterface)(self, iid, ppv);
    after_qi("PLUGIN", self, iid, ppv, hr);
    return hr;
}
static ULONG plug_Release(void *self) {
    Entry *e = find(self);
    ULONG r = ORIG(e, IOCFPlugInInterface, Release)(self);
    LOG("#%lu PLUGIN Release self=%p -> %u", __sync_add_and_fetch(&g_seq, 1), self, (unsigned)r);
    return r;
}

// ---------------------------------------------------------------- device wrappers
typedef IOUSBDeviceInterface942 DI;
#define DENTRY Entry *e = find(self); unsigned long seq = __sync_add_and_fetch(&g_seq, 1)

static HRESULT dev_QI(void *self, REFIID iid, LPVOID *ppv) {
    Entry *e = find(self);
    HRESULT hr = ORIG(e, DI, QueryInterface)(self, iid, ppv);
    after_qi("DEV", self, iid, ppv, hr);
    return hr;
}
static ULONG dev_Release(void *self) {
    DENTRY; ULONG r = ORIG(e, DI, Release)(self);
    LOG("#%lu DEV Release self=%p -> refcount %u", seq, self, (unsigned)r);
    return r;
}
static IOReturn dev_Open(void *self) {
    DENTRY; IOReturn r = ORIG(e, DI, USBDeviceOpen)(self);
    LOG("#%lu DEV USBDeviceOpen self=%p -> 0x%08x %s", seq, self, r, ioret(r)); return r;
}
static IOReturn dev_OpenSeize(void *self) {
    DENTRY; IOReturn r = ORIG(e, DI, USBDeviceOpenSeize)(self);
    LOG("#%lu DEV USBDeviceOpenSeize self=%p -> 0x%08x %s", seq, self, r, ioret(r)); return r;
}
static IOReturn dev_Close(void *self) {
    DENTRY; IOReturn r = ORIG(e, DI, USBDeviceClose)(self);
    LOG("#%lu DEV USBDeviceClose self=%p -> 0x%08x %s", seq, self, r, ioret(r)); return r;
}
#define DEV_GET16(fn) static IOReturn dev_##fn(void *self, UInt16 *v) { DENTRY; IOReturn r = ORIG(e, DI, fn)(self, v); \
    LOG("#%lu DEV " #fn " -> 0x%08x %s value=0x%04x", seq, r, ioret(r), v ? *v : 0); return r; }
DEV_GET16(GetDeviceVendor) DEV_GET16(GetDeviceProduct) DEV_GET16(GetDeviceReleaseNumber)
static IOReturn dev_GetConfigDesc(void *self, UInt8 idx, IOUSBConfigurationDescriptorPtr *d) {
    DENTRY; IOReturn r = ORIG(e, DI, GetConfigurationDescriptorPtr)(self, idx, d);
    LOG("#%lu DEV GetConfigurationDescriptorPtr index=%u -> 0x%08x %s ptr=%p", seq, idx, r, ioret(r), d ? (void *)*d : NULL);
    if (r == kIOReturnSuccess && d && *d) hexdump("cfgdesc", *d, USBToHostWord((*d)->wTotalLength));
    return r;
}
static IOReturn dev_GetConfiguration(void *self, UInt8 *c) {
    DENTRY; IOReturn r = ORIG(e, DI, GetConfiguration)(self, c);
    LOG("#%lu DEV GetConfiguration -> 0x%08x %s config=%u", seq, r, ioret(r), c ? *c : 0); return r;
}
static IOReturn dev_SetConfiguration(void *self, UInt8 c) {
    DENTRY; LOG("#%lu DEV SetConfiguration config=%u ...", seq, c);
    IOReturn r = ORIG(e, DI, SetConfiguration)(self, c);
    LOG("#%lu DEV SetConfiguration -> 0x%08x %s", seq, r, ioret(r)); return r;
}
static IOReturn dev_ResetDevice(void *self) {
    DENTRY; LOG("#%lu DEV ResetDevice ...", seq);
    IOReturn r = ORIG(e, DI, ResetDevice)(self);
    LOG("#%lu DEV ResetDevice -> 0x%08x %s", seq, r, ioret(r)); return r;
}
static IOReturn dev_ReEnumerate(void *self, UInt32 opts) {
    DENTRY; LOG("#%lu DEV USBDeviceReEnumerate options=0x%x ...", seq, opts);
    IOReturn r = ORIG(e, DI, USBDeviceReEnumerate)(self, opts);
    LOG("#%lu DEV USBDeviceReEnumerate -> 0x%08x %s", seq, r, ioret(r)); return r;
}
static IOReturn dev_CreateIfIter(void *self, IOUSBFindInterfaceRequest *rq, io_iterator_t *it) {
    DENTRY; IOReturn r = ORIG(e, DI, CreateInterfaceIterator)(self, rq, it);
    LOG("#%lu DEV CreateInterfaceIterator class=0x%x sub=0x%x proto=0x%x alt=0x%x -> 0x%08x %s iter=%u", seq,
        rq ? rq->bInterfaceClass : 0, rq ? rq->bInterfaceSubClass : 0, rq ? rq->bInterfaceProtocol : 0,
        rq ? rq->bAlternateSetting : 0, r, ioret(r), it ? *it : 0);
    return r;
}

// Generic control request logging (shared by device & interface, sync & async).
static void log_req_pre(unsigned long seq, const char *who, const char *fn, void *self, int pipe,
                        uint8_t bm, uint8_t breq, uint16_t wv, uint16_t wi, uint16_t wl, void *pData,
                        int has_to, uint32_t nd, uint32_t ct) {
    char d[48];
    char pipes[16] = "";
    if (pipe >= 0) snprintf(pipes, sizeof pipes, " pipe=%d", pipe);
    char tos[48] = "";
    if (has_to) snprintf(tos, sizeof tos, " noDataTO=%u complTO=%u", nd, ct);
    LOG("#%lu %s %s self=%p%s SETUP bmRequestType=0x%02x (%s) bRequest=0x%02x wValue=0x%04x wIndex=0x%04x wLength=%u pData=%p%s",
        seq, who, fn, self, pipes, bm, bmrt_desc(bm, d, sizeof d), breq, wv, wi, wl, pData, tos);
    if (!(bm & 0x80) && wl) hexdump("OUT", pData, wl);
}
static void log_req_post(unsigned long seq, const char *who, const char *fn, IOReturn r, uint8_t bm, void *pData, uint32_t done) {
    LOG("#%lu %s %s -> 0x%08x %s wLenDone=%u", seq, who, fn, r, ioret(r), done);
    if ((bm & 0x80) && r == kIOReturnSuccess && done) hexdump("IN ", pData, done);
}

static IOReturn dev_DeviceRequest(void *self, IOUSBDevRequest *q) {
    DENTRY;
    log_req_pre(seq, "DEV", "DeviceRequest", self, -1, q->bmRequestType, q->bRequest, q->wValue, q->wIndex, q->wLength, q->pData, 0, 0, 0);
    IOReturn r = ORIG(e, DI, DeviceRequest)(self, q);
    log_req_post(seq, "DEV", "DeviceRequest", r, q->bmRequestType, q->pData, q->wLenDone);
    return r;
}
static IOReturn dev_DeviceRequestTO(void *self, IOUSBDevRequestTO *q) {
    DENTRY;
    log_req_pre(seq, "DEV", "DeviceRequestTO", self, -1, q->bmRequestType, q->bRequest, q->wValue, q->wIndex, q->wLength, q->pData, 1, q->noDataTimeout, q->completionTimeout);
    IOReturn r = ORIG(e, DI, DeviceRequestTO)(self, q);
    log_req_post(seq, "DEV", "DeviceRequestTO", r, q->bmRequestType, q->pData, q->wLenDone);
    return r;
}

// async: wrap callback
typedef struct { IOAsyncCallback1 cb; void *refcon; unsigned long seq; const char *who, *fn; uint8_t bm; void *pData; int isPipeRead; } AsyncCtx;
static void async_cb(void *refcon, IOReturn result, void *arg0) {
    AsyncCtx *c = refcon;
    uint32_t done = (uint32_t)(uintptr_t)arg0;
    LOG("#%lu %s %s COMPLETION -> 0x%08x %s bytes=%u", c->seq, c->who, c->fn, result, ioret(result), done);
    if (result == kIOReturnSuccess && done && ((c->bm & 0x80) || c->isPipeRead)) hexdump("IN ", c->pData, done);
    IOAsyncCallback1 cb = c->cb; void *rc = c->refcon; free(c);
    if (cb) cb(rc, result, arg0);
}
static AsyncCtx *mkctx(IOAsyncCallback1 cb, void *refcon, unsigned long seq, const char *who, const char *fn, uint8_t bm, void *pData, int rd) {
    AsyncCtx *c = calloc(1, sizeof *c);
    c->cb = cb; c->refcon = refcon; c->seq = seq; c->who = who; c->fn = fn; c->bm = bm; c->pData = pData; c->isPipeRead = rd;
    return c;
}
static IOReturn dev_DeviceRequestAsync(void *self, IOUSBDevRequest *q, IOAsyncCallback1 cb, void *refcon) {
    DENTRY;
    log_req_pre(seq, "DEV", "DeviceRequestAsync", self, -1, q->bmRequestType, q->bRequest, q->wValue, q->wIndex, q->wLength, q->pData, 0, 0, 0);
    AsyncCtx *c = mkctx(cb, refcon, seq, "DEV", "DeviceRequestAsync", q->bmRequestType, q->pData, 0);
    IOReturn r = ORIG(e, DI, DeviceRequestAsync)(self, q, async_cb, c);
    LOG("#%lu DEV DeviceRequestAsync submit -> 0x%08x %s", seq, r, ioret(r));
    if (r != kIOReturnSuccess) free(c);
    return r;
}
static IOReturn dev_DeviceRequestAsyncTO(void *self, IOUSBDevRequestTO *q, IOAsyncCallback1 cb, void *refcon) {
    DENTRY;
    log_req_pre(seq, "DEV", "DeviceRequestAsyncTO", self, -1, q->bmRequestType, q->bRequest, q->wValue, q->wIndex, q->wLength, q->pData, 1, q->noDataTimeout, q->completionTimeout);
    AsyncCtx *c = mkctx(cb, refcon, seq, "DEV", "DeviceRequestAsyncTO", q->bmRequestType, q->pData, 0);
    IOReturn r = ORIG(e, DI, DeviceRequestAsyncTO)(self, q, async_cb, c);
    LOG("#%lu DEV DeviceRequestAsyncTO submit -> 0x%08x %s", seq, r, ioret(r));
    if (r != kIOReturnSuccess) free(c);
    return r;
}

#define SETD(field, fn) do { size_t s = offsetof(DI, field) / sizeof(void *); if ((int)s < e->nslots) e->copy[s] = (void *)(fn); } while (0)
static void wrap_device(void *obj, const IIDInfo *ii) {
    if (find(obj)) { LOG("    (device object %p already wrapped)", obj); return; }
    Entry *e = install(obj, K_DEVICE, ii->nslots, ii->version);
    if (!e) return;
    SETD(QueryInterface, dev_QI); SETD(AddRef, e->orig[2]); SETD(Release, dev_Release);
    SETD(USBDeviceOpen, dev_Open); SETD(USBDeviceClose, dev_Close);
    SETD(GetDeviceVendor, dev_GetDeviceVendor); SETD(GetDeviceProduct, dev_GetDeviceProduct);
    SETD(GetDeviceReleaseNumber, dev_GetDeviceReleaseNumber);
    SETD(GetConfigurationDescriptorPtr, dev_GetConfigDesc);
    SETD(GetConfiguration, dev_GetConfiguration); SETD(SetConfiguration, dev_SetConfiguration);
    SETD(ResetDevice, dev_ResetDevice);
    SETD(DeviceRequest, dev_DeviceRequest); SETD(DeviceRequestAsync, dev_DeviceRequestAsync);
    SETD(CreateInterfaceIterator, dev_CreateIfIter);
    if (ii->version >= 182) {
        SETD(USBDeviceOpenSeize, dev_OpenSeize); SETD(DeviceRequestTO, dev_DeviceRequestTO);
        SETD(DeviceRequestAsyncTO, dev_DeviceRequestAsyncTO); SETD(USBDeviceReEnumerate, dev_ReEnumerate);
    }
    activate(e);
    LOG("    wrapped USB device interface %p (%s, %d slots; private vtable %p, original %p)", obj, ii->name, ii->nslots, (void *)e->copy, (void *)e->orig);
}

// ---------------------------------------------------------------- interface wrappers
typedef IOUSBInterfaceInterface942 II;
static HRESULT if_QI(void *self, REFIID iid, LPVOID *ppv) {
    Entry *e = find(self);
    HRESULT hr = ORIG(e, II, QueryInterface)(self, iid, ppv);
    after_qi("IF", self, iid, ppv, hr);
    return hr;
}
static ULONG if_Release(void *self) { DENTRY; ULONG r = ORIG(e, II, Release)(self); LOG("#%lu IF Release self=%p -> refcount %u", seq, self, (unsigned)r); return r; }
static IOReturn if_Open(void *self) { DENTRY; IOReturn r = ORIG(e, II, USBInterfaceOpen)(self); LOG("#%lu IF USBInterfaceOpen self=%p -> 0x%08x %s", seq, self, r, ioret(r)); return r; }
static IOReturn if_OpenSeize(void *self) { DENTRY; IOReturn r = ORIG(e, II, USBInterfaceOpenSeize)(self); LOG("#%lu IF USBInterfaceOpenSeize self=%p -> 0x%08x %s", seq, self, r, ioret(r)); return r; }
static IOReturn if_Close(void *self) { DENTRY; IOReturn r = ORIG(e, II, USBInterfaceClose)(self); LOG("#%lu IF USBInterfaceClose self=%p -> 0x%08x %s", seq, self, r, ioret(r)); return r; }
#define IF_GET8(fn) static IOReturn if_##fn(void *self, UInt8 *v) { DENTRY; IOReturn r = ORIG(e, II, fn)(self, v); \
    LOG("#%lu IF " #fn " self=%p -> 0x%08x %s value=0x%02x", seq, self, r, ioret(r), v ? *v : 0); return r; }
IF_GET8(GetInterfaceClass) IF_GET8(GetInterfaceSubClass) IF_GET8(GetInterfaceProtocol) IF_GET8(GetInterfaceNumber) IF_GET8(GetNumEndpoints) IF_GET8(GetAlternateSetting)
static IOReturn if_SetAlt(void *self, UInt8 alt) { DENTRY; IOReturn r = ORIG(e, II, SetAlternateInterface)(self, alt); LOG("#%lu IF SetAlternateInterface alt=%u -> 0x%08x %s", seq, alt, r, ioret(r)); return r; }
static IOReturn if_GetPipeProps(void *self, UInt8 p, UInt8 *dir, UInt8 *num, UInt8 *tt, UInt16 *mps, UInt8 *iv) {
    DENTRY; IOReturn r = ORIG(e, II, GetPipeProperties)(self, p, dir, num, tt, mps, iv);
    LOG("#%lu IF GetPipeProperties pipe=%u -> 0x%08x %s dir=%u ep=%u type=%u maxPacket=%u interval=%u", seq, p, r, ioret(r),
        dir ? *dir : 0, num ? *num : 0, tt ? *tt : 0, mps ? *mps : 0, iv ? *iv : 0);
    return r;
}
#define IF_PIPEOP(fn) static IOReturn if_##fn(void *self, UInt8 p) { DENTRY; IOReturn r = ORIG(e, II, fn)(self, p); \
    LOG("#%lu IF " #fn " pipe=%u -> 0x%08x %s", seq, p, r, ioret(r)); return r; }
IF_PIPEOP(AbortPipe) IF_PIPEOP(ResetPipe) IF_PIPEOP(ClearPipeStall) IF_PIPEOP(GetPipeStatus)
static IOReturn if_ControlRequest(void *self, UInt8 pipe, IOUSBDevRequest *q) {
    DENTRY;
    log_req_pre(seq, "IF", "ControlRequest", self, pipe, q->bmRequestType, q->bRequest, q->wValue, q->wIndex, q->wLength, q->pData, 0, 0, 0);
    IOReturn r = ORIG(e, II, ControlRequest)(self, pipe, q);
    log_req_post(seq, "IF", "ControlRequest", r, q->bmRequestType, q->pData, q->wLenDone);
    return r;
}
static IOReturn if_ControlRequestTO(void *self, UInt8 pipe, IOUSBDevRequestTO *q) {
    DENTRY;
    log_req_pre(seq, "IF", "ControlRequestTO", self, pipe, q->bmRequestType, q->bRequest, q->wValue, q->wIndex, q->wLength, q->pData, 1, q->noDataTimeout, q->completionTimeout);
    IOReturn r = ORIG(e, II, ControlRequestTO)(self, pipe, q);
    log_req_post(seq, "IF", "ControlRequestTO", r, q->bmRequestType, q->pData, q->wLenDone);
    return r;
}
static IOReturn if_ControlRequestAsync(void *self, UInt8 pipe, IOUSBDevRequest *q, IOAsyncCallback1 cb, void *rc) {
    DENTRY;
    log_req_pre(seq, "IF", "ControlRequestAsync", self, pipe, q->bmRequestType, q->bRequest, q->wValue, q->wIndex, q->wLength, q->pData, 0, 0, 0);
    AsyncCtx *c = mkctx(cb, rc, seq, "IF", "ControlRequestAsync", q->bmRequestType, q->pData, 0);
    IOReturn r = ORIG(e, II, ControlRequestAsync)(self, pipe, q, async_cb, c);
    LOG("#%lu IF ControlRequestAsync submit -> 0x%08x %s", seq, r, ioret(r)); if (r) free(c); return r;
}
static IOReturn if_ControlRequestAsyncTO(void *self, UInt8 pipe, IOUSBDevRequestTO *q, IOAsyncCallback1 cb, void *rc) {
    DENTRY;
    log_req_pre(seq, "IF", "ControlRequestAsyncTO", self, pipe, q->bmRequestType, q->bRequest, q->wValue, q->wIndex, q->wLength, q->pData, 1, q->noDataTimeout, q->completionTimeout);
    AsyncCtx *c = mkctx(cb, rc, seq, "IF", "ControlRequestAsyncTO", q->bmRequestType, q->pData, 0);
    IOReturn r = ORIG(e, II, ControlRequestAsyncTO)(self, pipe, q, async_cb, c);
    LOG("#%lu IF ControlRequestAsyncTO submit -> 0x%08x %s", seq, r, ioret(r)); if (r) free(c); return r;
}
static IOReturn if_ReadPipe(void *self, UInt8 p, void *buf, UInt32 *sz) {
    DENTRY; UInt32 req = sz ? *sz : 0;
    LOG("#%lu IF ReadPipe pipe=%u buf=%p size=%u ...", seq, p, buf, req);
    IOReturn r = ORIG(e, II, ReadPipe)(self, p, buf, sz);
    LOG("#%lu IF ReadPipe -> 0x%08x %s got=%u", seq, r, ioret(r), sz ? *sz : 0);
    if (r == kIOReturnSuccess && sz && *sz) hexdump("IN ", buf, *sz);
    return r;
}
static IOReturn if_WritePipe(void *self, UInt8 p, void *buf, UInt32 sz) {
    DENTRY; LOG("#%lu IF WritePipe pipe=%u size=%u", seq, p, sz); hexdump("OUT", buf, sz);
    IOReturn r = ORIG(e, II, WritePipe)(self, p, buf, sz);
    LOG("#%lu IF WritePipe -> 0x%08x %s", seq, r, ioret(r)); return r;
}
static IOReturn if_ReadPipeTO(void *self, UInt8 p, void *buf, UInt32 *sz, UInt32 nd, UInt32 ct) {
    DENTRY; UInt32 req = sz ? *sz : 0;
    LOG("#%lu IF ReadPipeTO pipe=%u buf=%p size=%u noDataTO=%u complTO=%u ...", seq, p, buf, req, nd, ct);
    IOReturn r = ORIG(e, II, ReadPipeTO)(self, p, buf, sz, nd, ct);
    LOG("#%lu IF ReadPipeTO -> 0x%08x %s got=%u", seq, r, ioret(r), sz ? *sz : 0);
    if (r == kIOReturnSuccess && sz && *sz) hexdump("IN ", buf, *sz);
    return r;
}
static IOReturn if_WritePipeTO(void *self, UInt8 p, void *buf, UInt32 sz, UInt32 nd, UInt32 ct) {
    DENTRY; LOG("#%lu IF WritePipeTO pipe=%u size=%u noDataTO=%u complTO=%u", seq, p, sz, nd, ct); hexdump("OUT", buf, sz);
    IOReturn r = ORIG(e, II, WritePipeTO)(self, p, buf, sz, nd, ct);
    LOG("#%lu IF WritePipeTO -> 0x%08x %s", seq, r, ioret(r)); return r;
}
static IOReturn if_ReadPipeAsync(void *self, UInt8 p, void *buf, UInt32 sz, IOAsyncCallback1 cb, void *rc) {
    DENTRY; LOG("#%lu IF ReadPipeAsync pipe=%u buf=%p size=%u", seq, p, buf, sz);
    AsyncCtx *c = mkctx(cb, rc, seq, "IF", "ReadPipeAsync", 0, buf, 1);
    IOReturn r = ORIG(e, II, ReadPipeAsync)(self, p, buf, sz, async_cb, c);
    LOG("#%lu IF ReadPipeAsync submit -> 0x%08x %s", seq, r, ioret(r)); if (r) free(c); return r;
}
static IOReturn if_WritePipeAsync(void *self, UInt8 p, void *buf, UInt32 sz, IOAsyncCallback1 cb, void *rc) {
    DENTRY; LOG("#%lu IF WritePipeAsync pipe=%u size=%u", seq, p, sz); hexdump("OUT", buf, sz);
    AsyncCtx *c = mkctx(cb, rc, seq, "IF", "WritePipeAsync", 0, buf, 0);
    IOReturn r = ORIG(e, II, WritePipeAsync)(self, p, buf, sz, async_cb, c);
    LOG("#%lu IF WritePipeAsync submit -> 0x%08x %s", seq, r, ioret(r)); if (r) free(c); return r;
}
static IOReturn if_ReadPipeAsyncTO(void *self, UInt8 p, void *buf, UInt32 sz, UInt32 nd, UInt32 ct, IOAsyncCallback1 cb, void *rc) {
    DENTRY; LOG("#%lu IF ReadPipeAsyncTO pipe=%u buf=%p size=%u noDataTO=%u complTO=%u", seq, p, buf, sz, nd, ct);
    AsyncCtx *c = mkctx(cb, rc, seq, "IF", "ReadPipeAsyncTO", 0, buf, 1);
    IOReturn r = ORIG(e, II, ReadPipeAsyncTO)(self, p, buf, sz, nd, ct, async_cb, c);
    LOG("#%lu IF ReadPipeAsyncTO submit -> 0x%08x %s", seq, r, ioret(r)); if (r) free(c); return r;
}
static IOReturn if_WritePipeAsyncTO(void *self, UInt8 p, void *buf, UInt32 sz, UInt32 nd, UInt32 ct, IOAsyncCallback1 cb, void *rc) {
    DENTRY; LOG("#%lu IF WritePipeAsyncTO pipe=%u size=%u noDataTO=%u complTO=%u", seq, p, sz, nd, ct); hexdump("OUT", buf, sz);
    AsyncCtx *c = mkctx(cb, rc, seq, "IF", "WritePipeAsyncTO", 0, buf, 0);
    IOReturn r = ORIG(e, II, WritePipeAsyncTO)(self, p, buf, sz, nd, ct, async_cb, c);
    LOG("#%lu IF WritePipeAsyncTO submit -> 0x%08x %s", seq, r, ioret(r)); if (r) free(c); return r;
}

#define SETI(field, fn) do { size_t s = offsetof(II, field) / sizeof(void *); if ((int)s < e->nslots) e->copy[s] = (void *)(fn); } while (0)
static void wrap_interface(void *obj, const IIDInfo *ii) {
    if (find(obj)) { LOG("    (interface object %p already wrapped)", obj); return; }
    Entry *e = install(obj, K_INTERFACE, ii->nslots, ii->version);
    if (!e) return;
    SETI(QueryInterface, if_QI); SETI(AddRef, e->orig[2]); SETI(Release, if_Release);
    SETI(USBInterfaceOpen, if_Open); SETI(USBInterfaceClose, if_Close);
    SETI(GetInterfaceClass, if_GetInterfaceClass); SETI(GetInterfaceSubClass, if_GetInterfaceSubClass);
    SETI(GetInterfaceProtocol, if_GetInterfaceProtocol); SETI(GetInterfaceNumber, if_GetInterfaceNumber);
    SETI(GetNumEndpoints, if_GetNumEndpoints); SETI(GetAlternateSetting, if_GetAlternateSetting);
    SETI(SetAlternateInterface, if_SetAlt); SETI(GetPipeProperties, if_GetPipeProps);
    SETI(AbortPipe, if_AbortPipe); SETI(ResetPipe, if_ResetPipe); SETI(ClearPipeStall, if_ClearPipeStall); SETI(GetPipeStatus, if_GetPipeStatus);
    SETI(ControlRequest, if_ControlRequest); SETI(ControlRequestAsync, if_ControlRequestAsync);
    SETI(ReadPipe, if_ReadPipe); SETI(WritePipe, if_WritePipe);
    SETI(ReadPipeAsync, if_ReadPipeAsync); SETI(WritePipeAsync, if_WritePipeAsync);
    if (ii->version >= 182) {
        SETI(ControlRequestTO, if_ControlRequestTO); SETI(ControlRequestAsyncTO, if_ControlRequestAsyncTO);
        SETI(ReadPipeTO, if_ReadPipeTO); SETI(WritePipeTO, if_WritePipeTO);
        SETI(ReadPipeAsyncTO, if_ReadPipeAsyncTO); SETI(WritePipeAsyncTO, if_WritePipeAsyncTO);
    }
    if (ii->version >= 183) SETI(USBInterfaceOpenSeize, if_OpenSeize);
    activate(e);
    LOG("    wrapped USB interface interface %p (%s, %d slots; private vtable %p, original %p)", obj, ii->name, ii->nslots, (void *)e->copy, (void *)e->orig);
}

// ---------------------------------------------------------------- interposed C functions
static void cfdesc(const char *tag, CFTypeRef o) {
    if (!o) { LOG("    %s: NULL", tag); return; }
    CFStringRef s = CFCopyDescription(o);
    char buf[2048] = "?";
    if (s) { CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(s); }
    for (char *p = buf; *p; p++) if (*p == '\n') *p = ' ';
    LOG("    %s: %s", tag, buf);
}
static void svcdesc(io_service_t s) {
    if (!s) return;
    io_name_t cls = "", nm = "";
    IOObjectGetClass(s, cls); IORegistryEntryGetName(s, nm);
    uint64_t id = 0; IORegistryEntryGetRegistryEntryID(s, &id);
    LOG("    service %u: class=%s name=\"%s\" registryID=0x%llx", s, cls, nm, (unsigned long long)id);
}

static kern_return_t my_IOCreatePlugInInterfaceForService(io_service_t service, CFUUIDRef pluginType, CFUUIDRef interfaceType,
                                                          IOCFPlugInInterface ***theInterface, SInt32 *theScore) {
    unsigned long seq = __sync_add_and_fetch(&g_seq, 1);
    char a[40] = "", b[40] = "";
    if (pluginType) { CFUUIDBytes x = CFUUIDGetUUIDBytes(pluginType); uuidstr(&x, a); }
    if (interfaceType) { CFUUIDBytes x = CFUUIDGetUUIDBytes(interfaceType); uuidstr(&x, b); }
    LOG("#%lu IOCreatePlugInInterfaceForService service=%u pluginType=%s interfaceType=%s", seq, service, a, b);
    svcdesc(service);
    kern_return_t r = IOCreatePlugInInterfaceForService(service, pluginType, interfaceType, theInterface, theScore);
    LOG("#%lu IOCreatePlugInInterfaceForService -> 0x%08x plugin=%p score=%d", seq, r, theInterface ? (void *)*theInterface : NULL, theScore ? *theScore : 0);
    if (r == KERN_SUCCESS && theInterface && *theInterface) {
        void *obj = *theInterface;
        if (!find(obj)) {
            Entry *e = install(obj, K_PLUGIN, (int)(sizeof(IOCFPlugInInterface) / sizeof(void *)), 0);
            if (e) {
                e->copy[offsetof(IOCFPlugInInterface, QueryInterface) / sizeof(void *)] = (void *)plug_QI;
                e->copy[offsetof(IOCFPlugInInterface, Release) / sizeof(void *)] = (void *)plug_Release;
                activate(e);
                LOG("    wrapped IOCFPlugInInterface %p (private vtable %p)", obj, (void *)e->copy);
            }
        }
    }
    return r;
}
static CFMutableDictionaryRef my_IOServiceMatching(const char *name) {
    CFMutableDictionaryRef d = IOServiceMatching(name);
    LOG("#%lu IOServiceMatching(\"%s\") -> %p", __sync_add_and_fetch(&g_seq, 1), name ? name : "(null)", (void *)d);
    return d;
}
static io_service_t my_IOServiceGetMatchingService(mach_port_t mp, CFDictionaryRef m) {
    unsigned long seq = __sync_add_and_fetch(&g_seq, 1);
    LOG("#%lu IOServiceGetMatchingService", seq);
    cfdesc("matching", m);  // describe before the call: the call consumes the reference
    io_service_t s = IOServiceGetMatchingService(mp, m);
    LOG("#%lu IOServiceGetMatchingService -> service=%u", seq, s);
    svcdesc(s);
    return s;
}
static kern_return_t my_IOServiceGetMatchingServices(mach_port_t mp, CFDictionaryRef m, io_iterator_t *it) {
    unsigned long seq = __sync_add_and_fetch(&g_seq, 1);
    LOG("#%lu IOServiceGetMatchingServices", seq); cfdesc("matching", m);
    kern_return_t r = IOServiceGetMatchingServices(mp, m, it);
    LOG("#%lu IOServiceGetMatchingServices -> 0x%08x iter=%u", seq, r, it ? *it : 0);
    return r;
}
static kern_return_t my_IOServiceAddMatchingNotification(IONotificationPortRef np, const io_name_t type, CFDictionaryRef m,
                                                         IOServiceMatchingCallback cb, void *rc, io_iterator_t *it) {
    unsigned long seq = __sync_add_and_fetch(&g_seq, 1);
    LOG("#%lu IOServiceAddMatchingNotification type=%s", seq, type); cfdesc("matching", m);
    kern_return_t r = IOServiceAddMatchingNotification(np, type, m, cb, rc, it);
    LOG("#%lu IOServiceAddMatchingNotification -> 0x%08x iter=%u", seq, r, it ? *it : 0);
    return r;
}
static kern_return_t my_IOServiceOpen(io_service_t s, task_port_t t, uint32_t type, io_connect_t *c) {
    unsigned long seq = __sync_add_and_fetch(&g_seq, 1);
    kern_return_t r = IOServiceOpen(s, t, type, c);
    if (g_trace_ioconnect) { LOG("#%lu IOServiceOpen service=%u type=%u -> 0x%08x connect=%u", seq, s, type, r, c ? *c : 0); svcdesc(s); }
    return r;
}
static void log_scalars(const char *tag, const uint64_t *v, uint32_t n) {
    if (!v || !n) return;
    char buf[512]; int k = 0;
    for (uint32_t i = 0; i < n && k < 480; i++) k += snprintf(buf + k, sizeof buf - k, "0x%llx ", (unsigned long long)v[i]);
    LOG("    %s scalars[%u]: %s", tag, n, buf);
}
static kern_return_t my_IOConnectCallMethod(mach_port_t c, uint32_t sel, const uint64_t *in, uint32_t inCnt, const void *inS, size_t inSCnt,
                                            uint64_t *out, uint32_t *outCnt, void *outS, size_t *outSCnt) {
    unsigned long seq = __sync_add_and_fetch(&g_seq, 1);
    if (g_trace_ioconnect) {
        LOG("#%lu IOConnectCallMethod connect=%u selector=%u inScalars=%u inStruct=%zu outScalars=%u outStruct=%zu", seq, c, sel, inCnt, inSCnt,
            outCnt ? *outCnt : 0, outSCnt ? *outSCnt : 0);
        log_scalars("in", in, inCnt);
        if (inS && inSCnt) hexdump("inStruct", inS, inSCnt > 4096 ? 4096 : inSCnt);
    }
    kern_return_t r = IOConnectCallMethod(c, sel, in, inCnt, inS, inSCnt, out, outCnt, outS, outSCnt);
    if (g_trace_ioconnect) {
        LOG("#%lu IOConnectCallMethod -> 0x%08x %s", seq, r, ioret(r));
        if (r == KERN_SUCCESS) {
            log_scalars("out", out, outCnt ? *outCnt : 0);
            if (outS && outSCnt && *outSCnt) hexdump("outStruct", outS, *outSCnt > 4096 ? 4096 : *outSCnt);
        }
    }
    return r;
}
static kern_return_t my_IOConnectCallAsyncMethod(mach_port_t c, uint32_t sel, mach_port_t wake, uint64_t *ref, uint32_t refCnt,
                                                 const uint64_t *in, uint32_t inCnt, const void *inS, size_t inSCnt,
                                                 uint64_t *out, uint32_t *outCnt, void *outS, size_t *outSCnt) {
    unsigned long seq = __sync_add_and_fetch(&g_seq, 1);
    if (g_trace_ioconnect) {
        LOG("#%lu IOConnectCallAsyncMethod connect=%u selector=%u inScalars=%u inStruct=%zu", seq, c, sel, inCnt, inSCnt);
        log_scalars("in", in, inCnt);
        if (inS && inSCnt) hexdump("inStruct", inS, inSCnt > 4096 ? 4096 : inSCnt);
    }
    kern_return_t r = IOConnectCallAsyncMethod(c, sel, wake, ref, refCnt, in, inCnt, inS, inSCnt, out, outCnt, outS, outSCnt);
    if (g_trace_ioconnect) LOG("#%lu IOConnectCallAsyncMethod -> 0x%08x %s", seq, r, ioret(r));
    return r;
}
static kern_return_t my_IOConnectCallStructMethod(mach_port_t c, uint32_t sel, const void *inS, size_t inSCnt, void *outS, size_t *outSCnt) {
    unsigned long seq = __sync_add_and_fetch(&g_seq, 1);
    if (g_trace_ioconnect) { LOG("#%lu IOConnectCallStructMethod connect=%u selector=%u inStruct=%zu", seq, c, sel, inSCnt);
        if (inS && inSCnt) hexdump("inStruct", inS, inSCnt > 4096 ? 4096 : inSCnt); }
    kern_return_t r = IOConnectCallStructMethod(c, sel, inS, inSCnt, outS, outSCnt);
    if (g_trace_ioconnect) { LOG("#%lu IOConnectCallStructMethod -> 0x%08x %s", seq, r, ioret(r));
        if (!r && outS && outSCnt && *outSCnt) hexdump("outStruct", outS, *outSCnt > 4096 ? 4096 : *outSCnt); }
    return r;
}
static kern_return_t my_IOConnectCallScalarMethod(mach_port_t c, uint32_t sel, const uint64_t *in, uint32_t inCnt, uint64_t *out, uint32_t *outCnt) {
    unsigned long seq = __sync_add_and_fetch(&g_seq, 1);
    if (g_trace_ioconnect) { LOG("#%lu IOConnectCallScalarMethod connect=%u selector=%u", seq, c, sel); log_scalars("in", in, inCnt); }
    kern_return_t r = IOConnectCallScalarMethod(c, sel, in, inCnt, out, outCnt);
    if (g_trace_ioconnect) { LOG("#%lu IOConnectCallScalarMethod -> 0x%08x %s", seq, r, ioret(r)); if (!r) log_scalars("out", out, outCnt ? *outCnt : 0); }
    return r;
}

#define INTERPOSE(rep, orig) \
    __attribute__((used)) static const struct { const void *r; const void *o; } _ip_##orig \
    __attribute__((section("__DATA,__interpose"))) = {(const void *)(rep), (const void *)(orig)}
INTERPOSE(my_IOCreatePlugInInterfaceForService, IOCreatePlugInInterfaceForService);
INTERPOSE(my_IOServiceMatching, IOServiceMatching);
INTERPOSE(my_IOServiceGetMatchingService, IOServiceGetMatchingService);
INTERPOSE(my_IOServiceGetMatchingServices, IOServiceGetMatchingServices);
INTERPOSE(my_IOServiceAddMatchingNotification, IOServiceAddMatchingNotification);
INTERPOSE(my_IOServiceOpen, IOServiceOpen);
INTERPOSE(my_IOConnectCallMethod, IOConnectCallMethod);
INTERPOSE(my_IOConnectCallAsyncMethod, IOConnectCallAsyncMethod);
INTERPOSE(my_IOConnectCallStructMethod, IOConnectCallStructMethod);
INTERPOSE(my_IOConnectCallScalarMethod, IOConnectCallScalarMethod);

__attribute__((constructor)) static void ssw_init(void) {
    mach_timebase_info(&g_tb);
    g_t0 = mach_absolute_time();
    const char *p = getenv("SSW_LOG");
    if (p && *p) {
        g_log = fopen(p, "a");
        if (!g_log) fprintf(stderr, "ssw_usbtrace: cannot open %s, logging to stderr\n", p);
    }
    const char *t = getenv("SSW_TRACE_IOCONNECT");
    if (t && !strcmp(t, "0")) g_trace_ioconnect = 0;
    int tr = 0; size_t sz = sizeof tr;
    if (sysctlbyname("sysctl.proc_translated", &tr, &sz, NULL, 0) != 0) tr = -1;
    char path[1024] = "?"; uint32_t ps = sizeof path;
    extern int _NSGetExecutablePath(char *, uint32_t *);
    _NSGetExecutablePath(path, &ps);
    LOG("=== ssw_usbtrace loaded: pid=%d exe=%s rosetta_translated=%d ioconnect_trace=%d ===", getpid(), path, tr, g_trace_ioconnect);
}
