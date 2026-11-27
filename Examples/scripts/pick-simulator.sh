#!/usr/bin/env bash
#
# Print an `xcodebuild -destination` string for an iPhone simulator.
#
#   pick-simulator.sh            → an iPhone on the NEWEST installed iOS runtime
#   pick-simulator.sh 16.4       → an iPhone on iOS 16.4 — installing that runtime if the
#                                  installed Xcode can. If it can't (e.g. a much newer Xcode
#                                  that no longer offers 16.4), it falls back to the OLDEST
#                                  installed runtime and logs that, so CI never breaks on a
#                                  runtime that simply isn't available on this runner.
#
# Set CATCHDEV_NO_DOWNLOAD=1 to skip the runtime-download attempt (tests / offline).
# Diagnostics go to stderr; ONLY the destination string is printed to stdout, so callers
# can capture it with `dest=$(pick-simulator.sh 16.4)`.
set -euo pipefail

version="${1:-}"

# "<version> <runtime-identifier>" for each installed+available iOS runtime, version-sorted
# ascending. A numeric key (major*1000+minor…) is used so 16.10 sorts after 16.4 and we
# don't depend on GNU `sort -V` (BSD sort on macOS lacks it).
installed_runtimes() {
  xcrun simctl list runtimes \
    | sed -nE 's/^iOS ([0-9]+(\.[0-9]+)*) .* (com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+)$/\1 \3/p' \
    | awk '{ n=split($1,a,"."); k=0; for(i=1;i<=n;i++) k=k*1000+a[i]; printf "%015d %s %s\n", k, $1, $2 }' \
    | sort -n | awk '{print $2, $3}'
}
newest_runtime() { installed_runtimes | tail -1 | awk '{print $2}'; }
oldest_runtime() { installed_runtimes | head -1 | awk '{print $2}'; }
runtime_for_version() { installed_runtimes | awk -v v="$1" '$1 == v {print $2; exit}'; }

resolve_runtime() {
  if [ -z "$version" ]; then newest_runtime; return; fi

  local rid; rid=$(runtime_for_version "$version")
  if [ -z "$rid" ] && [ "${CATCHDEV_NO_DOWNLOAD:-}" != "1" ]; then
    echo "iOS $version runtime not installed; attempting download…" >&2
    xcodebuild -downloadPlatform iOS -buildVersion "$version" 1>&2 \
      || echo "download of iOS $version failed or unavailable on this Xcode" >&2
    rid=$(runtime_for_version "$version")
  fi
  if [ -z "$rid" ]; then
    rid=$(oldest_runtime)
    echo "iOS $version unavailable on this runner; falling back to oldest installed ($rid)" >&2
  fi
  echo "$rid"
}

rid=$(resolve_runtime)
[ -n "$rid" ] || { echo "no usable iOS simulator runtime is installed" >&2; exit 1; }

# Stable, reuse-by-name device per runtime (idempotent — avoids piling up simulators on a
# persistent self-hosted runner). Older runtimes don't support newer device types, so the
# preferred models are tried oldest-first. After them comes every iPhone this Xcode knows,
# newest first (`simctl list devicetypes` order), so a future runtime that has dropped all
# the preferred models still gets a device: the runtime rejects types it doesn't support and
# the first one it accepts wins. No model name here has to be updated when Apple retires one.
label="${rid##*.SimRuntime.}"   # e.g. iOS-16-4
name="catchdev-ci-$label"
udid=$(xcrun simctl list devices | grep -F "$name (" | grep -oE '[0-9A-F-]{36}' | head -1 || true)

if [ -z "$udid" ]; then
  candidates=$(
    printf '%s\n' "iPhone 14" "iPhone 15" "iPhone 16" "iPhone SE (3rd generation)" "iPhone 13"
    xcrun simctl list devicetypes \
      | sed -nE 's/^iPhone.*\((com\.apple\.CoreSimulator\.SimDeviceType\.[^)]+)\)$/\1/p'
  )
  while IFS= read -r dt; do
    [ -n "$dt" ] || continue
    if udid=$(xcrun simctl create "$name" "$dt" "$rid" 2>/dev/null); then
      echo "created simulator '$dt' on $label ($udid)" >&2
      break
    fi
    udid=""
  done <<< "$candidates"
fi
[ -n "$udid" ] || { echo "could not find or create an iPhone on $label" >&2; exit 1; }

echo "platform=iOS Simulator,id=$udid"
