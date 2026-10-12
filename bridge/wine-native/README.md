# Native Steam bridge for matching stock Wine

This experiment forwards the native Windows DLL names `steamclient64.dll` and
`steamclient.dll` to a separately rebuilt Wine `lsteamclient.dll`. The Unix
half of LSC opens the already installed macOS Steam `steamclient.dylib`.
It avoids CrossOver's binary `ntdll` detour and keeps the stock Wine runtime intact.

`forwarders.py` reads the built PE's actual names and ordinals. It refuses unnamed
exports, malformed images, mismatched architectures, or references which are
themselves forwarders. Validation checks every forwarding target and ordinal,
the absence of executable entry points/imports, and a 64 KiB initialized writable
`.data` reserve. LSC uses this reserve for interface objects and vtables when a
game expects them to reside inside its `steamclient` module.

## Build

First rebuild both LSC PE halves and the x86_64 Unix half against the pinned Wine
Devel 11.17, 11.18 or 11.19 headers and that runtime's unchanged ntdll. See
[the component build guide](BUILD-LSTEAMCLIENT.md) for the exact source pins.
Do not substitute an old CrossOver `ntdll` or transplant its patch.
Then pass those PE files and the workspace-local LLVM MinGW toolchain explicitly:

```sh
sh bridge/wine-native/build.sh \
  --wine-version 11.19 \
  --toolchain /absolute/path/to/llvm-mingw \
  --lsteamclient-x64 /absolute/path/to/x86_64-windows/lsteamclient.dll \
  --lsteamclient-x86 /absolute/path/to/i386-windows/lsteamclient.dll \
  --sdk-root /absolute/path/to/steamworks_sdk_165 \
  --output /absolute/path/to/bridge-probe
```

The i386 option is optional while validating the 64-bit path. All output stays in
the specified build directory. Building does not install libraries, touch Steam,
start a game, change accounts, or rewrite a user's prefix.
The version option accepts only `11.17` (default), `11.18` or `11.19` and compiles that exact
expected version into both probes. Use the same choice as the LSC build; changing
this option does not make an older LSC binary compatible with a newer runtime.

Run the regression checks against each actual built forwarder:

```sh
python3 bridge/wine-native/test_forwarders.py \
  /absolute/path/to/x86_64-windows/lsteamclient.dll \
  /absolute/path/to/bridge-probe/x86_64-windows/steamclient64.dll \
  --module steamclient64
```

The checks reject altered forwarding targets, executable entry points/imports,
read-only interface storage, forwarding DLLs used as a reference, and truncated
PE files. Repeat with the i386 LSC, `steamclient.dll`, and `--module steamclient`.

## Validate a separately staged runtime

Use an isolated fresh prefix and an ABI-checked bridge directory with architecture
subdirectories. Keep the selected official Wine runtime's `ntdll.so` and
`ntdll.dll` unchanged. The staged Unix bridge must link to its canonical runtime
ntdll.so using the verified symlink described in the component build guide.
Set `WINEDLLPATH` to the **parent bridge directory**, `lsteamclient=b`, and the
forwarding DLLs to `n`. Wine adds the `x86_64-windows`, `i386-windows`, and
`x86_64-unix` suffixes itself. Do not add those subdirectories or the prefix's
Steam directory to `WINEDLLPATH`: selecting a flat PE trigger as the builtin would
associate it with a nonexistent adjacent Unix half and break Unix calls.
Stage the native forwarders and **the x86_64 LSC PE trigger** into the fresh
prefix's Steam directory; place the i386 LSC PE trigger in `windows/syswow64` for
32-bit clients. Stock Wine resolves a real Windows-path DLL before choosing a
builtin implementation, so merely adding a DLL to `WINEDLLPATH` is insufficient.
`lsteamclient=b` redirects those architecture-correct trigger files to the staged
LSC builtin and its Unix half. Set `STEAM_COMPAT_CLIENT_INSTALL_PATH` to the
installed macOS Steam `Contents/MacOS` directory containing `steamclient.dylib`.

Steam for Mac must already be running and signed in. Having `steamclient.dylib`
present on disk is insufficient: LSC can load the library and return SteamClient023
while `CreateSteamPipe` still returns zero because the native client is closed.
The probe reports this as `native_steam_pipe_unavailable`, separately from DLL
resolution or ABI failures.

The probe loads the forwarded DLL and verifies the actual Wine version, LSC module,
SteamClient023 interface, a native Steam user, login state, and whether the Aion 2
subscription is visible. It releases the pipe/user it created. It never requests
or prints account identifiers, credentials, authentication tickets, or callback
bodies. It does not stop or restart the existing Steam client.
Before registering a new version, verify the vendor archive digest, selected Wine
source commit, runtime version and ntdll hash, component provenance and all PE
forwarders. In a new prefix, finish `cmd.exe /c ver` and run both architectures
through the final `steam.exe` launcher path; require both probes to return zero
with the intended native session available. Use a new engine id such as
`wine-11.19` so the existing 11.17 and 11.18 runtimes and prefixes remain available.

Success demonstrates the bridge can contact the current macOS Steam session.
It does not establish that Aion 2 starts, its graphics backend works, every Steam
interface is supported, or that 32-bit WOW64 works; test the 32-bit probe separately.
This forwarder exposes the subset already present in LSC, including its existing
stub exports. It is not a byte-for-byte replacement for Valve's Windows DLL.
