# NotProton

## Experimental independent Wine support in this fork

This fork can register an independent Wine runtime exported by Whisky Lab. In
NotProton choose **Setup > Import Experimental Wine Engine**, or run:

```sh
"/Applications/NotProton Lab.app/Contents/MacOS/NotProtonApp" --import-wine-engine "/absolute/path/runtime-descriptor.json"
```

Restart Steam and select the engine marked **Experimental** in a game's
Compatibility settings. The descriptor schema is:

```json
{
  "schemaVersion": 1,
  "id": "wine-11.17",
  "displayName": "Wine 11.17",
  "backend": "wine",
  "root": "/absolute/canonical/path/to/wine",
  "wineLoader": "bin/wine",
  "wineServer": "bin/wineserver",
  "steamAPI": "unavailable"
}
```

`bin/wine64` is also accepted. Both executable paths must stay within the same
runtime root, including when they are symlinks. Registration pins their SHA256
hashes; import again after updating Wine. CrossOver cannot be imported under this
provider, and all existing CrossOver licensing and trial checks remain active.

**Version 1 is a raw Wine launcher without a native SteamAPI bridge.** Games
that need SteamAPI require the real Windows Steam client running in this Wine
prefix. No native Steam Input, overlay, automatic graphics installation, or Steam
Cloud support is claimed. Aion 2 compatibility is unverified. Neither Whisky's UI
nor this registration makes an unsupported anti-cheat work.
The raw wrapper tracks the launched Wine process, rather than waiting for every
process in the prefix; Windows Steam can therefore remain open after a game exits.
Launchers that exit before handing off to a child game are not yet tracked.

### Experimental native SteamAPI mode

Version 2 adds a separately rebuilt native SteamAPI bridge for the exact supported
Wine 11.17 runtime. Steam for Mac must be running and signed in; this mode does
not install or run Windows Steam. It still provides no Steam Input or overlay
bridge and installs no graphics translation libraries. A successful SteamAPI
probe does not establish Aion 2 or anti-cheat compatibility.

```json
{
  "schemaVersion": 2,
  "id": "wine-11.17",
  "displayName": "Wine 11.17 Native Steam",
  "backend": "wine",
  "root": "/absolute/canonical/path/to/wine",
  "wineLoader": "bin/wine",
  "wineServer": "bin/wineserver",
  "steamAPI": "native",
  "bridgeRoot": "/absolute/path/to/rebuilt-native-bridge"
}
```

The bridge root contains `bridge-manifest.json` with schema version 1, Wine version
`11.17`, source commit `36b6a2cf679fb395f668a917b76537190e212d9c`, the exact
runtime `ntdll.so` SHA256, and hashes for this fixed file set:

- `x86_64-windows/lsteamclient.dll`, `steamclient64.dll`, and `steam.exe`
- `i386-windows/lsteamclient.dll` and `steamclient.dll`
- `x86_64-unix/lsteamclient.so`

The importer copies these bridge files into an immutable managed directory and
links its Unix half to the **canonical runtime ntdll.so**. A separate copy of that
image loads duplicate Wine globals and can crash the bridge, even when its bytes
are identical. This one link must point to the exact runtime image; other bridge
symlinks are rejected. Both copied files and the actual runtime ntdll.so are
checked again before each launch. Wine, CrossOver, and
their original ntdll files are never replaced. The native tool is named
`notproton-wine-native-<id>`, and its prefix is separate from the raw engine's
prefix. Raw descriptor ids beginning `native-` are reserved to prevent collisions.

For game launches the wrapper initializes Wine, stages the bridge into the prefix,
and launches the rebuilt `steam.exe` helper with the original target and arguments.
The helper publishes Steam registry discovery data and forwards SteamAPI calls to
the native client; it is not the Windows Steam client. `runinprefix` remains a direct
Wine helper verb. Missing/mismatched bridge files or native client libraries cause
a clear refusal and never fall back to raw Wine. Existing CrossOver or unknown
Windows Steam prefixes are refused without modifying them.

Each raw engine's prefix lives at
`<STEAM_COMPAT_DATA_PATH>/notproton-wine/<engine-id>/pfx`; logs are alongside it as
`notproton-wine.log`. The launcher never deploys CrossOver's ntdll patches or
copies its graphics libraries. It refuses an existing `pfx` or `notproton-build`
record before changing that game's directory. Back up the existing compatibility
data directory and choose a fresh directory for these experiments. Launch
arguments are omitted from the wrapper log because they can contain login tokens;
output produced by Wine or the Windows program itself can still be sensitive.
Native prefixes use `notproton-wine/native-<engine-id>/pfx` and the same log name.

