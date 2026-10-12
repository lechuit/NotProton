# Build the stock Wine 11.17 LSC bridge

`build-lsteamclient.sh` reproduces the bridge component build used by the stock
Wine experiment. It builds the x86_64/i386 PE LSC DLLs, the x86_64 macOS Unix LSC
half, and the x86_64 Steam PE shim. It does not rebuild the Wine loader, wineserver,
or Unix ntdll, and it does not install into an application or prefix.

The Wine source is pinned to `wine-11.17`, commit
`36b6a2cf679fb395f668a917b76537190e212d9c`. The existing LSC fetcher verifies Valve's
Proton source tree against its recorded content digest; shim headers retain their
individual hash checks. All fetched sources stay under the supplied workspace.

## Requirements

Use macOS with Xcode command-line tools, Git, rsync, flex, Python 3, an existing
LLVM MinGW toolchain containing both x86_64 and i686 compiler wrappers, and bison
3.0 or newer. The tested toolchain is
`llvm-mingw-20261006-ucrt-macos-universal`; the tested bison is 3.8.2. The helper
installs no package-manager dependencies. The source/build paths must have no
whitespace because Wine's generated make rules do not safely represent it.
Runtime and output paths may contain spaces.

The supplied runtime must report `wine-11.17` and contain its stock x86_64
`lib/wine/x86_64-unix/ntdll.so`. The helper copies that file into its build tree
only as the Unix bridge link input. Its hash is recorded in the output provenance;
deployment must require the same ntdll hash. This was tested with the independent
Gcenx Wine Devel 11.17 macOS runtime, not a CrossOver ntdll.

## Build

```sh
sh bridge/wine-native/build-lsteamclient.sh \
  --toolchain /absolute/path/to/llvm-mingw \
  --bison /absolute/path/to/bison \
  --runtime-root '/absolute/path/to/Wine Devel.app/Contents/Resources/wine' \
  --work /absolute/path/to/private-wine-native-work \
  --output /absolute/path/to/private-lsc-output \
  --jobs 2
```

The workspace contains `source/`, `build/`, `proton-lsc/`, `lsteamclient/`, and
`proton-headers-cache/`. To reuse previously configured, matching trees, pass
`--source /path/to/wine-source --build /path/to/wine-build`. The helper refuses a
different source commit, build host, Wine version, or source directory. PE make
also builds the required headers, tools, import libraries and C++ runtime libraries;
these are build dependencies rather than a complete Wine runtime build.

The Unix compile/link always uses Apple's `/usr/bin/clang++` explicitly so a
toolchain-local clang cannot accidentally replace the macOS compiler. It names
`-arch x86_64` on every Unix object and link. `ntdll.so` remains unchanged; only
the resulting LSC library's dependency name is changed to `@rpath/ntdll.so`, with
`@loader_path` in its rpath. Deployment places the unchanged matching ntdll beside
this Unix bridge. The x86_64 Unix bridge must remain unsigned.

The output contains:

- `x86_64-windows/lsteamclient.dll`
- `i386-windows/lsteamclient.dll`
- `x86_64-unix/lsteamclient.so`
- `x86_64-windows/steam.exe`
- `lsteamclient-provenance.json`

The provenance records source pins, artifact hashes and the runtime ntdll hash.
Verification checks PE architectures, Unix architecture/signing state, required
Wine Unix symbol exports, and absence of the shim's ole32 import. These checks do
not establish that the bridge can contact a native Steam session or run a game.

Next build the Windows-name forwarding DLLs with `build.sh`, passing the output
LSC DLLs and `WORK/lsteamclient/steamworks_sdk_165`. The LSC output alone is not a
complete native Steam bridge package: add validated forwarders, create the complete
bridge manifest and run the isolated Steam probe described in `README.md`.
