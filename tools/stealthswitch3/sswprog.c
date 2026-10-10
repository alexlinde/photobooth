// sswprog.c -- command-line programmer for the H-Mod StealthSwitch 3 USB foot switch
// (VID 0x1324, PID 0x0103).  Replaces the vendor's StealthSwitch3.app.
// Protocol: docs/stealthswitch3-protocol.md (sections 2, 3, 6.4).  Image encoding mirrors ssw_proto.py.
//
// Build:  ./build.sh   (or: clang -arch arm64 -arch x86_64 -Wall -o sswprog sswprog.c \
//                              -framework IOKit -framework CoreFoundation)
//
// Usage:
//   sswprog keys                          list the accepted key names
//   sswprog [--10] [--shift N] 1=<key> 2=<key> ... [--write]
//       Build the config from per-switch assignments (unassigned switches = none).
//       "3=a/b" gives switch 3 normal key a and shifted key b.  --10 selects the 10-switch
//       product (default is the 5-switch product).  --shift N makes switch N the shift switch.
//   sswprog --ssconfig file.ssconfig [--write]
//       Build the config from a StealthSwitch3.app saved configuration (macros included).
//   sswprog --selftest                    check the encoder against the golden images captured from the app
//
// Without --write this is a DRY RUN: prints the 96-byte image, checksum and per-switch summary and
// never touches the device.  With --write the image is sent to the device (start, 3 x (block, status),
// end) and the program exits 0 only if every call succeeded and all three status bytes were 0x01.
// If the seize fails, quit StealthSwitch3.app / RoboCon and retry.
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define SIZE 96
#define NIN 28
#define OFF_CKSUM 57
#define OFF_MODE 58
#define OFF_MACRO 59

typedef struct { const char *name; unsigned char byte; } Key;
// Names/values from ssw_proto.py KEYS (already reduced with byte_of: E0-prefixed -> 0x80|code).
static const Key KEYS[] = {
    {"<none>",0xff},{"A",0x1c},{"B",0x32},{"C",0x21},{"D",0x23},{"E",0x24},{"F",0x2b},{"G",0x34},
    {"H",0x33},{"I",0x43},{"J",0x3b},{"K",0x42},{"L",0x4b},{"M",0x3a},{"N",0x31},{"O",0x44},
    {"P",0x4d},{"Q",0x15},{"R",0x2d},{"S",0x1b},{"T",0x2c},{"U",0x3c},{"V",0x2a},{"W",0x1d},
    {"X",0x22},{"Y",0x35},{"Z",0x1a},{"1",0x16},{"2",0x1e},{"3",0x26},{"4",0x25},{"5",0x2e},
    {"6",0x36},{"7",0x3d},{"8",0x3e},{"9",0x46},{"0",0x45},{"Home",0xec},{"End",0xe9},
    {"Page Up",0xfd},{"Page Down",0xfa},{"Up Arrow",0xf5},{"Down Arrow",0xf2},
    {"Left Arrow",0xeb},{"Right Arrow",0xf4},{"Left Mouse Click",0xd0},{"Right Mouse Click",0xd3},
    {"Middle Mouse Click",0xd1},{"Double Click",0xe8},{"Left Mouse Toggle",0xd6},
    {"Middle Mouse Toggle",0xd7},{"Return",0x5a},{"Enter",0xda},{"Escape",0x76},{"Insert",0xf0},
    {"Delete",0xf1},{"Backspace",0x66},{"Caps Lock",0x58},{"Tab",0x0d},{"Print Screen",0x7f},
    {"Space",0x29},{"-",0x4e},{"=",0x55},{"[",0x54},{"]",0x5b},{"\\",0x5d},{";",0x4c},{"'",0x52},
    {"`",0x0e},{",",0x41},{".",0x49},{"/",0x4a},{"Command / Apple",0x9f},{"Left Shift",0x12},
    {"Left Control",0x14},{"Left Option",0x11},{"Right Shift",0x59},{"Right Control",0x94},
    {"Right Option",0x91},{"Shift Toggle",0xde},{"Control Toggle",0xdc},{"Option Toggle",0xdf},
    {"F1",0x05},{"F2",0x06},{"F3",0x04},{"F4",0x0c},{"F5",0x03},{"F6",0x0b},{"F7",0x83},{"F8",0x0a},
    {"F9",0x01},{"F10",0x09},{"F11",0x78},{"F12",0x07},{"Num /",0xca},{"Num *",0x7c},{"Num -",0x7b},
    {"Num +",0x79},{"Num =",0x0f},{"Num 1",0x69},{"Num 2",0x72},{"Num 3",0x7a},{"Num 4",0x6b},
    {"Num 5",0x73},{"Num 6",0x74},{"Num 7",0x6c},{"Num 8",0x75},{"Num 9",0x7d},{"Num 0",0x70},
    {"Num .",0x71},{"Key Macro 1",0xe0},{"Key Macro 2",0xe1},{"Key Macro 3",0xe2},{"Key Macro 4",0xe3},
    {"H-Mod Shift Toggle",0xe7},
};
#define NKEYS ((int)(sizeof KEYS / sizeof KEYS[0]))

