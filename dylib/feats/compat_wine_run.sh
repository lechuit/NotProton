#!/bin/sh
# notproton independent Wine compatibility tool shim (experimental)
set -eu

fail() { printf 'NotProton experimental Wine: %s\n' "$*" >&2; exit 1; }
verb=${1:-}
[ "$#" -gt 0 ] && shift
case "$verb" in
  getcompatpath|run|runinprefix|waitforexitandrun) ;;
  *) fail "Unsupported launch verb: $verb" ;;
esac

CDPATH=''
tool_dir=$(cd -P -- "$(dirname -- "$0")" && pwd) || fail "Cannot resolve tool directory."
engine=$(cat "$tool_dir/build") || fail "No engine is registered."
case "$engine" in wine-*) engine=${engine#wine-} ;; *) fail "Invalid engine record." ;; esac
case "$engine" in ''|*[!a-z0-9.-]*|.*|*..*) fail "Invalid engine id." ;; esac
record="$HOME/Library/Application Support/notproton/runners/wine-$engine/runtime.v1"
[ -r "$record" ] || fail "Engine $engine is not registered. Import its descriptor again."
exec 3< "$record"
IFS= read -r schema <&3 && IFS= read -r registered <&3 \
  && IFS= read -r runtime <&3 && IFS= read -r loader_rel <&3 \
  && IFS= read -r server_rel <&3 && IFS= read -r loader_hash <&3 \
  && IFS= read -r server_hash <&3 || fail "Incomplete runtime record."
mode=raw
bridge_identity=""
runtime_ntdll_hash=""
case "$schema:$engine" in
  1:native-*) fail "Native engines require a version 2 descriptor." ;;
  1:*) ;;
  2:native-*)
    mode=native
    IFS= read -r bridge_identity <&3 && IFS= read -r runtime_ntdll_hash <&3 \
      || fail "Incomplete native bridge record."
    ;;
  *) fail "Invalid runtime schema or native engine identity." ;;
