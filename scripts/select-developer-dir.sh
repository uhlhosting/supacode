#!/usr/bin/env bash
# Prints the Developer dir of an Xcode whose macOS SDK the pinned Zig can link.
# Shared by the build scripts, the Makefile, and `make doctor`. Exit 1 with an
# actionable message when none is installed.
set -euo pipefail

# Zig 0.15.2 cannot link macOS 26.4+ SDKs (ziglang/zig#31658); that is fixed in
# Zig 0.16+. Derive the highest linkable SDK from the pinned Zig version so a
# machine running the newer default Xcode (macOS 27 / Xcode 27) still builds.
max_linkable_sdk() {
  local zig_ver="" major minor
  if command -v mise >/dev/null 2>&1; then
    zig_ver="$(mise exec -- zig version 2>/dev/null)" || true
  elif command -v zig >/dev/null 2>&1; then
    zig_ver="$(zig version 2>/dev/null)" || true
  fi
  [ -n "${zig_ver}" ] || { printf '26.3\n'; return; }
  major="$(printf '%s' "$zig_ver" | cut -d. -f1)"
  minor="$(printf '%s' "$zig_ver" | cut -d. -f2)"
  if [ "$major" -gt 0 ] 2>/dev/null || { [ "$major" -eq 0 ] 2>/dev/null && [ "$minor" -ge 16 ] 2>/dev/null; }; then
    printf '27.3\n'
  else
    printf '26.3\n'
  fi
}

MAX_SDK="$(max_linkable_sdk)"

# Linkable when the dir is a full Xcode, not CommandLineTools (no xcodebuild), and
# its macOS SDK is not newer than the pinned Zig can link.
is_zig_linkable() {
  local dir="$1" ver
  [ -d "$dir" ] || return 1
  # Require a full Xcode, not CommandLineTools (no xcodebuild).
  [ -x "${dir}/usr/bin/xcodebuild" ] || return 1
  ver="$(DEVELOPER_DIR="$dir" xcrun --sdk macosx --show-sdk-version 2>/dev/null)" || return 1
  [ -n "$ver" ] || return 1
  # Reject SDKs newer than MAX_SDK; sort -V keeps 26.10 above 26.3.
  [ "$(printf '%s\n%s\n' "$ver" "$MAX_SDK" | sort -V | tail -1)" = "$MAX_SDK" ]
}

# Honor an explicit DEVELOPER_DIR when it is itself linkable.
if [ -n "${DEVELOPER_DIR:-}" ] && is_zig_linkable "${DEVELOPER_DIR}"; then
  printf '%s\n' "${DEVELOPER_DIR}"
  exit 0
fi

candidates=()
# Known-good versioned Xcodes first (newest linkable SDK, underscore and hyphen
# naming), so a machine whose default is a newer non-linkable Xcode still finds
# a linkable one instead of stopping at the default.
if [ "$MAX_SDK" = "27.3" ]; then
  for app in \
    /Applications/Xcode_27.3*.app /Applications/Xcode-27.3*.app \
    /Applications/Xcode_27.2*.app /Applications/Xcode-27.2*.app \
    /Applications/Xcode_27.1*.app /Applications/Xcode-27.1*.app \
    /Applications/Xcode_27.0*.app /Applications/Xcode-27.0*.app; do
    [ -d "${app}" ] && candidates+=("${app}/Contents/Developer")
  done
fi
for app in \
  /Applications/Xcode_26.3*.app /Applications/Xcode-26.3*.app \
  /Applications/Xcode_26.2*.app /Applications/Xcode-26.2*.app \
  /Applications/Xcode_26.1*.app /Applications/Xcode-26.1*.app \
  /Applications/Xcode_26.0*.app /Applications/Xcode-26.0*.app; do
  [ -d "${app}" ] && candidates+=("${app}/Contents/Developer")
done
# Then the currently-selected and unversioned default, covering a linkable Xcode
# at a non-standard path.
if current="$(xcode-select -p 2>/dev/null)" && [ -n "${current}" ]; then
  candidates+=("${current}")
fi
[ -d /Applications/Xcode.app ] && candidates+=("/Applications/Xcode.app/Contents/Developer")

# Guard the empty case: bash 3.2 errors on `"${arr[@]}"` under `set -u`.
for dir in ${candidates[@]+"${candidates[@]}"}; do
  if is_zig_linkable "${dir}"; then
    printf '%s\n' "${dir}"
    exit 0
  fi
done

if [ "$MAX_SDK" = "27.3" ]; then
  cat >&2 <<'EOF'
error: no Zig-linkable Xcode found.

  The pinned Zig (0.16.0+) cannot link the installed macOS SDK. On macOS 27
  with Xcode 27, the default Xcode should be linkable; if you see this,
  accept the Xcode license and finish first launch:

    sudo xcodebuild -license accept
    sudo xcodebuild -runFirstLaunch

  No global `xcode-select -s` is needed. The build picks it up automatically.
EOF
else
  cat >&2 <<'EOF'
error: no Zig-linkable Xcode found.

  The pinned Zig (0.15.2) cannot link the macOS 26.4+ SDK (ziglang/zig
  #31658, fixed only in Zig 0.16+). Install Xcode 26.3, which ships the macOS
  26.2 SDK whose .tbd still has arm64-macos:

    https://developer.apple.com/download/all/?q=Xcode%2026.3

  Then accept its license and finish first launch:

    sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -license accept
    sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -runFirstLaunch

  No global `xcode-select -s` is needed. The build picks it up automatically.
EOF
fi
exit 1
