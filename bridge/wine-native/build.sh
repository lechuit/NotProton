#!/bin/sh
# Build tiny native PE forwarding DLLs and a harmless Steam session probe.
# The selected matching Wine LSC halves must already have been built separately.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
toolchain=""
lsc_x64=""
lsc_x86=""
sdk=""
out=""
wine_version=11.17
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
    case "$1" in
        --toolchain) toolchain=$2 ;;
        --lsteamclient-x64) lsc_x64=$2 ;;
        --lsteamclient-x86) lsc_x86=$2 ;;
        --sdk-root) sdk=$2 ;;
        --output) out=$2 ;;
        --wine-version) wine_version=$2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift 2
done
case "$wine_version" in
    11.17|11.18) ;;
    *) echo "Unsupported --wine-version: use Devel 11.17 or 11.18 (not Staging)." >&2; exit 1 ;;
esac
[ -n "$toolchain" ] && [ -n "$lsc_x64" ] && [ -n "$sdk" ] && [ -n "$out" ] || {
    echo "Required: --toolchain <llvm-mingw-root> --lsteamclient-x64 <dll> --sdk-root <Steamworks165> --output <dir>; optional --wine-version 11.17|11.18 (default: 11.17)" >&2
    exit 1
}
[ -f "$sdk/steam_api.h" ] || { echo "Steamworks SDK headers missing" >&2; exit 1; }
mkdir -p "$out"
out=$(cd "$out" && pwd)

build_arch() {
    arch=$1
    reference=$2
    module=$3
    machine=$4
    case "$arch" in
        x86_64) compiler=x86_64-w64-mingw32-clang ;;
        i386) compiler=i686-w64-mingw32-clang ;;
    esac
    directory="$out/$arch-windows"
    mkdir -p "$directory"
    python3 "$here/forwarders.py" generate "$reference" --module "$module" --output "$directory/$module.def"
    "$toolchain/bin/$compiler" -c -O2 -fno-stack-protector \
        "$here/interface-reserve.c" -o "$directory/interface-reserve.o"
    "$toolchain/bin/lld-link" /dll /noentry /nodefaultlib /opt:noref \
        "/machine:$machine" "/def:$directory/$module.def" "/out:$directory/$module.dll" \
        "$directory/interface-reserve.o"
    python3 "$here/forwarders.py" verify "$reference" "$directory/$module.dll" \
        --module "$module" --report "$directory/$module-verification.json"
    "$toolchain/bin/$compiler++" -std=c++17 -O2 -static -I"$sdk" \
        "-DNP_EXPECTED_WINE_VERSION=\"$wine_version\"" \
        "$here/steam-probe.cpp" -o "$directory/steam-probe.exe"
}

build_arch x86_64 "$lsc_x64" steamclient64 x64
if [ -n "$lsc_x86" ]; then
    build_arch i386 "$lsc_x86" steamclient x86
fi
echo "Built forwarders and probes in $out; no runtime or prefix was changed."