esac
exec 3<&-
[ "$registered" = "$engine" ] || fail "Invalid runtime record."
case "$runtime" in /*) ;; *) fail "Runtime root must be absolute." ;; esac
case "$loader_rel" in bin/wine|bin/wine64) ;; *) fail "Invalid Wine loader." ;; esac
[ "$server_rel" = bin/wineserver ] || fail "Invalid Wine server."
[ ! -d "$runtime/share/crossover" ] || fail "A CrossOver runtime cannot be imported as independent Wine."
[ -d "$runtime" ] && [ ! -L "$runtime" ] || fail "Runtime root is missing or has changed."
runtime_real=$(cd -P -- "$runtime" && pwd) || fail "Runtime root is unreadable."
[ "$runtime_real" = "$runtime" ] || fail "Runtime root has changed; import it again."
loader="$runtime/$loader_rel"
server="$runtime/$server_rel"
for executable in "$loader" "$server"; do
  [ -x "$executable" ] && [ -f "$executable" ] || fail "Runtime executable is missing."
  # The importer accepts only in-root symlinks. Re-check their targets at launch.
  resolved="$executable"
  links=0
  while [ -L "$resolved" ]; do
    links=$((links + 1))
    [ "$links" -le 20 ] || fail "Runtime symlink loop."
    target=$(readlink "$resolved") || fail "Cannot read runtime symlink."
    case "$target" in /*) resolved="$target" ;; *) resolved="$(dirname "$resolved")/$target" ;; esac
  done
  parent=$(cd -P -- "$(dirname "$resolved")" && pwd) || fail "Cannot resolve runtime executable."
  case "$parent/" in "$runtime/"*) ;; *) fail "Runtime executable leaves its registered root." ;; esac
done
actual_loader=$(/usr/bin/shasum -a 256 "$loader" | awk '{print $1}')
actual_server=$(/usr/bin/shasum -a 256 "$server" | awk '{print $1}')
[ "$actual_loader" = "$loader_hash" ] && [ "$actual_server" = "$server_hash" ] \
  || fail "Runtime executables changed; import the descriptor again."
bridge=""
if [ "$mode" = native ]; then
  for hash in "$bridge_identity" "$runtime_ntdll_hash"; do
    [ "${#hash}" -eq 64 ] || fail "Invalid native bridge fingerprint."
    case "$hash" in *[!a-f0-9]*) fail "Invalid native bridge fingerprint." ;; esac
  done
  bridge="$HOME/Library/Application Support/notproton/runners/wine-$engine/bridge-$bridge_identity"
  [ -d "$bridge" ] && [ ! -L "$bridge" ] || fail "Native bridge is missing."
  actual_ntdll=$(/usr/bin/shasum -a 256 "$runtime/lib/wine/x86_64-unix/ntdll.so" | awk '{print $1}')
  [ "$actual_ntdll" = "$runtime_ntdll_hash" ] \
    || fail "Runtime ntdll.so changed. Rebuild and register a matching native bridge."
  actual_checksums=$({ printf 'ntdll-runtime-link-v1\n'; cat "$bridge/checksums.sha256"; } | /usr/bin/shasum -a 256 | awk '{print $1}')
  [ "$actual_checksums" = "$bridge_identity" ] || fail "Native bridge file manifest changed."
  runtime_ntdll="$runtime/lib/wine/x86_64-unix/ntdll.so"
  resolved="$runtime_ntdll"
  links=0
  while [ -L "$resolved" ]; do
    links=$((links + 1))
    [ "$links" -le 20 ] || fail "Runtime ntdll symlink loop."
    target=$(readlink "$resolved") || fail "Cannot resolve runtime ntdll."
    case "$target" in /*) resolved="$target" ;; *) resolved="$(dirname "$resolved")/$target" ;; esac
  done
  parent=$(cd -P -- "$(dirname "$resolved")" && pwd) || fail "Cannot resolve runtime ntdll."
  canonical_ntdll="$parent/$(basename "$resolved")"
  case "$canonical_ntdll" in "$runtime/"*) ;; *) fail "Runtime ntdll leaves its runtime root." ;; esac
  [ -L "$bridge/x86_64-unix/ntdll.so" ] \
    && [ "$(readlink "$bridge/x86_64-unix/ntdll.so")" = "$canonical_ntdll" ] \
    || fail "Native bridge ntdll must link to the exact runtime image; copied or redirected images are unsafe."
  for file in x86_64-windows/lsteamclient.dll x86_64-windows/steamclient64.dll x86_64-windows/steam.exe \
    i386-windows/lsteamclient.dll i386-windows/steamclient.dll x86_64-unix/lsteamclient.so; do
    [ ! -L "$bridge/$file" ] || fail "Only the runtime ntdll link is allowed in a native bridge."
  done
  (cd "$bridge" && /usr/bin/shasum -a 256 -c checksums.sha256 >/dev/null 2>&1) \
    || fail "Native bridge files changed. Import a clean bridge again."
fi

data=${STEAM_COMPAT_DATA_PATH:-}
case "$data" in /*) ;; *) fail "Steam did not provide an absolute compatibility data path." ;; esac
# Refuse before writing even a log into an existing CrossOver/unknown prefix.
[ ! -e "$data/notproton-build" ] && [ ! -e "$data/pfx" ] && [ ! -L "$data/pfx" ] \
  || fail "This game has an existing CrossOver or unknown prefix. Back it up and select a fresh compatibility data directory."
prefix_root="$data/notproton-wine/$engine"
if [ "$verb" = getcompatpath ]; then
  printf '%s\n' "$prefix_root"
  exit 0
fi
[ "$#" -gt 0 ] || fail "No Windows program was supplied."
for directory in "$data" "$data/notproton-wine" "$prefix_root" "$prefix_root/pfx"; do
  [ ! -L "$directory" ] || fail "A prefix directory is a symlink."
done
native_client=""
if [ "$mode" = native ]; then
  prefix_steam="$prefix_root/pfx/drive_c/Program Files (x86)/Steam"
  for directory in "$prefix_root/pfx/drive_c" "$prefix_root/pfx/drive_c/Program Files (x86)" \
    "$prefix_steam" "$prefix_root/pfx/drive_c/windows" "$prefix_root/pfx/drive_c/windows/syswow64"; do
    [ ! -L "$directory" ] || fail "Native bridge prefix directory is a symlink."
  done
  if [ -e "$prefix_steam/steam.exe" ]; then
    have=$(/usr/bin/shasum -a 256 "$prefix_steam/steam.exe" | awk '{print $1}')
    want=$(/usr/bin/shasum -a 256 "$bridge/x86_64-windows/steam.exe" | awk '{print $1}')
    [ "$have" = "$want" ] || fail "Windows Steam or an unknown shim is already installed in this native prefix. Use a fresh prefix."
  fi
  native_client=${STEAM_COMPAT_CLIENT_INSTALL_PATH:-"$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"}
  [ -f "$native_client/steamclient.dylib" ] || fail "The Steam for Mac client library is missing. Open Steam for Mac first."
fi
mkdir -p "$prefix_root"
marker="$prefix_root/engine"
[ ! -L "$marker" ] || fail "Prefix engine marker is a symlink."
identity="$engine $loader_hash $server_hash"
[ "$mode" != native ] || identity="$identity $bridge_identity $runtime_ntdll_hash"
if [ -e "$marker" ]; then
  [ "$(cat "$marker")" = "$identity" ] || fail "Prefix belongs to a different engine build. Back it up and create a fresh prefix."
else
  [ ! -e "$prefix_root/pfx" ] || fail "Unmarked prefix; create a fresh prefix."
  printf '%s\n' "$identity" > "$marker"
fi
log="$prefix_root/notproton-wine.log"
[ ! -L "$log" ] || fail "Log is a symlink."
export WINEPREFIX="$prefix_root/pfx" WINELOADER="$loader" WINESERVER="$server"
export PATH="$runtime/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export WINEDEBUG="${WINEDEBUG:-err+all,fixme-all}"
# These belong to the native Steam/CrossOver bridge, which this backend does not use.
unset DYLD_INSERT_LIBRARIES STEAM_DYLD_INSERT_LIBRARIES WINEDLLPATH WINEDLLOVERRIDES
unset CX_ROOT CX_HOME CX_APPLEGPTK_LIBD3DSHARED_PATH
unset WINEARCH WINEESYNC WINEFSYNC WINEMSYNC WINEPRELOADRESERVE WINELOADERNOEXEC
for variable in $(env | sed -nE 's/^((CX|D3DM|DXMT|NOTPROTON|ROSETTA|DYLD)_[A-Z0-9_]*)=.*/\1/p'); do
  unset "$variable"
