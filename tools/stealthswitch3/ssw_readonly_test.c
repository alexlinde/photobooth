// ssw_readonly_test.c -- READ-ONLY exerciser for ssw_usbtrace.dylib.
// Mirrors the app's device lookup (IOServiceMatching("IOUSBDevice") + idVendor/idProduct,
// IOCreatePlugInInterfaceForService, QueryInterface(kIOUSBDeviceInterfaceID182)) and then
// performs only reads:
//   * cached getters (vendor, product, release, speed, location, config descriptor ptr)
//   * two standard GET_DESCRIPTOR requests (device descriptor, product string)
//   * enumerates interfaces and reads their cached class/number/endpoint counts.
// It never opens the device or an interface, and never sends any SET/vendor/class request.
//
// Build: clang -arch x86_64 -o ssw_readonly_test ssw_readonly_test.c -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

static void setint(CFMutableDictionaryRef d, CFStringRef k, int v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFDictionarySetValue(d, k, n); CFRelease(n);
}

int main(void) {
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBDevice");
    setint(m, CFSTR("idVendor"), 0x1324);
    setint(m, CFSTR("idProduct"), 0x0103);
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!svc) { printf("device not found\n"); return 1; }

    IOCFPlugInInterface **plug = NULL; SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    if (kr || !plug) { printf("plugin failed 0x%x\n", kr); return 1; }
    IOUSBDeviceInterface182 **dev = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (hr || !dev) { printf("QI failed 0x%x\n", (int)hr); return 1; }

    UInt16 v = 0, p = 0, rel = 0; UInt8 speed = 0; UInt32 loc = 0;
    (*dev)->GetDeviceVendor(dev, &v);
    (*dev)->GetDeviceProduct(dev, &p);
    (*dev)->GetDeviceReleaseNumber(dev, &rel);
    (*dev)->GetDeviceSpeed(dev, &speed);       // not specially wrapped -> exercises asm trampoline
    (*dev)->GetLocationID(dev, &loc);          // ditto
    printf("vendor=0x%04x product=0x%04x bcdDevice=0x%04x speed=%u location=0x%08x\n", v, p, rel, speed, loc);

    IOUSBConfigurationDescriptorPtr cd = NULL;
    kr = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &cd);
    printf("GetConfigurationDescriptorPtr -> 0x%x totalLength=%u\n", kr, cd ? USBToHostWord(cd->wTotalLength) : 0);

    // Standard GET_DESCRIPTOR(DEVICE) -- read-only, does not change device state.
    UInt8 buf[256] = {0};
    IOUSBDevRequestTO rq = {0};
    rq.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice);   // 0x80
    rq.bRequest = kUSBRqGetDescriptor;                                          // 6
    rq.wValue = (kUSBDeviceDesc << 8) | 0;
    rq.wIndex = 0; rq.wLength = 18; rq.pData = buf;
    rq.noDataTimeout = 1000; rq.completionTimeout = 1000;
    kr = (*dev)->DeviceRequestTO(dev, &rq);
    printf("GET_DESCRIPTOR(device) -> 0x%x len=%u\n", kr, rq.wLenDone);

    // Standard GET_DESCRIPTOR(STRING, iProduct=2, LANGID 0x0409) -- read-only.
    memset(buf, 0, sizeof buf);
    IOUSBDevRequest rq2 = {0};
    rq2.bmRequestType = 0x80; rq2.bRequest = kUSBRqGetDescriptor;
    rq2.wValue = (kUSBStringDesc << 8) | 2; rq2.wIndex = 0x0409; rq2.wLength = 255; rq2.pData = buf;
    kr = (*dev)->DeviceRequest(dev, &rq2);
    printf("GET_DESCRIPTOR(string 2) -> 0x%x len=%u\n", kr, rq2.wLenDone);

    // Enumerate interfaces read-only.
    IOUSBFindInterfaceRequest fr = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
    io_iterator_t it = 0;
    kr = (*dev)->CreateInterfaceIterator(dev, &fr, &it);
    io_service_t ifs;
    while (kr == 0 && (ifs = IOIteratorNext(it))) {
        IOCFPlugInInterface **ip = NULL;
        if (IOCreatePlugInInterfaceForService(ifs, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &ip, &score) == 0 && ip) {
            IOUSBInterfaceInterface190 **intf = NULL;
            (*ip)->QueryInterface(ip, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID190), (LPVOID *)&intf);
            (*ip)->Release(ip);
            if (intf) {
                UInt8 num = 0, cls = 0, sub = 0, ne = 0;
                (*intf)->GetInterfaceNumber(intf, &num);
                (*intf)->GetInterfaceClass(intf, &cls);
                (*intf)->GetInterfaceSubClass(intf, &sub);
                (*intf)->GetNumEndpoints(intf, &ne);
                printf("interface %u class=0x%02x sub=0x%02x endpoints=%u\n", num, cls, sub, ne);
                (*intf)->Release(intf);
            }
        }
        IOObjectRelease(ifs);
    }
    if (it) IOObjectRelease(it);
    (*dev)->Release(dev);
    IOObjectRelease(svc);
    return 0;
}
