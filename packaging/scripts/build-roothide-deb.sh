#!/usr/bin/env bash
set -euo pipefail

# build-roothide-deb.sh — Build the Showcase RootHide package.
#
# RootHide packages use the iphoneos-arm64e architecture and rootful-style
# paths (no /var/jb prefix) because the dpkg runtime root is jbroot.
# The binaries reuse the rootless helper names (CarDisplaySim,
# "CarPlay Simulator") and the SHOWCASE_ROOTHIDE compile flag implies
# SHOWCASE_ROOTLESS so the app code finds resources through /var/jb.
#
# All binary manipulation (install_name_tool, ldid, dpkg-deb) happens on
# the jailbroken device, so this script runs on Linux/WSL/macOS.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
CONTROL_DIR="$ROOT/control-roothide"
CONTROL="$CONTROL_DIR/control"
PAYLOAD="$ROOT/payload"
BTSTACK_DYLIB="$PAYLOAD/usr/lib/libBTstack.dylib"
BTSTACK_DAEMON="$PAYLOAD/usr/bin/BTdaemon"
BTSTACK_SOURCE_DIR="$REPO_ROOT/btstack-rootless"
BTSTACK_SOURCE_BUILD="$BTSTACK_SOURCE_DIR/build_btdaemon.sh"
BTSTACK_PLIST="$PAYLOAD/Library/LaunchDaemons/ch.ringwald.BTstack.plist"
BUILD="$ROOT/build"
REMOTE_BASE="${REMOTE_BASE:-/tmp/showcase-roothide-deb-build}"
SDK_REMOTE="${SDK_REMOTE:-/var/jb/usr/share/SDKs/iPhoneOS.sdk}"

IPAD_HOST="${IPAD_HOST:-localhost}"
IPAD_PORT="${IPAD_PORT:-2222}"
IPAD_USER="${IPAD_USER:-mobile}"
IPAD_PASS="${IPAD_PASS:-alpine}"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o NumberOfPasswordPrompts=1
  -p "$IPAD_PORT"
)

SCP_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o NumberOfPasswordPrompts=1
  -P "$IPAD_PORT"
)

. "$ROOT/scripts/version.sh"

field() {
  awk -F': ' -v key="$1" '$1 == key { print $2; exit }' "$CONTROL"
}

need_file() {
  if [ ! -f "$1" ]; then
    echo "Missing file: $1"
    exit 1
  fi
}

PKG="$(field Package)"
VER="$PACKAGE_VERSION"
ARCH="$(field Architecture)"
DEB_NAME="${PKG}_${VER}_${ARCH}.deb"

need_file "$BTSTACK_DYLIB"
if [ ! -x "$BTSTACK_SOURCE_BUILD" ]; then
  need_file "$BTSTACK_DAEMON"
fi
need_file "$BTSTACK_PLIST"
need_file "$REPO_ROOT/source/Showcase.m"
need_file "$REPO_ROOT/source/carplay_bt.m"
need_file "$REPO_ROOT/source/carplay_services.m"
need_file "$REPO_ROOT/source/carplay_pair.c"
need_file "$REPO_ROOT/source/carplay_pair.h"
need_file "$REPO_ROOT/source/baa_broker.h"
need_file "$REPO_ROOT/source/vendor/monocypher/monocypher.c"
need_file "$REPO_ROOT/source/vendor/monocypher/monocypher-ed25519.c"
need_file "$REPO_ROOT/source/vendor/libtommath/tommath.c"
need_file "$REPO_ROOT/source/Info.plist"
need_file "$REPO_ROOT/source/ent_app.xml"
need_file "$REPO_ROOT/source/ent_bt.xml"
need_file "$REPO_ROOT/source/ent_btdaemon.xml"
need_file "$REPO_ROOT/source/ent_svc.xml"
need_file "$REPO_ROOT/icon/generated/Icon-OEM-104.png"
need_file "$REPO_ROOT/icon/generated/Icon-OEM-120.png"

sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "$IPAD_USER@$IPAD_HOST" "
set -e
test -d '$SDK_REMOTE'
command -v clang >/dev/null
command -v ldid >/dev/null
command -v dpkg-deb >/dev/null
command -v install_name_tool >/dev/null
"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/showcase-roothide.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mkdir -p \
  "$WORK/send" \
  "$WORK/rootfs/Applications/Showcase.app" \
  "$WORK/rootfs/usr/bin" \
  "$WORK/rootfs/usr/lib" \
  "$WORK/rootfs/usr/share/showcase" \
  "$WORK/rootfs/Library/LaunchDaemons" \
  "$WORK/rootfs/DEBIAN" \
  "$BUILD" \
  "$ROOT/repo/debs"

cp "$REPO_ROOT/source/Showcase.m" \
   "$REPO_ROOT/source/carplay_bt.m" \
   "$REPO_ROOT/source/carplay_services.m" \
   "$REPO_ROOT/source/carplay_pair.c" \
   "$REPO_ROOT/source/carplay_pair.h" \
   "$REPO_ROOT/source/baa_broker.h" \
   "$REPO_ROOT/source/Info.plist" \
   "$REPO_ROOT/source/ent_app.xml" \
   "$REPO_ROOT/source/ent_bt.xml" \
   "$REPO_ROOT/source/ent_btdaemon.xml" \
   "$REPO_ROOT/source/ent_svc.xml" \
   "$WORK/send/"
cp "$BTSTACK_DYLIB" "$WORK/send/libBTstack.dylib"
COPYFILE_DISABLE=1 tar --format ustar -C "$REPO_ROOT/source" \
  -cf "$WORK/send/crypto-vendor.tar" vendor
if [ -x "$BTSTACK_SOURCE_BUILD" ]; then
  COPYFILE_DISABLE=1 tar --format ustar -C "$BTSTACK_SOURCE_DIR" \
    -cf "$WORK/send/btstack-rootless.tar" .
fi

sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "$IPAD_USER@$IPAD_HOST" \
  "if [ \"\$(id -u)\" != 0 ]; then printf '%s\n' '$IPAD_PASS' | sudo -S rm -rf '$REMOTE_BASE'; else rm -rf '$REMOTE_BASE'; fi && mkdir -p '$REMOTE_BASE'"

sshpass -p "$IPAD_PASS" scp "${SCP_OPTS[@]}" \
  "$WORK/send/"* \
  "$IPAD_USER@$IPAD_HOST:$REMOTE_BASE/"

sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "$IPAD_USER@$IPAD_HOST" "
set -e
cd '$REMOTE_BASE'
tar -xf crypto-vendor.tar

if [ -f btstack-rootless.tar ]; then
    rm -rf btstack-rootless
    mkdir -p btstack-rootless
    tar -C btstack-rootless -xf btstack-rootless.tar
    chmod +x btstack-rootless/build_btdaemon.sh
    SDK='$SDK_REMOTE' ENT='$REMOTE_BASE/ent_btdaemon.xml' OUT='$REMOTE_BASE/BTdaemon' \
        btstack-rootless/build_btdaemon.sh
fi

# Compile with SHOWCASE_ROOTHIDE (implies SHOWCASE_ROOTLESS in source).
clang -fobjc-arc -DSHOWCASE_ROOTHIDE=1 -miphoneos-version-min=12.0 -isysroot '$SDK_REMOTE' \
    -DAPP_VERSION='\"$DISPLAY_VERSION\"' -o Showcase Showcase.m \
    -framework UIKit -framework AVFoundation -framework AudioToolbox \
    -framework CoreMedia -framework Foundation -framework Security \
    -Wl,-undefined,dynamic_lookup

clang -fobjc-arc -DSHOWCASE_ROOTHIDE=1 -miphoneos-version-min=12.0 -isysroot '$SDK_REMOTE' \
    -o carplay_bt carplay_bt.m \
    ./libBTstack.dylib \
    -framework Foundation -framework Security \
    -Wl,-undefined,dynamic_lookup

