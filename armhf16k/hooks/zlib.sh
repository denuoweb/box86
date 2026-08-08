#!/usr/bin/env bash
set -euo pipefail

SRC=${1:?source directory required}
RULES="$SRC/debian/rules"

python3 - "$RULES" <<'PY'
from pathlib import Path
import sys

rules = Path(sys.argv[1])
text = rules.read_text()
old = 'cd contrib/minizip && autoreconf -fis && CFLAGS="$(CFLAGS)" LDFLAGS="$(LDFLAGS)" uname=GNU ./configure --prefix=/usr --libdir=$${prefix}/lib/$(DEB_HOST_MULTIARCH)'
new = 'cd contrib/minizip && autoreconf -fis && CC="$(DEB_HOST_GNU_TYPE)-gcc" AR="$(AR)" CFLAGS="$(CFLAGS)" LDFLAGS="$(LDFLAGS)" uname=GNU ./configure --build=$(DEB_BUILD_GNU_TYPE) --host=$(DEB_HOST_GNU_TYPE) --prefix=/usr --libdir=$${prefix}/lib/$(DEB_HOST_MULTIARCH)'

if old not in text:
    raise SystemExit('zlib hook: expected contrib/minizip configure line not found')

rules.write_text(text.replace(old, new, 1))
print('ARMHF16K zlib hook: forced contrib/minizip ARMHF cross configuration')
PY