static const struct { const char *alias; const char *name; } ALIASES[] = {
    {"printscreen","Print Screen"},{"prtsc","Print Screen"},{"prtscr","Print Screen"},{"printscr","Print Screen"},
    {"none","<none>"},{"unset","<none>"},{"esc","Escape"},{"bksp","Backspace"},{"del","Delete"},{"ins","Insert"},
    {"pgup","Page Up"},{"pgdn","Page Down"},{"pageup","Page Up"},{"pagedown","Page Down"},
    {"up","Up Arrow"},{"down","Down Arrow"},{"left","Left Arrow"},{"right","Right Arrow"},
    {"cmd","Command / Apple"},{"command","Command / Apple"},{"apple","Command / Apple"},
    {"lshift","Left Shift"},{"rshift","Right Shift"},{"lctrl","Left Control"},{"rctrl","Right Control"},
    {"lalt","Left Option"},{"ralt","Right Option"},{"lopt","Left Option"},{"ropt","Right Option"},
    {"shift","Left Shift"},{"ctrl","Left Control"},{"control","Left Control"},{"alt","Left Option"},{"option","Left Option"},
    {"minus","-"},{"equals","="},{"plus","Num +"},{"semicolon",";"},{"quote","'"},{"comma",","},{"period","."},
    {"slash","/"},{"backslash","\\"},{"backtick","`"},{"grave","`"},{"capslock","Caps Lock"},
    {"numenter","Enter"},{"keypadenter","Enter"},
};
#define NALIASES ((int)(sizeof ALIASES / sizeof ALIASES[0]))

// Lowercase and drop spaces/underscores so "Page Up", "page_up", "pageup" all match.
static void normalize(const char *s, char *out, size_t n) {
    size_t j = 0;
    for (; *s && j + 1 < n; s++) {
        if (*s == ' ' || *s == '_') continue;
        out[j++] = (char)tolower((unsigned char)*s);
    }
    out[j] = 0;
}

// Returns 1 and sets *b on success.
static int key_lookup(const char *s, unsigned char *b) {
    char q[64], t[64];
    normalize(s, q, sizeof q);
    if (!q[0]) return 0;
    for (int i = 0; i < NKEYS; i++) {
        const char *nm = KEYS[i].name;
        if (i == 0) nm = "none";          // "<none>" is spelled "none" on the command line
        normalize(nm, t, sizeof t);
        if (!strcmp(q, t)) { *b = KEYS[i].byte; return 1; }
    }
    for (int i = 0; i < NALIASES; i++)
        if (!strcmp(q, ALIASES[i].alias)) return key_lookup(ALIASES[i].name, b);
    if (!strcmp(q, "<none>")) { *b = 0xff; return 1; }
    return 0;
}

static const char *key_name(unsigned char b) {
    for (int i = 0; i < NKEYS; i++) if (KEYS[i].byte == b) return i == 0 ? "none" : KEYS[i].name;
    return b == 0 ? "(0x00: unset)" : "?";
}

