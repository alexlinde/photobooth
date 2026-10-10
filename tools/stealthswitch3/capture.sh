#!/bin/bash
# capture.sh -- launch H-Mod StealthSwitch3.app with the passive USB tracer injected.
#
# Usage:  ./capture.sh [logfile]
#   logfile defaults to $SSW_LOG, else ./captures/ssw-<timestamp>.log next to this script.
#   App stdout/stderr (its printf/NSLog error messages) go to <logfile>.stdout.
#   Set SSW_TRACE_IOCONNECT=0 to suppress the low-level IOConnectCall* lines.
#
# The tracer only observes; every USB request in the log is one the app itself made.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_BIN="/Applications/StealthSwitch3.app/Contents/MacOS/StealthSwitch3"
DYLIB="$HERE/ssw_usbtrace.dylib"

if pgrep -x StealthSwitch3 >/dev/null 2>&1; then
    echo "capture.sh: StealthSwitch3 is already running (pid $(pgrep -x StealthSwitch3 | tr '\n' ' '))." >&2
    echo "            Quit it first; an already-running instance cannot be traced." >&2
    exit 1
fi
if pgrep -x RoboCon >/dev/null 2>&1; then
    echo "capture.sh: note: the RoboCon helper is running (pid $(pgrep -x RoboCon | tr '\n' ' ')). It is NOT traced;" >&2
    echo "            do not program from its menu-bar item during the capture." >&2
fi
[ -x "$APP_BIN" ] || { echo "capture.sh: $APP_BIN not found" >&2; exit 1; }
[ -f "$DYLIB" ] || { echo "capture.sh: $DYLIB not built (see build.sh)" >&2; exit 1; }
if ! lipo -archs "$DYLIB" 2>/dev/null | grep -qw x86_64; then
    echo "capture.sh: $DYLIB is not x86_64" >&2; exit 1
fi

LOG="${1:-${SSW_LOG:-}}"
if [ -z "$LOG" ]; then
    mkdir -p "$HERE/captures"
    LOG="$HERE/captures/ssw-$(date +%Y%m%d-%H%M%S).log"
fi
mkdir -p "$(dirname "$LOG")"
: >> "$LOG"
LOG="$(cd "$(dirname "$LOG")" && pwd)/$(basename "$LOG")"

echo "capture.sh: tracing to $LOG"
echo "capture.sh: app stdout/stderr -> $LOG.stdout"
echo "capture.sh: quit the app (Cmd-Q) to finish; then run:  python3 $HERE/ssw_proto.py decode-log \"$LOG\""

# Launch the Mach-O directly (not via `open`, which would drop DYLD_* variables).
# The app is x86_64-only, so this runs under Rosetta; the dylib must be x86_64.
SSW_LOG="$LOG" \
SSW_TRACE_IOCONNECT="${SSW_TRACE_IOCONNECT:-1}" \
DYLD_INSERT_LIBRARIES="$DYLIB" \
    "$APP_BIN" >>"$LOG.stdout" 2>&1 || true

if ! grep -q "ssw_usbtrace loaded" "$LOG"; then
    echo "capture.sh: WARNING: tracer banner missing from log -- DYLD_INSERT_LIBRARIES was not honoured." >&2
    echo "            Fall back to the lldb procedure in docs/stealthswitch3-protocol.md." >&2
    exit 2
fi
echo "capture.sh: done. $(grep -c 'DeviceRequest' "$LOG" || true) DeviceRequest log lines captured."
