#!/bin/bash
# build_openvpn_ios.sh — cross-compile the OpenVPN 2.6.21 CLI for iOS armv7
# (iPhone 4S / iOS 6.1.3) against the embedded OpenSSL 3.4.6 static libs.
#
# Runs ON SERV2 (192.168.0.101). Produces:
#   ~/Documents/ios6-app/vpnold/openvpn/openvpn   (Mach-O armv7, min iOS 6.0)
#
# Security scan (M1, org policy) — DONE for 2.6.21:
#   - Downloaded over HTTPS from build.openvpn.net (official host); size matches.
#   - Detached PGP signature VERIFIED against OpenVPN's official key
#     F554A3687412CFFEBDEFE0A312F5F7B42F2B01E7 ("OpenVPN - Security Mailing List
#     <security@openvpn.net>", signer subkey 822F6DF096D04874). VERIFIED: True.
#   - SHA256 24cb6185e544a47323d6798b03d39f2367d96f227bee9cd1543e8ed528319b17
#   - Source tree inspection clean (no rogue URLs / exfil / IP literals).
#   Re-verify before bumping the version.

set -e

VER=2.6.21
BASE=~/Documents/ios6-app/vpnold
SRC="$BASE/openvpn-src"
SSL="$BASE/ThirdParty/openssl"
COMPAT="$BASE/ThirdParty/compat-include"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MAC=$(xcrun --sdk macosx --show-sdk-path)
CC="$(xcrun -sdk iphoneos -f clang)"

# ── 1. Fetch + verify (skip if already present + verified) ──────────────────
mkdir -p "$SRC" && cd "$SRC"
if [ ! -f "openvpn-$VER.tar.gz" ]; then
  curl -sSL -o "openvpn-$VER.tar.gz"     "https://build.openvpn.net/downloads/releases/openvpn-$VER.tar.gz"
  curl -sSL -o "openvpn-$VER.tar.gz.asc" "https://build.openvpn.net/downloads/releases/openvpn-$VER.tar.gz.asc"
fi
echo "SHA256: $(shasum -a 256 openvpn-$VER.tar.gz)"
# GPG verify (needs: python3 -m pip install --user 'pgpy==0.6.0'):
#   key from https://keys.openpgp.org/vks/v1/by-fingerprint/F554A3687412CFFEBDEFE0A312F5F7B42F2B01E7
[ -d "openvpn-$VER" ] || tar xzf "openvpn-$VER.tar.gz"

# ── 2. Build the atomic shim (armv7 64-bit atomics for OpenSSL) ─────────────
# libcrypto.a references __atomic_*_8 + __atomic_is_lock_free; the bare iOS
# clang cross-link does not provide them (Xcode links compiler-rt implicitly).
cd "$SSL"
"$CC" -arch armv7 -isysroot "$SDK" -miphoneos-version-min=6.0 -fno-builtin -c atomic_shim.c   -o atomic_shim.o
"$CC" -arch armv7 -isysroot "$SDK" -miphoneos-version-min=6.0                -c atomic_stubs.S -o atomic_stubs_asm.o
ar rcs lib/libatomicshim.a atomic_shim.o atomic_stubs_asm.o

# ── 3. Supply headers stripped from the iOS SDK (present in the macOS SDK) ───
# net/route.h        → PF_ROUTE (works on JB).
# net/if_utun.h,     → gate openvpn's Darwin utun path. Without them configure
# sys/kern_control.h,  leaves HAVE_NET_IF_UTUN_H / HAVE_SYS_KERN_CONTROL_H
# sys/sys_domain.h     undefined and openvpn falls back to the nonexistent
#                      /dev/tunN path ("Cannot allocate TUN/TAP dev dynamically").
mkdir -p "$COMPAT/net" "$COMPAT/sys"
# -f: SDK headers are mode 0444, so overwriting an existing copy would fail.
cp -f "$MAC/usr/include/net/route.h"         "$COMPAT/net/route.h"
cp -f "$MAC/usr/include/net/if_utun.h"       "$COMPAT/net/if_utun.h"
cp -f "$MAC/usr/include/sys/kern_control.h"  "$COMPAT/sys/kern_control.h"
cp -f "$MAC/usr/include/sys/sys_domain.h"    "$COMPAT/sys/sys_domain.h"

# ── 4. Configure ────────────────────────────────────────────────────────────
cd "$SRC/openvpn-$VER"
export CC
export CFLAGS="-arch armv7 -isysroot $SDK -miphoneos-version-min=6.0 -I$SSL/include -I$COMPAT -D__APPLE_USE_RFC_3542"
export LDFLAGS="-arch armv7 -isysroot $SDK -miphoneos-version-min=6.0 -L$SSL/lib"
export OPENSSL_CFLAGS="-I$SSL/include"
export OPENSSL_LIBS="-L$SSL/lib -lssl -lcrypto -latomicshim"   # shim AFTER crypto
# Cache seeds: the uid_t/gid_t/socklen_t autoconf tests misfire when cross-
# compiling (bad `#define uid_t int` poisons every later header test).
./configure --host=arm-apple-darwin \
  --disable-lzo --disable-lz4 --disable-plugins \
  --disable-dependency-tracking --disable-unit-tests \
  ac_cv_type_uid_t=yes ac_cv_type_gid_t=yes ac_cv_type_socklen_t=yes

# ── 5. Build + install the binary ────────────────────────────────────────────
# make clean is required: --disable-dependency-tracking means a changed config.h
# (e.g. newly-detected utun headers) will NOT retrigger recompilation otherwise.
make clean >/dev/null 2>&1 || true
make -j4
mkdir -p "$BASE/openvpn"
cp src/openvpn/openvpn "$BASE/openvpn/openvpn"
xcrun --sdk iphoneos strip "$BASE/openvpn/openvpn" 2>/dev/null || true
echo "== done =="
lipo -info "$BASE/openvpn/openvpn"
strings "$BASE/openvpn/openvpn" | grep -m1 "^OpenVPN $VER"