// switch number (1-based) -> firmware input index; index 0 = no shift (0xFF)
static const int MAP5[] = {0xff, 8, 10, 12, 5, 3};
static const int MAP10[] = {0xff, 3, 1, 4, 16, 20, 8, 6, 2, 18, 22};

typedef struct {
    int ten;                       // hardware type: 0 = 5-switch, 1 = 10-switch
    int shift_sw;                  // 0 = none
    unsigned char normal[11], shifted[11];   // by switch number; 0xff = none
    int unset_default;             // value for unassigned switches (0xff for CLI)
    unsigned char macro[16];
} Config;

static int nswitches(const Config *c) { return c->ten ? 10 : 5; }

static void encode(const Config *c, unsigned char img[SIZE]) {
    const int *m = c->ten ? MAP10 : MAP5;
    memset(img, 0, SIZE);
    img[0] = (unsigned char)m[c->shift_sw];
    for (int n = 1; n <= nswitches(c); n++) {
        img[m[n]] = c->normal[n];
        img[m[n] + 28] = c->shifted[n];
    }
    unsigned sum = 0;
    for (int i = 0; i < OFF_CKSUM; i++) sum += img[i];
    img[OFF_CKSUM] = (unsigned char)sum;
    img[OFF_MODE] = 0;                 // permanent
    memcpy(img + OFF_MACRO, c->macro, 16);
}

static void config_init(Config *c) {
    memset(c, 0, sizeof *c);
    memset(c->normal, 0xff, sizeof c->normal);
    memset(c->shifted, 0xff, sizeof c->shifted);
    memset(c->macro, 0xff, sizeof c->macro);
}

static void print_image(const unsigned char *img) {
    for (int r = 0; r < 3; r++) {
        for (int i = 0; i < 32; i++) printf("%02x%s", img[r * 32 + i], i == 31 ? "\n" : " ");
    }
}

static void print_summary(const Config *c, const unsigned char *img) {
    const int *m = c->ten ? MAP10 : MAP5;
    printf("product      : %d-switch\n", nswitches(c));
    printf("shift switch : ");
    if (c->shift_sw) printf("%d (input %d)\n", c->shift_sw, m[c->shift_sw]); else printf("none (0xff)\n");
    for (int n = 1; n <= nswitches(c); n++)
        printf("switch %2d (input %2d): normal=0x%02x %-20s shifted=0x%02x %s\n", n, m[n],
               img[m[n]], key_name(img[m[n]]), img[m[n] + 28], key_name(img[m[n] + 28]));
    unsigned sum = 0;
    for (int i = 0; i < OFF_CKSUM; i++) sum += img[i];
    printf("checksum     : 0x%02x (computed 0x%02x)\n", img[OFF_CKSUM], sum & 0xff);
    printf("control mode : 0x%02x (permanent)\n", img[OFF_MODE]);
}

// ---- argument parsing ----------------------------------------------------------------------------

// Parse "key" or "normal/shifted".  Because "/" is itself a key, try the whole string first,
// then every '/' split point.
static int parse_assign(const char *v, unsigned char *nrm, unsigned char *shf) {
    unsigned char b;
    if (key_lookup(v, &b)) { *nrm = b; *shf = 0xff; return 1; }
    for (const char *p = v; *p; p++) {
        if (*p != '/') continue;
        char l[64], r[64];
        size_t ln = (size_t)(p - v);
        if (ln == 0 || ln >= sizeof l || strlen(p + 1) >= sizeof r) continue;
        memcpy(l, v, ln); l[ln] = 0; strcpy(r, p + 1);
        unsigned char a, s;
        if (key_lookup(l, &a) && key_lookup(r, &s)) { *nrm = a; *shf = s; return 1; }
    }
    return 0;
}

static void list_keys(void) {
    printf("Key names (case-insensitive; spaces/underscores optional):\n");
    for (int i = 0; i < NKEYS; i++) printf("  %-22s 0x%02x\n", i == 0 ? "none" : KEYS[i].name, KEYS[i].byte);
    printf("Aliases:");
    for (int i = 0; i < NALIASES; i++) printf(" %s", ALIASES[i].alias);
    printf("\n");
}

