#!/usr/bin/env python3
"""ssw_proto.py -- offline model of the StealthSwitch3 programming protocol (as recovered
statically from StealthSwitch3.app 2.1).  Sends NOTHING to any device.

  ssw_proto.py encode <file.ssconfig> [--hw 0|1] [--volatile]
      Build the 96-byte config image the app would send for a saved configuration and
      print it together with the control-request sequence.
  ssw_proto.py decode-log <capture.log>
      Pull the vendor requests out of an ssw_usbtrace log, reassemble the 96-byte image(s),
      verify the checksum and decode them.
  ssw_proto.py decode-hex <192 hex chars>
"""
import plistlib, re, sys

# Name table recovered from the app (address 0x1000143e0, 125 entries {NSString*, uint32}).
# Values are PS/2 Scan Code Set 2 make codes; E0-prefixed keys are stored as 0x80 | (code & 0x7f).
KEYS = [
    ('<none>', 0xff), ('A', 0x1c), ('B', 0x32), ('C', 0x21), ('D', 0x23), ('E', 0x24), ('F', 0x2b), ('G', 0x34),
    ('H', 0x33), ('I', 0x43), ('J', 0x3b), ('K', 0x42), ('L', 0x4b), ('M', 0x3a), ('N', 0x31), ('O', 0x44),
    ('P', 0x4d), ('Q', 0x15), ('R', 0x2d), ('S', 0x1b), ('T', 0x2c), ('U', 0x3c), ('V', 0x2a), ('W', 0x1d),
    ('X', 0x22), ('Y', 0x35), ('Z', 0x1a), ('1', 0x16), ('2', 0x1e), ('3', 0x26), ('4', 0x25), ('5', 0x2e),
    ('6', 0x36), ('7', 0x3d), ('8', 0x3e), ('9', 0x46), ('0', 0x45), ('Home', 0xe06c), ('End', 0xe069),
    ('Page Up', 0xe07d), ('Page Down', 0xe07a), ('Up Arrow', 0xe075), ('Down Arrow', 0xe072),
    ('Left Arrow', 0xe06b), ('Right Arrow', 0xe074), ('Left Mouse Click', 0xd0), ('Right Mouse Click', 0xd3),
    ('Middle Mouse Click', 0xd1), ('Double Click', 0xe8), ('Left Mouse Toggle', 0xd6),
    ('Middle Mouse Toggle', 0xd7), ('Return', 0x5a), ('Enter', 0xe05a), ('Escape', 0x76), ('Insert', 0xe070),
    ('Delete', 0xe071), ('Backspace', 0x66), ('Caps Lock', 0x58), ('Tab', 0x0d), ('Print Screen', 0x7f),
    ('Space', 0x29), ('-', 0x4e), ('=', 0x55), ('[', 0x54), (']', 0x5b), ('\\', 0x5d), (';', 0x4c), ("'", 0x52),
    ('`', 0x0e), (',', 0x41), ('.', 0x49), ('/', 0x4a), ('Command / Apple', 0xe01f), ('Left Shift', 0x12),
    ('Left Control', 0x14), ('Left Option', 0x11), ('Right Shift', 0x59), ('Right Control', 0xe014),
    ('Right Option', 0xe011), ('Shift Toggle', 0xde), ('Control Toggle', 0xdc), ('Option Toggle', 0xdf),
    ('F1', 0x05), ('F2', 0x06), ('F3', 0x04), ('F4', 0x0c), ('F5', 0x03), ('F6', 0x0b), ('F7', 0x83), ('F8', 0x0a),
    ('F9', 0x01), ('F10', 0x09), ('F11', 0x78), ('F12', 0x07), ('Num /', 0xe04a), ('Num *', 0x7c), ('Num -', 0x7b),
    ('Num +', 0x79), ('Num =', 0x0f), ('Num 1', 0x69), ('Num 2', 0x72), ('Num 3', 0x7a), ('Num 4', 0x6b),
    ('Num 5', 0x73), ('Num 6', 0x74), ('Num 7', 0x6c), ('Num 8', 0x75), ('Num 9', 0x7d), ('Num 0', 0x70),
    ('Num .', 0x71), ('Key Macro 1', 0xe0), ('Key Macro 2', 0xe1), ('Key Macro 3', 0xe2), ('Key Macro 4', 0xe3),
    ('H-Mod Shift Toggle', 0xe7),
]
def byte_of(code):
    return ((code & 0x7f) | 0x80) if (code & 0xffffff00) == 0xe000 else code & 0xff
