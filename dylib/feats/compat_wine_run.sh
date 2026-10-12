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
exec 3<&-
[ "$schema" = 1 ] && [ "$registered" = "$engine" ] || fail "Invalid runtime record."
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
mkdir -p "$prefix_root"
marker="$prefix_root/engine"
[ ! -L "$marker" ] || fail "Prefix engine marker is a symlink."
identity="$engine $loader_hash $server_hash"
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
  printf 'No native SteamAPI bridge. Games requiring SteamAPI need Windows Steam running in this prefix.\n'
  printf 'Launching a Windows program. Arguments omitted because they may contain authentication tokens.\n'
} >> "$log"
status=0
"$loader" "$@" >> "$log" 2>&1 || status=$?
# Windows Steam may stay open in this prefix; waiting for the whole wineserver
# would keep native Steam's game marked running after the launched program exits.
printf '=== Wine exited status=%s ===\n' "$status" >> "$log"
exit "$status"