static int cfnum(CFTypeRef v, int def) {
    int x = def;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &x);
    return x;
}

// Mirror ssw_proto.py encode(): missing codes are 0, shift switch is the first with shift set.
static int load_ssconfig(const char *path, Config *c) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 0; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc((size_t)n + 1);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) { fclose(f); fprintf(stderr, "read error\n"); return 0; }
    fclose(f);
    CFDataRef d = CFDataCreate(NULL, buf, n); free(buf);
    CFErrorRef err = NULL;
    CFPropertyListRef pl = CFPropertyListCreateWithData(NULL, d, kCFPropertyListImmutable, NULL, &err);
    CFRelease(d);
    if (!pl || CFGetTypeID(pl) != CFDictionaryGetTypeID()) { fprintf(stderr, "%s: not a plist dictionary\n", path); return 0; }
    CFDictionaryRef top = pl;
    config_init(c);
    c->ten = cfnum(CFDictionaryGetValue(top, CFSTR("type")), 0) == 1;
    CFDictionaryRef sw = CFDictionaryGetValue(top, CFSTR("switches"));
    for (int k = 1; k <= nswitches(c); k++) {
        char key[8]; snprintf(key, sizeof key, "%d", k);
        CFStringRef ks = CFStringCreateWithCString(NULL, key, kCFStringEncodingASCII);
        CFDictionaryRef s = sw ? CFDictionaryGetValue(sw, ks) : NULL;
        CFRelease(ks);
        c->normal[k] = (unsigned char)(s ? cfnum(CFDictionaryGetValue(s, CFSTR("normalCode")), 0) : 0);
        c->shifted[k] = (unsigned char)(s ? cfnum(CFDictionaryGetValue(s, CFSTR("shiftedCode")), 0) : 0);
        if (s && cfnum(CFDictionaryGetValue(s, CFSTR("shift")), 0) && !c->shift_sw) c->shift_sw = k;
    }
    // The app takes the first shift switch in (unordered) dictionary order; we take the lowest number.
    CFDictionaryRef mac = CFDictionaryGetValue(top, CFSTR("macros"));
    static CFStringRef const fields[4] = {CFSTR("firstCode"), CFSTR("secondCode"), CFSTR("thirdCode"), CFSTR("fourthCode")};
    for (int i = 0; i < 4; i++) {
        char key[8]; snprintf(key, sizeof key, "%d", i + 1);
        CFStringRef ks = CFStringCreateWithCString(NULL, key, kCFStringEncodingASCII);
        CFDictionaryRef mm = mac ? CFDictionaryGetValue(mac, ks) : NULL;
        CFRelease(ks);
        for (int j = 0; j < 4; j++)
            c->macro[4 * i + j] = (unsigned char)(mm ? cfnum(CFDictionaryGetValue(mm, fields[j]), 0) : 0);
    }
    CFRelease(pl);
    return 1;
}

// ---- selftest ------------------------------------------------------------------------------------

