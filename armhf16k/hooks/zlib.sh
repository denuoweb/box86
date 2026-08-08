#!/usr/bin/env bash
set -euo pipefail

SRC=${1:?source directory required}
RULES="$SRC/debian/rules"

python3 - "$RULES" <<'PY'
from pathlib import Path
import sys

rules = Path(sys.argv[1])
lines = rules.read_text().splitlines(keepends=True)
matched = 0
changed = 0
out = []

for line in lines:
    if "cd contrib/minizip" in line and "./configure" in line:
        matched += 1
        new = line

        # Debian's main zlib configure explicitly selects the target compiler,
        # but the minizip subproject historically omitted it. Preserve the
        # package's existing flags/path quoting and add only cross-build data.
        if 'CC="$(DEB_HOST_GNU_TYPE)-gcc"' not in new:
            marker = 'CFLAGS="$(CFLAGS)"'
            if marker not in new:
                raise SystemExit("zlib hook: minizip configure line lacks expected CFLAGS assignment")
            new = new.replace(
                marker,
                'CC="$(DEB_HOST_GNU_TYPE)-gcc" AR="$(AR)" ' + marker,
                1,
            )

        if '--host=$(DEB_HOST_GNU_TYPE)' not in new:
            marker = './configure '
            if marker not in new:
                raise SystemExit("zlib hook: minizip configure invocation not recognized")
            new = new.replace(
                marker,
                './configure --build=$(DEB_BUILD_GNU_TYPE) --host=$(DEB_HOST_GNU_TYPE) ',
                1,
            )

        if new != line:
            changed += 1
        out.append(new)
    else:
        out.append(line)

if matched != 1:
    raise SystemExit(f"zlib hook: expected exactly one contrib/minizip configure line, found {matched}")

rules.write_text(''.join(out))
print(f"ARMHF16K zlib hook: minizip cross configuration verified ({changed} line changed)")
PY