done
{
  printf '\n=== experimental Wine %s: %s ===\n' "$engine" "$(date)"
  printf 'verb=%s\nprefix=%s\n' "$verb" "$WINEPREFIX"
  if [ "$mode" = native ]; then
    printf 'Experimental native SteamAPI bridge; Steam for Mac must be running. No Steam Input or overlay bridge.\n'
  else
    printf 'No native SteamAPI bridge. Games requiring SteamAPI need Windows Steam running in this prefix.\n'
  fi
  printf 'Launching a Windows program. Arguments omitted because they may contain authentication tokens.\n'
} >> "$log"
if [ "$mode" = native ]; then
  prefix_steam="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
  # Wine can defer registry-file persistence until wineserver flushes. Completing
  # an actual Windows program verifies readiness without waiting for that flush.
  "$loader" cmd.exe /c ver >> "$log" 2>&1 || fail "Wine prefix readiness check failed; see the Wine log."
  for directory in "$WINEPREFIX/drive_c" "$WINEPREFIX/drive_c/Program Files (x86)" \
    "$prefix_steam" "$WINEPREFIX/drive_c/windows" "$WINEPREFIX/drive_c/windows/syswow64"; do
    [ ! -L "$directory" ] || fail "Native bridge prefix directory is a symlink."
  done
  mkdir -p "$prefix_steam" "$WINEPREFIX/drive_c/windows/syswow64"
  stage_bridge_file() {
    [ ! -L "$2" ] || fail "Native bridge destination is a symlink."
    cp -f "$bridge/$1" "$2" || fail "Could not stage native bridge file."
  }
  for file in lsteamclient.dll steamclient64.dll steam.exe; do
    stage_bridge_file "x86_64-windows/$file" "$prefix_steam/$file"
  done
  stage_bridge_file i386-windows/steamclient.dll "$prefix_steam/steamclient.dll"
  stage_bridge_file i386-windows/lsteamclient.dll "$WINEPREFIX/drive_c/windows/syswow64/lsteamclient.dll"
  stage_bridge_file i386-windows/steamclient.dll "$WINEPREFIX/drive_c/windows/syswow64/steamclient.dll"
  # Wine appends the architecture directories and pairs each builtin PE with its Unix half.
  # Listing the PE trigger directory or arch leaves can select a builtin with no paired .so.
  export WINEDLLPATH="$bridge:$runtime/lib/wine"
  export WINEDLLOVERRIDES="steamclient=n;steamclient64=n;lsteamclient=b"
  export STEAM_COMPAT_CLIENT_INSTALL_PATH="$native_client"
  case "$verb" in
    waitforexitandrun)
      app_id=${STEAM_COMPAT_APP_ID:-${SteamAppId:-0}}
      case "$app_id" in ''|*[!0-9]*) fail "Steam did not provide a numeric app id." ;; esac
      export SteamAppId="$app_id" SteamGameId="${SteamGameId:-$app_id}"
      ;;
    *) unset SteamAppId SteamGameId ;;
  esac
  if [ "$verb" != runinprefix ]; then
    set -- "$prefix_steam/steam.exe" "$@"
  fi
fi
status=0
"$loader" "$@" >> "$log" 2>&1 || status=$?
# Windows Steam may stay open in this prefix; waiting for the whole wineserver
# would keep native Steam's game marked running after the launched program exits.
printf '=== Wine exited status=%s ===\n' "$status" >> "$log"
exit "$status"