static const unsigned char GOLD_PRTSC[SIZE] = {
    0xff,0,0,0xff,0,0xff,0,0,0x7f,0,0xff,0,0xff,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0xff,
    0,0xff,0,0,0xff,0,0xff,0,0xff,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0x75,0,0xff,0xff,0xff,0xff,0xff,
    0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
static const unsigned char GOLD_ABCDE[SIZE] = {
    0xff,0,0,0x24,0,0x23,0,0,0x1c,0,0x32,0,0x21,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0xff,
    0,0xff,0,0,0xff,0,0xff,0,0xff,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0xb0,0,0xff,0xff,0xff,0xff,0xff,
    0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};

static int selftest_one(const char *label, const char *const *assign, int na, const unsigned char *gold) {
    Config c; config_init(&c);
    for (int i = 0; i < na; i++) {
        int n = atoi(assign[i]); const char *eq = strchr(assign[i], '=');
        if (!eq || !parse_assign(eq + 1, &c.normal[n], &c.shifted[n])) { printf("selftest %s: bad assignment %s\n", label, assign[i]); return 0; }
    }
    unsigned char img[SIZE]; encode(&c, img);
    int ok = !memcmp(img, gold, SIZE);
    printf("selftest %-30s %s\n", label, ok ? "PASS" : "FAIL");
    if (!ok) { printf("got:\n"); print_image(img); printf("expected:\n"); print_image(gold); }
    return ok;
}

static int selftest(void) {
    const char *a1[] = {"1=printscreen"};
    const char *a2[] = {"1=a", "2=b", "3=c", "4=d", "5=e"};
    int ok = selftest_one("1=printscreen (cksum 0x75)", a1, 1, GOLD_PRTSC);
    ok &= selftest_one("1=a 2=b 3=c 4=d 5=e (0xb0)", a2, 5, GOLD_ABCDE);
    // Parser sanity: aliases, split, and "/" as a key.
    unsigned char n, s;
    int p = parse_assign("A/b", &n, &s) && n == 0x1c && s == 0x32;
    p &= parse_assign("/", &n, &s) && n == 0x4a && s == 0xff;
    p &= parse_assign("Page_Up", &n, &s) && n == 0xfd;
    p &= !parse_assign("bogus", &n, &s);
    printf("selftest %-30s %s\n", "key parser", p ? "PASS" : "FAIL");
    ok &= p;
    printf(ok ? "selftest: ALL PASS\n" : "selftest: FAILED\n");
    return ok ? 0 : 1;
}

// ---- device write --------------------------------------------------------------------------------

static int write_device(const unsigned char *img) {
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBDevice");
    int vid = 0x1324, pid = 0x0103;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberIntType, &vid), np = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR("idVendor"), nv); CFDictionarySetValue(m, CFSTR("idProduct"), np);
    CFRelease(nv); CFRelease(np);
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!svc) { fprintf(stderr, "error: StealthSwitch 3 (1324:0103) not found; is it plugged in?\n"); return 2; }

    IOCFPlugInInterface **plug = NULL; SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(svc);
    if (kr || !plug) { fprintf(stderr, "error: IOCreatePlugInInterfaceForService failed 0x%x\n", kr); return 2; }
    IOUSBDeviceInterface182 **dev = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (hr || !dev) { fprintf(stderr, "error: QueryInterface failed 0x%x\n", (int)hr); return 2; }

    kr = (*dev)->USBDeviceOpenSeize(dev);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "error: could not open/seize the device (0x%08x).\n"
                        "       Quit StealthSwitch3.app / RoboCon (anything else using the switch) and retry.\n", kr);
        (*dev)->Release(dev);
        return 2;
    }
    printf("device opened (seized)\n");

    int ok = 1;
    IOUSBDevRequestTO rq;
    memset(&rq, 0, sizeof rq);
    rq.bmRequestType = 0x43; rq.bRequest = 0xE9; rq.wValue = 1; rq.wIndex = 0; rq.wLength = 0;
    rq.noDataTimeout = 500; rq.completionTimeout = 1000;
    kr = (*dev)->DeviceRequestTO(dev, &rq);
    printf("start download      -> 0x%08x\n", kr);
    if (kr != kIOReturnSuccess) ok = 0;

    for (int blk = 0; ok && blk < 3; blk++) {
        unsigned char data[32], st = 0;
        memcpy(data, img + 32 * blk, 32);
        memset(&rq, 0, sizeof rq);
        rq.bmRequestType = 0x43; rq.bRequest = 0xEB; rq.wValue = 0; rq.wIndex = 0; rq.wLength = 32; rq.pData = data;
        rq.noDataTimeout = 500; rq.completionTimeout = 1000;
        kr = (*dev)->DeviceRequestTO(dev, &rq);
        printf("block %d send        -> 0x%08x (%u bytes)\n", blk, kr, rq.wLenDone);
        if (kr != kIOReturnSuccess) { ok = 0; break; }
        memset(&rq, 0, sizeof rq);
        rq.bmRequestType = 0xC3; rq.bRequest = 0xEA; rq.wValue = 0; rq.wIndex = 0; rq.wLength = 1; rq.pData = &st;
        rq.noDataTimeout = 500; rq.completionTimeout = 1000;
        kr = (*dev)->DeviceRequestTO(dev, &rq);
        printf("block %d status      -> 0x%08x status=0x%02x%s\n", blk, kr, st,
               st == 0x01 ? " (ok)" : st == 0x03 ? " (CHECKSUM ERROR)" : " (UNEXPECTED)");
        if (kr != kIOReturnSuccess || st != 0x01) ok = 0;
    }

    if (ok) {   // like the app, skip "end download" after an error
        memset(&rq, 0, sizeof rq);
        rq.bmRequestType = 0x43; rq.bRequest = 0xE9; rq.wValue = 0; rq.wIndex = 0; rq.wLength = 0;
        rq.noDataTimeout = 500; rq.completionTimeout = 1000;
        kr = (*dev)->DeviceRequestTO(dev, &rq);
        printf("end download        -> 0x%08x\n", kr);
        if (kr != kIOReturnSuccess) ok = 0;
    }
    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    printf(ok ? "programming SUCCEEDED\n" : "programming FAILED\n");
    return ok ? 0 : 1;
}