The independent registry is stored in `notproton/wine-tools`, separate from
CrossOver's registry, so CrossOver setup and Steam startup preserve it. Run
`make winecheck compatcheck` and
`swift test --package-path app --no-parallel --filter IndependentWineTests` for
isolated checks. A functioning Wine runtime and Windows Steam/game smoke tests
are still required to establish actual game support.

The separately packaged NotProton Lab app sets `NPDisableUpdates=true` in its
`Info.plist`, disabling Sparkle and hiding Check for Updates so an official release
does not replace this experimental fork. Builds without that opt-in keep upstream
update behavior. Update Lab manually from this fork.

## CrossOver 14-day trial support in this fork

The `crossover-14-day-trial` branch accepts the official CrossOver trial for
14 days from the first launch recorded by CrossOver. Open CrossOver once to
initialize the trial, then set up its compatibility tool in NotProton.

NotProton checks eligibility both during setup and before each game launch.
At exactly 14 days the trial is refused, with a message linking to the
CodeWeavers store. Missing, unreadable, or future trial dates are refused.
Signed paid licenses continue to work, even after the trial expires; an
invalid license cannot fall back to a trial.

This fork never changes CrossOver's trial date, license files, or the system
clock. Trial support does not establish compatibility with any particular
game or anti-cheat system. Already running games are not forcibly terminated
at expiry; subsequent launches are refused.

Trial date checks depend on CrossOver's locally recorded preferences and the
system clock; they are not a tamper-resistant licensing system.

The implementation adapts [upstream PR #85](https://github.com/NotProtonNot/NotProton/pull/85)
by Geronimo Castaño, preserving its commit authorship, and adds a required
bundle key at launch plus an isolated test clock rather than a production
environment variable override.

Validation: `make licensecheck` checks paid signatures, valid and expired
trials, the exact expiry boundary, and missing/invalid/future trial dates.
`swift test --package-path app --no-parallel --filter CrossOverLicenseTests`
checks the application-side rule.


NotProton enables the Steam Play experience from Linux Steam in the macOS Steam client.

This is done by forcibly enabling the Steam Play functionality in macOS Steam (which is
present and inert) as well as by porting some components of Valve's Proton to macOS.

This tool is intended to be used with the stable Steam Client (version 1788652215) as well as the beta Steam Client (version 1791686101) paired with **CrossOver 26.3 or CrossOver Preview
20261006 or 2026082**, with more supported versions to come. 

Supporting specifically CrossOver is a design goal of this project. Better support for modifying CrossOver (using custom builds of DXMT/patched D3DMetal/MacGameVideoFix) will come in a future update, but support for alternatives to CrossOver itself is not planned.

Both the FEX and the Rosetta versions are supported. I recommend using the FEX version of the 
Preview 20261006, as it includes both the FEX version as well as the Rosetta one. 

I further recommend going into Steam Settings - Compatibility and selecting the Rosetta version as your default compatibility tool. You can select FEX on a per game basis by right clicking a game in Steam, going into Properties - Compatibility and selecting FEX there.

If a game has a native macOS version as well as a Windows one, Steam will download the macOS version. To override this behavior, right click on the game, select Properties, select Compatibility. Enable 'Force the use of a specific Steam Play compatibility tool'. Select whichever version of CrossOver you want to do use. That will make Steam download the Windows version. Unchecking the 'Force the use...' box or selecting 'No Compatibility Tool' in the drop down list will revert to the macOS version of the game, with the specifics there varying based on your Steam version.

**Valve Anti-Cheat is not supported.** Proton itself does not support VAC in Valve titles; Valve ships native Linux ports instead. VAC titles will launch in Insecure Mode and will not allow matchmaking. 

**This project now has a brew cask.** For brew users, you can install via ``brew install --cask notprotonnot/notproton/notproton``

Please read NOTICE for license information.

Please open issue reports with any issues. PRs are welcome and encouraged.

There are many people who worked on similar ideas, similar projects. I did not base NotProton on their work, but I still want to 
give thanks to the people who came before me:

[Nat Brown](https://github.com/natbro) made [Kaon](https://github.com/natbro/kaon), which is similar in goals to NotProton.

mont127's [Neutron](https://github.com/mont127/Neutron) is also a similar idea, but implemented differently. 

[Gio](https://github.com/giodotblue) was working enabling Steam Play inside of Steam on macOS prior to the release of NotProton itself. 
I would have done things differently had I been aware of that. 

Thanks to everyone who has positively contributed to macOS gaming. 

Developer Notes:

As far as the source structure goes, the macOS app itself is located in the ```app``` folder. The core logic is in ```dylib```.
```lsteamclient``` is a macOS port of Valve's lsteamclient. ```steam-shim```is a port of Valve's
steam-helper from Proton 9. ntdll-patch patches the copy of CrossOver that the app
makes/places in the ```~/Library/Application Support/notproton/runners/``` folder so that
lsteamclient is loaded.