BYTE2NAME = {}
for n, c in KEYS:
    BYTE2NAME.setdefault(byte_of(c), n)
BYTE2NAME.setdefault(0x00, '(0x00: unset)')

# switch number (1-based, as in the UI / .ssconfig) -> firmware input index (1..28)
SWITCH_MAP = {0: [0xff, 8, 10, 12, 5, 3], 1: [0xff, 3, 1, 4, 16, 20, 8, 6, 2, 18, 22]}
NIN = 28
OFF_SHIFT, OFF_NORMAL, OFF_SHIFTED, OFF_CKSUM, OFF_MODE, OFF_MACRO, SIZE = 0, 0, 28, 57, 58, 59, 96

def checksum(img):
    return sum(img[0:57]) & 0xff

def encode(cfg, hw, volatile=False):
    img = bytearray(SIZE)
    sw = cfg.get('switches', {})
    shift_sw = 0
    for k, v in sw.items():
        if v.get('shift'):
            shift_sw = int(k)  # app takes the first one found in dictionary order
            break
    m = SWITCH_MAP[hw]
    img[0] = m[shift_sw] if shift_sw < len(m) else 0
    for n in range(1, len(m)):
        s = sw.get(str(n))
        idx = m[n]
        img[idx] = (s or {}).get('normalCode', 0) & 0xff
        img[idx + 28] = (s or {}).get('shiftedCode', 0) & 0xff
    img[OFF_CKSUM] = checksum(img)
    img[OFF_MODE] = 0
    mac = cfg.get('macros', {})
    for i in range(4):
        mm = mac.get(str(i + 1), {})
        for j, k in enumerate(('firstCode', 'secondCode', 'thirdCode', 'fourthCode')):
            img[OFF_MACRO + 4 * i + j] = mm.get(k, 0) & 0xff
    img[OFF_MODE] = 4 if volatile else 0  # programConfiguration:permanent: overwrites byte 58
    return bytes(img)

def nm(b):
    return '0x%02x %s' % (b, BYTE2NAME.get(b, '?'))

def describe(img, hw=None):
    out = []
    out.append('shift input index : %s' % ('0x%02x' % img[0] + (' (none)' if img[0] == 0xff else '')))
    for i in range(1, NIN + 1):
        a, b = img[i], img[i + 28]
        if a or b:
            sws = ['%s#%d' % ('5sw' if h == 0 else '10sw', n) for h, mp in SWITCH_MAP.items() if hw in (None, h) for n in range(1, len(mp)) if mp[n] == i]
            out.append('input %2d (switch %s): normal=%-28s shifted=%s' % (i, '/'.join(sws) or '-', nm(a), nm(b)))
    ok = checksum(img) == img[OFF_CKSUM]
    out.append('checksum byte 57  : 0x%02x (computed 0x%02x) %s' % (img[57], checksum(img), 'OK' if ok else 'MISMATCH'))
    out.append('control mode 58   : 0x%02x %s' % (img[58], {0: '(permanent)', 4: '(volatile? permanent:NO)'}.get(img[58], '(unknown)')))
    for i in range(4):
        out.append('macro %d           : %s' % (i + 1, ', '.join(nm(x) for x in img[59 + 4 * i: 63 + 4 * i])))
    tail = img[75:96]
    out.append('bytes 75..95      : %s' % ('all zero' if not any(tail) else tail.hex(' ')))
    return '\n'.join(out)