int main(int argc, char **argv) {
    Config c; config_init(&c);
    int write = 0, have_assign = 0;
    const char *ssconfig = NULL;
    int shift = 0;
    if (argc < 2) { fprintf(stderr, "usage: sswprog keys | --selftest | [--10] [--shift N] 1=<key> ... [--write] | --ssconfig file [--write]\n"); return 64; }
    if (!strcmp(argv[1], "keys")) { list_keys(); return 0; }
    if (!strcmp(argv[1], "--selftest")) return selftest();

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--write")) write = 1;
        else if (!strcmp(a, "--10")) c.ten = 1;
        else if (!strcmp(a, "--shift") && i + 1 < argc) shift = atoi(argv[++i]);
        else if (!strcmp(a, "--ssconfig") && i + 1 < argc) ssconfig = argv[++i];
        else if (isdigit((unsigned char)a[0]) && strchr(a, '=')) have_assign = 1;
        else { fprintf(stderr, "unrecognised argument: %s\n", a); return 64; }
    }
    if (ssconfig && (have_assign || c.ten || shift)) { fprintf(stderr, "--ssconfig cannot be combined with assignments, --10 or --shift\n"); return 64; }
    if (ssconfig) {
        if (!load_ssconfig(ssconfig, &c)) return 64;
    } else {
        for (int i = 1; i < argc; i++) {
            const char *a = argv[i];
            if (!(isdigit((unsigned char)a[0]) && strchr(a, '='))) { if (!strcmp(a, "--shift") || !strcmp(a, "--ssconfig")) i++; continue; }
            int n = atoi(a);
            if (n < 1 || n > nswitches(&c)) { fprintf(stderr, "switch %d out of range (1..%d%s)\n", n, nswitches(&c), c.ten ? "" : "; use --10 for the 10-switch product"); return 64; }
            if (!parse_assign(strchr(a, '=') + 1, &c.normal[n], &c.shifted[n])) {
                fprintf(stderr, "unknown key name in '%s' (see: sswprog keys)\n", a); return 64;
            }
        }
        if (shift < 0 || shift > nswitches(&c)) { fprintf(stderr, "--shift %d out of range (1..%d)\n", shift, nswitches(&c)); return 64; }
        c.shift_sw = shift;
    }

    unsigned char img[SIZE];
    encode(&c, img);
    printf("%s\n", write ? "image to send:" : "DRY RUN (nothing sent to the device); image:");
    print_image(img);
    print_summary(&c, img);
    if (!write) { printf("\nadd --write to program the device.\n"); return 0; }
    printf("\nabout to send the above image to StealthSwitch 3 (1324:0103)...\n");
    return write_device(img);
}
