#!/usr/bin/env bash
# build-cross-roothide.sh — Cross-compile the Showcase RootHide package on macOS.
#
# Uses Xcode's iPhoneOS SDK to compile all components for arm64e, then signs
# with ldid and packages with dpkg-deb. No jailbroken device required.
#
# Prerequisites (macOS):
#   - Xcode (xcode-select --install)
#   - brew install ldid dpkg
#
# Usage:
#   ./packaging/scripts/build-cross-roothide.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
CONTROL_DIR="$ROOT/control-roothide"
CONTROL="$CONTROL_DIR/control"
BTSTACK_ROOT="$REPO_ROOT/btstack-rootless"
BUILD="$ROOT/build-cross"
WORK="$BUILD/work"
STAGE="$WORK/stage"

# ── Toolchain ──────────────────────────────────────────────────────────
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
ARCH="arm64e"
MIN_IOS="12.0"

CFLAGS_COMMON=(
  -isysroot "$SDKROOT"
  -arch "$ARCH"
  -mios-version-min="$MIN_IOS"
  -fobjc-arc
  -Wl,-undefined,dynamic_lookup
  -Wl,-not_for_dyld_shared_cache
)

. "$ROOT/scripts/version.sh"

field() { awk -F': ' -v key="$1" '$1 == key { print $2; exit }' "$CONTROL"; }

PKG="$(field Package)"
ARCH_PKG="$(field Architecture)"
DEB_NAME="${PKG}_${PACKAGE_VERSION}_${ARCH_PKG}.deb"

echo "═══════════════════════════════════════════════════════════"
echo "Showcase RootHide — cross build"
echo "SDK: $SDKROOT"
echo "Version: $PACKAGE_VERSION ($DISPLAY_VERSION)"
echo "Output: $BUILD/$DEB_NAME"
echo "═══════════════════════════════════════════════════════════"

rm -rf "$WORK"
mkdir -p \
  "$STAGE/Applications/Showcase.app" \
  "$STAGE/usr/bin" \
  "$STAGE/usr/lib" \
  "$STAGE/usr/share/showcase" \
  "$STAGE/Library/LaunchDaemons" \
  "$STAGE/DEBIAN" \
  "$BUILD"

# ── 1. Build libBTstack.dylib ──────────────────────────────────────────
echo ""
echo "[1/6] Building libBTstack.dylib"
BTSTACK_OBJDIR="$WORK/btstack-obj"
mkdir -p "$BTSTACK_OBJDIR"

BTSTACK_C_SOURCES=(
  "$BTSTACK_ROOT/src/ad_parser.c"
  "$BTSTACK_ROOT/src/btstack_linked_list.c"
  "$BTSTACK_ROOT/src/btstack_memory.c"
  "$BTSTACK_ROOT/src/btstack_memory_pool.c"
  "$BTSTACK_ROOT/src/btstack_run_loop.c"
  "$BTSTACK_ROOT/src/btstack_run_loop_base.c"
  "$BTSTACK_ROOT/src/btstack_tlv.c"
  "$BTSTACK_ROOT/src/btstack_util.c"
  "$BTSTACK_ROOT/src/hci.c"
  "$BTSTACK_ROOT/src/hci_cmd.c"
  "$BTSTACK_ROOT/src/hci_dump.c"
  "$BTSTACK_ROOT/src/l2cap.c"
  "$BTSTACK_ROOT/src/l2cap_signaling.c"
  "$BTSTACK_ROOT/src/classic/rfcomm.c"
  "$BTSTACK_ROOT/src/classic/sdp_client.c"
  "$BTSTACK_ROOT/src/classic/sdp_client_rfcomm.c"
  "$BTSTACK_ROOT/src/classic/sdp_server.c"
  "$BTSTACK_ROOT/src/classic/sdp_util.c"
  "$BTSTACK_ROOT/src/classic/spp_server.c"
  "$BTSTACK_ROOT/src/classic/btstack_link_key_db_tlv.c"
)

BTSTACK_INCLUDES=(
  -I"$BTSTACK_ROOT/src"
  -I"$BTSTACK_ROOT/platform/posix"
  -I"$BTSTACK_ROOT/platform/corefoundation"
  -I"$BTSTACK_ROOT/platform/daemon/src"
  -I"$BTSTACK_ROOT/port/ios"
  -I"$BTSTACK_ROOT/port/ios/src"
)

