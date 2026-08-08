#!/usr/bin/env bash
set -euo pipefail

SRC=${1:?source directory required}
RULES="$SRC/debian/rules"
CONFIGURE="$SRC/configure"

[[ -f "$RULES" ]] || { echo "libxi hook: missing debian/rules" >&2; exit 2; }
[[ -f "$CONFIGURE" ]] || { echo "libxi hook: missing configure" >&2; exit 2; }

# libXi uses XORG_CHECK_MALLOC_ZERO.  In auto mode that macro executes a target
# binary, which cannot run during this arm64 -> armhf cross-build.  Debian's
# ARMHF target uses glibc, for which the macro's combined malloc/realloc/calloc
# zero-size test evaluates yes (realloc(p, 0) returns NULL).  Preseed the X.Org
# cache variable rather than disabling cross compilation or executing ARMHF
# configure probes on the 16K host.
grep -q 'xorg_cv_malloc0_returns_null' "$CONFIGURE" || {
    echo "libxi hook: configure no longer contains xorg_cv_malloc0_returns_null" >&2
    exit 2
}

if ! grep -Eq '^export[[:space:]]+xorg_cv_malloc0_returns_null[[:space:]]*=' "$RULES"; then
    cat >>"$RULES" <<'EOF'

# ARMHF16K cross-build: XORG_CHECK_MALLOC_ZERO cannot execute target probes.
export xorg_cv_malloc0_returns_null = yes
EOF
    echo "ARMHF16K libxi hook: preseeded xorg_cv_malloc0_returns_null=yes"
else
    echo "ARMHF16K libxi hook: malloc(0) cross-build cache already configured"
fi