def sequence(img):
    s = ['DeviceRequestTO bmRequestType=0x43 bRequest=0xE9 wValue=0x0001 wIndex=0 wLength=0   (start download)']
    for blk in range(3):
        s.append('DeviceRequestTO bmRequestType=0x43 bRequest=0xEB wValue=0x0000 wIndex=0 wLength=32  data=%s' % img[32 * blk:32 * blk + 32].hex(' '))
        s.append('DeviceRequestTO bmRequestType=0xC3 bRequest=0xEA wValue=0x0000 wIndex=0 wLength=1   (status; expect 01)')
    s.append('DeviceRequestTO bmRequestType=0x43 bRequest=0xE9 wValue=0x0000 wIndex=0 wLength=0   (end download)')
    return '\n'.join(s)

def decode_log(path):
    lines = open(path, errors='replace').read().splitlines()
    reqs, cur = [], None
    for ln in lines:
        m = re.search(r'#(\d+) (DEV|IF) (\w+) self=\S+ (?:pipe=\d+ )?SETUP bmRequestType=0x(\w\w) .*?bRequest=0x(\w\w) wValue=0x(\w{4}) wIndex=0x(\w{4}) wLength=(\d+)', ln)
        if m:
            cur = dict(seq=m.group(1), fn=m.group(3), bm=int(m.group(4), 16), br=int(m.group(5), 16), wv=int(m.group(6), 16),
                       wi=int(m.group(7), 16), wl=int(m.group(8)), out=bytearray(), inn=bytearray(), ret=None)
            reqs.append(cur); continue
        m = re.search(r'#(\d+) (?:DEV|IF) \w+ -> (0x\w+) (\S+) wLenDone=(\d+)', ln)
        if m and cur and m.group(1) == cur['seq']:
            cur['ret'] = m.group(2) + ' ' + m.group(3); continue
        m = re.search(r'    (OUT|IN )\[\w+\]: ([0-9a-f ]+)', ln)
        if m and cur:
            (cur['out'] if m.group(1) == 'OUT' else cur['inn']).extend(bytes.fromhex(m.group(2)))
    img, imgs = bytearray(), []
    for r in reqs:
        if r['bm'] & 0x60 == 0:
            continue  # standard requests (descriptor reads) -- skip in the summary
        print('#%s %s bm=0x%02x req=0x%02x wValue=0x%04x wIndex=0x%04x wLength=%d -> %s %s%s' % (
            r['seq'], r['fn'], r['bm'], r['br'], r['wv'], r['wi'], r['wl'], r['ret'],
            ('OUT ' + r['out'].hex(' ')) if r['out'] else '', ('IN ' + r['inn'].hex(' ')) if r['inn'] else ''))
        if r['bm'] == 0x43 and r['br'] == 0xE9 and r['wv'] == 1:
            img = bytearray()
        elif r['bm'] == 0x43 and r['br'] == 0xEB:
            img.extend(r['out'])
        elif r['bm'] == 0x43 and r['br'] == 0xE9 and r['wv'] == 0:
            imgs.append(bytes(img))
    for k, im in enumerate(imgs):
        print('\n=== download %d: %d bytes ===' % (k + 1, len(im)))
        print(im.hex(' '))
        if len(im) == SIZE:
            print(describe(im))
    if not imgs:
        print('(no complete 0xE9/0xEB.../0xE9 download sequence found)')

def main(a):
    if len(a) >= 2 and a[0] == 'encode':
        cfg = plistlib.load(open(a[1], 'rb'))
        hw = int(a[a.index('--hw') + 1]) if '--hw' in a else (1 if cfg.get('type') == 1 else 0)
        img = encode(cfg, hw, '--volatile' in a)
        print('product type %s -> hardware type %d' % (cfg.get('type'), hw))
        print(img.hex(' ')); print(describe(img, hw)); print(); print(sequence(img))
    elif len(a) == 2 and a[0] == 'decode-log':
        decode_log(a[1])
    elif len(a) == 2 and a[0] == 'decode-hex':
        print(describe(bytes.fromhex(a[1])))
    else:
        print(__doc__); return 1
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