for src in "${BTSTACK_C_SOURCES[@]}"; do
  obj="$BTSTACK_OBJDIR/$(basename "${src%.c}.o")"
  "$CLANG" -c "${CFLAGS_COMMON[@]}" -fno-objc-arc \
    "${BTSTACK_INCLUDES[@]}" \
    -O2 -Wno-deprecated-declarations -Wno-incompatible-pointer-types \
    -Wno-pointer-sign -Wno-unused-command-line-argument \
    "$src" -o "$obj"
done

# Link dylib with install name /usr/lib/libBTstack.dylib (rootful-style
# path; RootHide dpkg root is jbroot).
"$CLANG" -dynamiclib \
  -isysroot "$SDKROOT" -arch "$ARCH" -mios-version-min="$MIN_IOS" \
  -install_name /usr/lib/libBTstack.dylib \
  -framework Foundation -framework CoreFoundation \
  -Wl,-undefined,dynamic_lookup \
  -Wl,-not_for_dyld_shared_cache \
  "$BTSTACK_OBJDIR"/*.o \
  -o "$STAGE/usr/lib/libBTstack.dylib"
echo "       -> libBTstack.dylib built"

# ── 2. Build BTdaemon ──────────────────────────────────────────────────
echo ""
echo "[2/6] Building BTdaemon"
BTD_OBJDIR="$WORK/btd-obj"
mkdir -p "$BTD_OBJDIR"

BTD_C_SOURCES=(
  "$BTSTACK_ROOT/src/ad_parser.c"
  "$BTSTACK_ROOT/src/btstack_linked_list.c"
  "$BTSTACK_ROOT/src/btstack_memory.c"
  "$BTSTACK_ROOT/src/btstack_memory_pool.c"
  "$BTSTACK_ROOT/src/btstack_run_loop.c"
  "$BTSTACK_ROOT/src/btstack_run_loop_base.c"
  "$BTSTACK_ROOT/src/btstack_tlv.c"
  "$BTSTACK_ROOT/src/btstack_util.c"
  "$BTSTACK_ROOT/src/hci.c"
  "$BTSTACK_ROOT/src/hci_cmd.c"
  "$BTSTACK_ROOT/src/hci_dump.c"
  "$BTSTACK_ROOT/src/l2cap.c"
  "$BTSTACK_ROOT/src/l2cap_signaling.c"
  "$BTSTACK_ROOT/src/classic/rfcomm.c"
  "$BTSTACK_ROOT/src/classic/sdp_client.c"
  "$BTSTACK_ROOT/src/classic/sdp_client_rfcomm.c"
  "$BTSTACK_ROOT/src/classic/sdp_server.c"
  "$BTSTACK_ROOT/src/classic/sdp_util.c"
  "$BTSTACK_ROOT/src/classic/spp_server.c"
  "$BTSTACK_ROOT/src/classic/btstack_link_key_db_tlv.c"
  "$BTSTACK_ROOT/platform/daemon/src/btstack.c"
  "$BTSTACK_ROOT/platform/daemon/src/daemon.c"
  "$BTSTACK_ROOT/platform/daemon/src/daemon_cmds.c"
  "$BTSTACK_ROOT/platform/daemon/src/socket_connection.c"
  "$BTSTACK_ROOT/platform/posix/btstack_run_loop_posix.c"
  "$BTSTACK_ROOT/platform/posix/btstack_tlv_posix.c"
  "$BTSTACK_ROOT/port/ios/src/hci_transport_h4_iphone.c"
  "$BTSTACK_ROOT/port/ios/src/hci_transport_skywalk_iphone.c"
  "$BTSTACK_ROOT/port/ios/SpringBoardAccess/SpringBoardAccess.c"
  "$BTSTACK_ROOT/stubs.c"
)

BTD_M_SOURCES=(
  "$BTSTACK_ROOT/platform/corefoundation/btstack_device_name_db_corefoundation.m"
  "$BTSTACK_ROOT/platform/corefoundation/btstack_link_key_db_corefoundation.m"
  "$BTSTACK_ROOT/platform/corefoundation/btstack_run_loop_corefoundation.m"
  "$BTSTACK_ROOT/platform/corefoundation/rfcomm_service_db_corefoundation.m"
  "$BTSTACK_ROOT/port/ios/src/btstack_control_iphone.m"
  "$BTSTACK_ROOT/port/ios/src/platform_iphone.m"
)

for src in "${BTD_C_SOURCES[@]}"; do
  obj="$BTD_OBJDIR/$(basename "${src%.c}.o")"
  "$CLANG" -c -isysroot "$SDKROOT" -arch "$ARCH" -mios-version-min="$MIN_IOS" \
    -fno-objc-arc "${BTSTACK_INCLUDES[@]}" \
    -O2 -Wno-deprecated-declarations -Wno-deprecated-non-prototype \
    -Wno-incompatible-pointer-types -Wno-pointer-sign \
    -Wno-unused-command-line-argument \
    "$src" -o "$obj"
done

for src in "${BTD_M_SOURCES[@]}"; do
  obj="$BTD_OBJDIR/$(basename "${src%.m}.o")"
  "$CLANG" -c -isysroot "$SDKROOT" -arch "$ARCH" -mios-version-min="$MIN_IOS" \
    -fno-objc-arc "${BTSTACK_INCLUDES[@]}" \
    -O2 -Wno-deprecated-declarations -Wno-deprecated-non-prototype \
    -Wno-incompatible-pointer-types -Wno-pointer-sign \
    -Wno-unused-command-line-argument \
    "$src" -o "$obj"
done

"$CLANG" -isysroot "$SDKROOT" -arch "$ARCH" -mios-version-min="$MIN_IOS" \
  -framework Foundation -framework CoreFoundation -framework IOKit \
  -Wl,-undefined,dynamic_lookup \
  -Wl,-not_for_dyld_shared_cache \
  "$BTD_OBJDIR"/*.o \
  -o "$STAGE/usr/bin/BTdaemon"
echo "       -> BTdaemon built"

# ── 3. Build Showcase app binary ───────────────────────────────────────
echo ""
echo "[3/6] Building Showcase.app binaries"

"$CLANG" "${CFLAGS_COMMON[@]}" \
  -DSHOWCASE_ROOTHIDE=1 \
  -DAPP_VERSION="\"$DISPLAY_VERSION\"" \
  "$REPO_ROOT/source/Showcase.m" \
  -framework UIKit -framework AVFoundation -framework AudioToolbox \
  -framework CoreMedia -framework Foundation -framework Security \
  -o "$STAGE/Applications/Showcase.app/Showcase"
echo "       -> Showcase built"

"$CLANG" "${CFLAGS_COMMON[@]}" \
  -DSHOWCASE_ROOTHIDE=1 \
  "$REPO_ROOT/source/carplay_bt.m" \
  "$STAGE/usr/lib/libBTstack.dylib" \
  -framework Foundation -framework Security \
  -o "$STAGE/Applications/Showcase.app/CarDisplaySim"
echo "       -> CarDisplaySim (carplay_bt) built"

"$CLANG" "${CFLAGS_COMMON[@]}" \
  -DSHOWCASE_ROOTHIDE=1 \
  "$REPO_ROOT/source/carplay_services.m" \
  "$REPO_ROOT/source/carplay_pair.c" \
  "$REPO_ROOT/source/vendor/monocypher/monocypher.c" \
  "$REPO_ROOT/source/vendor/monocypher/monocypher-ed25519.c" \
  "$REPO_ROOT/source/vendor/libtommath/tommath.c" \
  -framework Foundation -framework Security \
  -o "$STAGE/Applications/Showcase.app/CarPlay Simulator"
echo "       -> CarPlay Simulator (carplay_services) built"

# ── 4. Assemble app bundle ─────────────────────────────────────────────
echo ""
echo "[4/6] Assembling Showcase.app"

fill_version "$REPO_ROOT/source/Info.plist" > "$STAGE/Applications/Showcase.app/Info.plist"
cp "$REPO_ROOT/icon/generated/"*.png "$STAGE/Applications/Showcase.app/"
rm -rf "$STAGE/Applications/Showcase.app/"*.lproj
cp -R "$REPO_ROOT/source/Localizations/"*.lproj "$STAGE/Applications/Showcase.app/"

# Entitlements stored for postinst install-time signing.
cp "$REPO_ROOT/source/ent_app.xml" "$STAGE/usr/share/showcase/ent_app.xml"
cp "$REPO_ROOT/source/ent_bt.xml" "$STAGE/usr/share/showcase/ent_bt.xml"
cp "$REPO_ROOT/source/ent_svc.xml" "$STAGE/usr/share/showcase/ent_svc.xml"
cp "$REPO_ROOT/source/ent_btdaemon.xml" "$STAGE/usr/share/showcase/ent_btdaemon.xml"

# BTstack launch daemon plist (rootful-style path for RootHide).
BTSTACK_PLIST_SRC="$BTSTACK_ROOT/port/ios/layout/Library/LaunchDaemons/ch.ringwald.BTstack.plist"
if [ -f "$BTSTACK_PLIST_SRC" ]; then
  cp "$BTSTACK_PLIST_SRC" "$STAGE/Library/LaunchDaemons/ch.ringwald.BTstack.plist"
else
cat > "$STAGE/Library/LaunchDaemons/ch.ringwald.BTstack.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>ch.ringwald.BTstack</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/BTdaemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/BTstack.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/BTstack.log</string>
</dict>
</plist>
PLIST

# DEBIAN control scripts
fill_version "$CONTROL" > "$STAGE/DEBIAN/control"
cp "$CONTROL_DIR/postinst" "$STAGE/DEBIAN/postinst"
cp "$CONTROL_DIR/prerm" "$STAGE/DEBIAN/prerm"
cp "$CONTROL_DIR/postrm" "$STAGE/DEBIAN/postrm"

echo "       -> Bundle assembled"

# ── 5. Sign binaries ───────────────────────────────────────────────────
echo ""
echo "[5/6] Signing binaries"

ldid -S"$REPO_ROOT/source/ent_app.xml" "$STAGE/Applications/Showcase.app/Showcase"
ldid -S"$REPO_ROOT/source/ent_bt.xml" "$STAGE/Applications/Showcase.app/CarDisplaySim"
ldid -S"$REPO_ROOT/source/ent_svc.xml" "$STAGE/Applications/Showcase.app/CarPlay Simulator"
ldid -S"$REPO_ROOT/source/ent_btdaemon.xml" "$STAGE/usr/bin/BTdaemon"
ldid -S "$STAGE/usr/lib/libBTstack.dylib"
echo "       -> All binaries signed"

# ── 6. Package ─────────────────────────────────────────────────────────
echo ""
echo "[6/6] Packaging deb"

# Set permissions
chmod 0755 "$STAGE" "$STAGE/Applications" "$STAGE/Applications/Showcase.app"
chmod 0755 "$STAGE/usr" "$STAGE/usr/bin" "$STAGE/usr/lib" "$STAGE/usr/share" "$STAGE/usr/share/showcase"
chmod 0755 "$STAGE/Library" "$STAGE/Library/LaunchDaemons"
chmod 0644 "$STAGE/Applications/Showcase.app/Info.plist"
chmod 0644 "$STAGE/Applications/Showcase.app/"Icon*.png
chmod 0755 "$STAGE/Applications/Showcase.app/"*.lproj
chmod 0644 "$STAGE/Applications/Showcase.app/"*.lproj/*
chmod 0644 "$STAGE/usr/share/showcase/"*.xml
chmod 4755 "$STAGE/Applications/Showcase.app/Showcase"
chmod 4755 "$STAGE/Applications/Showcase.app/CarDisplaySim"
chmod 4755 "$STAGE/Applications/Showcase.app/CarPlay Simulator"
chmod 0755 "$STAGE/usr/bin/BTdaemon"
chmod 0755 "$STAGE/usr/lib/libBTstack.dylib"
chmod 0644 "$STAGE/Library/LaunchDaemons/ch.ringwald.BTstack.plist"
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"
chmod 0644 "$STAGE/DEBIAN/control"

# Generate md5sums
( cd "$STAGE" && find . -path ./DEBIAN -prune -o -type f -exec md5 -r {} \; | \
  sed 's# \./#  #' > DEBIAN/md5sums )
chmod 0644 "$STAGE/DEBIAN/md5sums"

# Build deb
dpkg-deb -Zgzip -z9 -b "$STAGE" "$BUILD/$DEB_NAME"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "DONE — built $BUILD/$DEB_NAME"
dpkg-deb -I "$BUILD/$DEB_NAME"
echo "═══════════════════════════════════════════════════════════"