clang -fobjc-arc -DSHOWCASE_ROOTHIDE=1 -miphoneos-version-min=12.0 -isysroot '$SDK_REMOTE' \
    -o carplay_services carplay_services.m carplay_pair.c \
    vendor/monocypher/monocypher.c \
    vendor/monocypher/monocypher-ed25519.c \
    vendor/libtommath/tommath.c \
    -framework Foundation -framework Security \
    -Wl,-undefined,dynamic_lookup

# Fix dylib install name and the helper's reference to it.
# RootHide uses rootful-style paths inside the deb (jbroot is the dpkg root).
install_name_tool -id /usr/lib/libBTstack.dylib libBTstack.dylib
if otool -L carplay_bt | grep -Fq './libBTstack.dylib'; then
  install_name_tool -change './libBTstack.dylib' /usr/lib/libBTstack.dylib carplay_bt
fi
"

for bin in Showcase carplay_bt carplay_services; do
  sshpass -p "$IPAD_PASS" scp "${SCP_OPTS[@]}" \
    "$IPAD_USER@$IPAD_HOST:$REMOTE_BASE/$bin" \
    "$WORK/rootfs/Applications/Showcase.app/$bin"
done
if [ -x "$BTSTACK_SOURCE_BUILD" ]; then
  sshpass -p "$IPAD_PASS" scp "${SCP_OPTS[@]}" \
    "$IPAD_USER@$IPAD_HOST:$REMOTE_BASE/BTdaemon" \
    "$WORK/rootfs/usr/bin/BTdaemon"
fi
sshpass -p "$IPAD_PASS" scp "${SCP_OPTS[@]}" \
  "$IPAD_USER@$IPAD_HOST:$REMOTE_BASE/libBTstack.dylib" \
  "$WORK/rootfs/usr/lib/libBTstack.dylib"

# Rename helpers to the rootless-style names (avoids system process collisions).
mv "$WORK/rootfs/Applications/Showcase.app/carplay_bt" \
   "$WORK/rootfs/Applications/Showcase.app/CarDisplaySim"
mv "$WORK/rootfs/Applications/Showcase.app/carplay_services" \
   "$WORK/rootfs/Applications/Showcase.app/CarPlay Simulator"

fill_version "$REPO_ROOT/source/Info.plist" > "$WORK/rootfs/Applications/Showcase.app/Info.plist"
cp "$REPO_ROOT/source/ent_app.xml" "$WORK/rootfs/usr/share/showcase/ent_app.xml"
cp "$REPO_ROOT/source/ent_bt.xml" "$WORK/rootfs/usr/share/showcase/ent_bt.xml"
cp "$REPO_ROOT/source/ent_svc.xml" "$WORK/rootfs/usr/share/showcase/ent_svc.xml"
cp "$REPO_ROOT/source/ent_btdaemon.xml" "$WORK/rootfs/usr/share/showcase/ent_btdaemon.xml"
cp "$REPO_ROOT/icon/generated/"*.png "$WORK/rootfs/Applications/Showcase.app/"
rm -rf "$WORK/rootfs/Applications/Showcase.app/"*.lproj
cp -R "$REPO_ROOT/source/Localizations/"*.lproj "$WORK/rootfs/Applications/Showcase.app/"
if [ ! -x "$BTSTACK_SOURCE_BUILD" ]; then
  cp "$BTSTACK_DAEMON" "$WORK/rootfs/usr/bin/BTdaemon"
fi
# BTstack plist: RootHide uses rootful-style /usr/bin/BTdaemon path.
sed 's#/var/jb/usr/bin/BTdaemon#/usr/bin/BTdaemon#g' \
  "$BTSTACK_PLIST" > "$WORK/rootfs/Library/LaunchDaemons/ch.ringwald.BTstack.plist"

