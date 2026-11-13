#!/bin/sh
#
# Build an nginx that carries this module.  The continuous integration
# workflow runs this, and so can you:
#
#     ci/build.sh 1.30.6 /tmp/nginx-test
#     ci/tcpcheck.sh /tmp/nginx-test/sbin/nginx
#
# usage: ci/build.sh <nginx version> <install prefix>
#
# There is no dynamic mode.  The module reaches into nginx's own peer
# selection through the patch in patches/, so it is built into the binary;
# a loadable object cannot carry those hooks.
#
# nginx lands in $CI_WORK, ./ci-work by default.  Unlike the other
# repositories here the tree is NOT reused between runs: it gets patched,
# and patching an already patched tree is how you end up debugging the
# build instead of the module.  A warning from this module's own source
# fails the build.

set -eu

NGINX=${1:?nginx version missing}
PREFIX=${2:?install prefix missing}

SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${CI_WORK:-$SRC/ci-work}
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
PATCH=$SRC/patches/nginx-1.30+.patch

# Every version and digest comes from one file, so a run here pins exactly
# what a continuous integration run pins.  Deliberately not overridable
# from the environment: a version and the digest that proves it have to
# move together, and an override would separate them.
PINS=$SRC/.github/versions.env
[ -r "$PINS" ] || {
	echo "ci/build.sh: cannot read $PINS" >&2
	exit 1
}
# shellcheck source=../.github/versions.env
. "$PINS"

[ -r "$PATCH" ] || {
	echo "ci/build.sh: cannot read $PATCH" >&2
	exit 1
}

mkdir -p "$WORK"

tarball=$WORK/nginx-$NGINX.tar.gz
url=https://nginx.org/download/nginx-$NGINX.tar.gz

# The digest is looked up by version, so building another release means
# writing its pin down first.  A missing pin is refused rather than waved
# through: a check that skips itself when it has nothing to compare against
# is not a check, it only looks like one.
key=NGINX_$(echo "$NGINX" | tr . _)_SHA256
eval "want=\${$key:-}"
if [ -z "$want" ]; then
	echo "ci/build.sh: no sha256 for nginx $NGINX in $PINS" >&2
	echo "ci/build.sh: harvest one with" >&2
	echo "    ci/fetch-verify.sh $url - $tarball" >&2
	exit 1
fi

"$SRC/ci/fetch-verify.sh" "$url" "$want" "$tarball"

rm -rf "$WORK/nginx-$NGINX"
tar xzf "$tarball" -C "$WORK"

cd "$WORK/nginx-$NGINX"

# The hooks into round robin, hash, ip_hash and least_conn.  Every hunk is
# wrapped in #if (NGX_HTTP_UPSTREAM_CHECK), so a patched tree built without
# this module is the stock server.  --forward turns "already applied" into
# a refusal instead of a reversed patch; the tree is fresh, so it should
# never speak up.
echo "--- patch nginx $NGINX ---"
patch -p0 --forward < "$PATCH"

# --with-http_ssl_module is what the ssl_hello check type needs, and
# --with-stream keeps this nginx the same shape as the one every other
# repository here builds.
set --
if [ -n "${CI_CC_OPT:-}" ]; then
	set -- "$@" --with-cc-opt="$CI_CC_OPT"
fi
if [ -n "${CI_LD_OPT:-}" ]; then
	set -- "$@" --with-ld-opt="$CI_LD_OPT"
fi

echo "--- configure ---"
./configure --prefix="$PREFIX" --with-debug --with-http_ssl_module \
	--with-stream --add-module="$SRC" "$@" \
	> "$WORK/configure-$NGINX.log" 2>&1 ||
	{ tail -30 "$WORK/configure-$NGINX.log"; exit 1; }

echo "--- make -j$JOBS ---"
make -j"$JOBS" > "$WORK/make-$NGINX.log" 2>&1 ||
	{ tail -40 "$WORK/make-$NGINX.log"; exit 1; }

if grep -E "$SRC/src/.*warning" "$WORK/make-$NGINX.log"; then
	echo "ci/build.sh: the compiler warned about this module, see above" >&2
	exit 1
fi

make install > /dev/null
"$PREFIX/sbin/nginx" -v
