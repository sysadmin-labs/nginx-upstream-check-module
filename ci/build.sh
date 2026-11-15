#!/bin/sh
#
# Build an nginx that carries this module.  The continuous integration
# workflow runs this, and so can you:
#
#     ci/build.sh 1.30.6 /tmp/nginx-test
#     ci/tcpcheck.sh /tmp/nginx-test/sbin/nginx
#
# usage: ci/build.sh <version> <install prefix>
#
# A version that starts with "freenginx-" builds freenginx instead, from
# freenginx.org and with the freenginx patch.  It is not the same patch:
# freenginx branched before NGX_HTTP_UPSTREAM_SID and ngx_md5.h reached
# nginx's round robin, so the hooks go to the same places but their
# surroundings differ, and the nginx patch is refused there.
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
case $NGINX in
freenginx-*)
	SERVER=freenginx
	NGINX=${NGINX#freenginx-}
	PATCH=$SRC/patches/freenginx-1.30+.patch
	;;
*)
	SERVER=nginx
	PATCH=$SRC/patches/nginx-1.30+.patch
	;;
esac

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

tarball=$WORK/$SERVER-$NGINX.tar.gz
if [ "$SERVER" = freenginx ]; then
	url=https://freenginx.org/download/freenginx-$NGINX.tar.gz
else
	url=https://nginx.org/download/nginx-$NGINX.tar.gz
fi

# The digest is looked up by version, so building another release means
# writing its pin down first.  A missing pin is refused rather than waved
# through: a check that skips itself when it has nothing to compare against
# is not a check, it only looks like one.
if [ "$SERVER" = freenginx ]; then
	key=FREENGINX_$(echo "$NGINX" | tr . _)_SHA256
else
	key=NGINX_$(echo "$NGINX" | tr . _)_SHA256
fi
eval "want=\${$key:-}"
if [ -z "$want" ]; then
	echo "ci/build.sh: no sha256 for $SERVER $NGINX in $PINS" >&2
	echo "ci/build.sh: harvest one with" >&2
	echo "    ci/fetch-verify.sh $url - $tarball" >&2
	exit 1
fi

"$SRC/ci/fetch-verify.sh" "$url" "$want" "$tarball"

rm -rf "$WORK/$SERVER-$NGINX"
tar xzf "$tarball" -C "$WORK"

cd "$WORK/$SERVER-$NGINX"

# The hooks into round robin, hash, ip_hash and least_conn.  Every hunk is
# wrapped in #if (NGX_HTTP_UPSTREAM_CHECK), so a patched tree built without
# this module is the stock server.  --forward turns "already applied" into
# a refusal instead of a reversed patch; the tree is fresh, so it should
# never speak up.
echo "--- patch $SERVER $NGINX ---"
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
	> "$WORK/configure-$SERVER-$NGINX.log" 2>&1 ||
	{ tail -30 "$WORK/configure-$SERVER-$NGINX.log"; exit 1; }

echo "--- make -j$JOBS ---"
make -j"$JOBS" > "$WORK/make-$SERVER-$NGINX.log" 2>&1 ||
	{ tail -40 "$WORK/make-$SERVER-$NGINX.log"; exit 1; }

if grep -E "$SRC/src/.*warning" "$WORK/make-$SERVER-$NGINX.log"; then
	echo "ci/build.sh: the compiler warned about this module, see above" >&2
	exit 1
fi

make install > /dev/null
"$PREFIX/sbin/nginx" -v
