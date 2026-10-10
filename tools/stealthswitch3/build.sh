#!/bin/bash
# build.sh -- build the tracer dylib and read-only test program (x86_64), and the universal sswprog programmer.
set -euo pipefail
cd "$(dirname "$0")"
clang -arch x86_64 -dynamiclib -O1 -g -Wall -Wno-unused-function \
    -o ssw_usbtrace.dylib ssw_usbtrace.c ssw_tramp.s -framework IOKit -framework CoreFoundation
clang -arch x86_64 -Wall -Wno-deprecated-declarations \
    -o ssw_readonly_test ssw_readonly_test.c -framework IOKit -framework CoreFoundation
clang -arch arm64 -arch x86_64 -Wall -Wno-deprecated-declarations \
    -o sswprog sswprog.c -framework IOKit -framework CoreFoundation
echo "built: $(pwd)/ssw_usbtrace.dylib $(pwd)/ssw_readonly_test $(pwd)/sswprog"
echo "test:  SSW_LOG=\$PWD/test.log DYLD_INSERT_LIBRARIES=\$PWD/ssw_usbtrace.dylib ./ssw_readonly_test && cat test.log"