fill_version "$CONTROL" > "$WORK/rootfs/DEBIAN/control"
cp "$CONTROL_DIR/postinst" "$WORK/rootfs/DEBIAN/postinst"
cp "$CONTROL_DIR/prerm" "$WORK/rootfs/DEBIAN/prerm"
cp "$CONTROL_DIR/postrm" "$WORK/rootfs/DEBIAN/postrm"

find "$WORK/rootfs" -name '.DS_Store' -delete
find "$WORK/rootfs" -name '._*' -delete
xattr -cr "$WORK/rootfs" 2>/dev/null || true

COPYFILE_DISABLE=1 tar --format ustar -C "$WORK" -cf "$WORK/rootfs.tar" rootfs

sshpass -p "$IPAD_PASS" scp "${SCP_OPTS[@]}" \
  "$WORK/rootfs.tar" \
  "$IPAD_USER@$IPAD_HOST:$REMOTE_BASE/rootfs.tar"

sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "$IPAD_USER@$IPAD_HOST" "
set -e
if [ \"\$(id -u)\" != 0 ]; then
  printf '%s\n' '$IPAD_PASS' | sudo -S -v
fi
as_root() {
  if [ \"\$(id -u)\" = 0 ]; then
    \"\$@\"
  else
    sudo -n \"\$@\"
  fi
}
cd '$REMOTE_BASE'
rm -rf rootfs
tar xf rootfs.tar
cd rootfs
find . -name '._*' -delete
find . -name '.DS_Store' -delete

as_root chown root:wheel .
as_root chown -R root:wheel Applications usr Library DEBIAN
as_root chmod 0755 . Applications Applications/Showcase.app usr usr/bin usr/lib usr/share usr/share/showcase Library Library/LaunchDaemons
as_root chmod 0644 Applications/Showcase.app/Info.plist Applications/Showcase.app/Icon*.png
as_root chmod 0755 Applications/Showcase.app/*.lproj
as_root chmod 0644 Applications/Showcase.app/*.lproj/*
as_root chmod 0644 usr/share/showcase/ent_app.xml usr/share/showcase/ent_bt.xml usr/share/showcase/ent_svc.xml usr/share/showcase/ent_btdaemon.xml
as_root chmod 4755 Applications/Showcase.app/Showcase Applications/Showcase.app/CarDisplaySim 'Applications/Showcase.app/CarPlay Simulator'
as_root chmod 0755 usr/bin/BTdaemon usr/lib/libBTstack.dylib
as_root chmod 0644 Library/LaunchDaemons/ch.ringwald.BTstack.plist
as_root chmod 0755 DEBIAN/postinst DEBIAN/prerm DEBIAN/postrm
as_root chmod 0644 DEBIAN/control

as_root ldid -S'$REMOTE_BASE/ent_app.xml' Applications/Showcase.app/Showcase
as_root ldid -S'$REMOTE_BASE/ent_bt.xml'  Applications/Showcase.app/CarDisplaySim
as_root ldid -S'$REMOTE_BASE/ent_svc.xml' 'Applications/Showcase.app/CarPlay Simulator'
as_root ldid -S'$REMOTE_BASE/ent_btdaemon.xml' usr/bin/BTdaemon
as_root ldid -S usr/lib/libBTstack.dylib

find . -path ./DEBIAN -prune -o -type f -exec md5sum {} \; |
  as_root tee DEBIAN/md5sums >/dev/null
as_root chmod 0644 DEBIAN/md5sums

as_root dpkg-deb -Zgzip -z9 -b . '../$DEB_NAME'
dpkg-deb -I '../$DEB_NAME'
dpkg-deb -c '../$DEB_NAME' | sed -n '1,90p'
"

sshpass -p "$IPAD_PASS" scp "${SCP_OPTS[@]}" \
  "$IPAD_USER@$IPAD_HOST:$REMOTE_BASE/$DEB_NAME" \
  "$BUILD/$DEB_NAME"

cp "$BUILD/$DEB_NAME" "$ROOT/repo/debs/$DEB_NAME"

echo "Built $BUILD/$DEB_NAME"
echo "Copied repo payload to $ROOT/repo/debs/$DEB_NAME"
