#!/usr/bin/env python3
"""Exercise the raw Wine runner without starting Steam or a real Wine process."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(sys.argv.pop(1) if len(sys.argv) > 1 else "dylib/feats/compat_wine_run.sh").resolve()


class WineRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="np wine tests ")
        self.base = Path(self.temp.name).resolve()
        self.home = self.base / "home"
        self.tool = self.base / "Steam tools/notproton-wine-test"
        self.runtime = self.base / "Wine runtime with spaces"
        self.tool.mkdir(parents=True)
        (self.runtime / "bin").mkdir(parents=True)
        self.loader = self.runtime / "bin/wine"
        self.server = self.runtime / "bin/wineserver"
        self.loader.write_text('#!/bin/sh\nprintf "prefix=[%s]\\n" "$WINEPREFIX"\n'
                               'printf "bridge=[%s]\\n" "${WINEDLLPATH:-unset}"\n'
                               'printf "cx=[%s] dxmt=[%s] d3dm=[%s] msync=[%s]\\n" "${CX_GRAPHICS_BACKEND:-unset}" "${DXMT_CONFIG:-unset}" "${D3DM_ENABLE_METALFX:-unset}" "${WINEMSYNC:-unset}"\n'
                               'printf "arch=[%s] esync=[%s] dyld=[%s] fallback=[%s] customcx=[%s] np=[%s]\\n" "${WINEARCH:-unset}" "${WINEESYNC:-unset}" "${DYLD_LIBRARY_PATH:-unset}" "${DYLD_FALLBACK_LIBRARY_PATH:-unset}" "${CX_TEST:-unset}" "${NOTPROTON_TEST:-unset}"\n'
                               'printf "avx=[%s] other_rosetta=[%s]\\n" "${ROSETTA_ADVERTISE_AVX-unset}" "${ROSETTA_TEST-unset}"\n'
                               'for a in "$@"; do printf "passed=[%s]\\n" "$a"; done\n'
                               'exit "${FAKE_WINE_STATUS:-0}"\n')
        self.server.write_text('#!/bin/sh\nprintf "server=[%s]\\n" "$*"\nexit 0\n')
        self.loader.chmod(0o755)
        self.server.chmod(0o755)
        shutil.copyfile(SCRIPT, self.tool / "run")
        (self.tool / "build").write_text("wine-test\n")
        self.record = self.home / "Library/Application Support/notproton/runners/wine-test/runtime.v1"
        self.record.parent.mkdir(parents=True)
        self.write_record()
        self.data = self.base / "compatdata with spaces/42"
        self.prefix_root = self.data / "notproton-wine/test"
        self.env = dict(os.environ, HOME=str(self.home), STEAM_COMPAT_DATA_PATH=str(self.data),
                        WINEDLLPATH="foreign native Steam bridge", CX_ROOT="CrossOver",
                        CX_GRAPHICS_BACKEND="d3dmetal", DXMT_CONFIG="old setting", D3DM_ENABLE_METALFX="1", WINEMSYNC="1",
                        WINEARCH="win32", WINEESYNC="1", DYLD_LIBRARY_PATH="foreign dylibs", DYLD_FALLBACK_LIBRARY_PATH="foreign fallback",
                        CX_TEST="inherited", NOTPROTON_TEST="inherited", ROSETTA_TEST="inherited")
        self.env.pop("ROSETTA_ADVERTISE_AVX", None)

    def tearDown(self):
        self.temp.cleanup()

    def write_record(self):
        self.record.write_text("\n".join(["1", "test", str(self.runtime), "bin/wine", "bin/wineserver",
                                         hashlib.sha256(self.loader.read_bytes()).hexdigest(),
                                         hashlib.sha256(self.server.read_bytes()).hexdigest()]) + "\n")

    def run_tool(self, verb="waitforexitandrun", *arguments):
        return subprocess.run(["/bin/sh", str(self.tool / "run"), verb, *arguments], env=self.env,
                              text=True, capture_output=True, timeout=10)

    def test_arguments_and_isolated_prefix(self):
        result = self.run_tool("waitforexitandrun", "/game with spaces/AION2.exe", "--name", "literal $(`text`)")
        self.assertEqual(result.returncode, 0, result.stderr)
        log = (self.prefix_root / "notproton-wine.log").read_text()
        self.assertIn(f"prefix=[{self.prefix_root / 'pfx'}]", log)
        self.assertIn("passed=[/game with spaces/AION2.exe]", log)
        self.assertIn("passed=[literal $(`text`)]", log)
        self.assertIn("bridge=[unset]", log)
        self.assertIn("cx=[unset] dxmt=[unset] d3dm=[unset] msync=[unset]", log)
        self.assertIn("arch=[unset] esync=[unset] dyld=[unset] fallback=[unset] customcx=[unset] np=[unset]", log)
        self.assertNotIn("server=[-w]", log)
        self.assertFalse((self.data / "pfx").exists())

    def test_nonzero_exit_preserved(self):
        self.env["FAKE_WINE_STATUS"] = "37"
        result = self.run_tool("run", "/game.exe")
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertIn("status=37", (self.prefix_root / "notproton-wine.log").read_text())

    def test_getcompatpath_is_read_only(self):
        result = self.run_tool("getcompatpath")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.prefix_root))
        self.assertFalse(self.data.exists())

    def test_foreign_prefix_refused_without_modification(self):
        (self.data / "pfx").mkdir(parents=True)
        sentinel = self.data / "pfx/save.dat"
        sentinel.write_text("preserve")
        result = self.run_tool("waitforexitandrun", "/game.exe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("existing CrossOver or unknown prefix", result.stderr)
        self.assertEqual(sentinel.read_text(), "preserve")
        self.assertFalse((self.data / "notproton-wine").exists())

    def test_cross_build_record_refused(self):
        self.data.mkdir(parents=True)
        (self.data / "notproton-build").write_text("26.3\n")
        result = self.run_tool("runinprefix", "cmd", "/c", "ver")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.data.iterdir()), [self.data / "notproton-build"])

    def test_tampered_binary_refused_before_mutation(self):
        self.loader.write_text("#!/bin/sh\nexit 0 # changed\n")
        result = self.run_tool("run", "/game.exe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("executables changed", result.stderr)
        self.assertFalse(self.data.exists())

    def test_runtime_symlink_escape_refused(self):
        self.loader.unlink()
        self.loader.symlink_to("/bin/sh")
        self.write_record()
        result = self.run_tool("run", "/game.exe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("leaves its registered root", result.stderr)
        self.assertFalse(self.data.exists())

    def test_prefix_symlink_refused(self):
        victim = self.base / "untouched"
        victim.mkdir()
        self.data.mkdir(parents=True)
        (self.data / "notproton-wine").symlink_to(victim)
        result = self.run_tool("run", "/game.exe")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(victim.iterdir()), [])

    def test_unknown_verb_refused(self):
        result = self.run_tool("delete-prefix")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.data.exists())

    def test_registered_runtime_update_refuses_existing_prefix(self):
        self.assertEqual(self.run_tool("run", "/game.exe").returncode, 0)
        self.loader.write_text(self.loader.read_text() + "# rebuilt runtime\n")
        self.write_record()
        old_log = (self.prefix_root / "notproton-wine.log").read_bytes()
        result = self.run_tool("run", "/game.exe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different engine build", result.stderr)
        self.assertEqual((self.prefix_root / "notproton-wine.log").read_bytes(), old_log)

    def test_persistent_windows_steam_does_not_delay_game_exit(self):
        self.server.write_text('#!/bin/sh\nif [ "$1" = "-w" ]; then sleep 30; fi\nexit 0\n')
        self.write_record()
        result = self.run_tool("waitforexitandrun", "/game.exe")
        self.assertEqual(result.returncode, 0, result.stderr)

    def native_mode(self):
        self.loader.write_text('#!/bin/sh\n'
            'if [ "$1" = cmd.exe ] && [ "$2" = /c ] && [ "$3" = ver ]; then\n'
            '  printf "readiness command completed\\n"\n'
            '  [ "${FAKE_BOOT_STATUS:-0}" = 0 ] || exit "$FAKE_BOOT_STATUS"\n'
            '  mkdir -p "$WINEPREFIX/drive_c/windows/system32"; exit 0\n'
            'fi\n'
            'printf "override=[%s] appid=[%s] gameid=[%s] client=[%s]\\n" "$WINEDLLOVERRIDES" "${SteamAppId:-unset}" "${SteamGameId:-unset}" "$STEAM_COMPAT_CLIENT_INSTALL_PATH"\n'
            'printf "dllpath=[%s]\\n" "$WINEDLLPATH"\n'
            'printf "avx=[%s] other_rosetta=[%s]\\n" "${ROSETTA_ADVERTISE_AVX-unset}" "${ROSETTA_TEST-unset}"\n'
            'for a in "$@"; do printf "passed=[%s]\\n" "$a"; done\n'
            'exit "${FAKE_WINE_STATUS:-0}"\n')
        ntdll = self.runtime / "lib/wine/x86_64-unix/ntdll.so"
        ntdll.parent.mkdir(parents=True)
        ntdll.write_text("stock matching ntdll")
        self.runtime_ntdll = ntdll
        files = ["x86_64-windows/lsteamclient.dll", "x86_64-windows/steamclient64.dll", "x86_64-windows/steam.exe",
                 "i386-windows/lsteamclient.dll", "i386-windows/steamclient.dll", "x86_64-unix/lsteamclient.so",
                 "x86_64-unix/ntdll.so"]
        payload = {name: (ntdll.read_bytes() if name.endswith("ntdll.so") else f"bridge {name}".encode()) for name in files}
        checksums = "".join(f"{hashlib.sha256(payload[name]).hexdigest()}  {name}\n" for name in sorted(files[:-1]))
        checksums += f"{hashlib.sha256(payload[files[-1]]).hexdigest()}  {files[-1]}\n"
        self.bridge_identity = hashlib.sha256(("ntdll-runtime-link-v1\n" + checksums).encode()).hexdigest()
        managed = self.home / "Library/Application Support/notproton/runners/wine-native-test"
        self.bridge = managed / f"bridge-{self.bridge_identity}"
        for name, data in payload.items():
            target = self.bridge / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if name == "x86_64-unix/ntdll.so":
                target.symlink_to(ntdll)
            else:
                target.write_bytes(data)
        (self.bridge / "checksums.sha256").write_text(checksums)
        self.record = managed / "runtime.v1"
        self.record.write_text("\n".join(["2", "native-test", str(self.runtime), "bin/wine", "bin/wineserver",
            hashlib.sha256(self.loader.read_bytes()).hexdigest(), hashlib.sha256(self.server.read_bytes()).hexdigest(),
            self.bridge_identity, hashlib.sha256(ntdll.read_bytes()).hexdigest()]) + "\n")
        (self.tool / "build").write_text("wine-native-test\n")
        self.prefix_root = self.data / "notproton-wine/native-test"
        client = self.base / "native Steam MacOS"
        client.mkdir()
        (client / "steamclient.dylib").write_text("native client fixture")
        self.env.update(STEAM_COMPAT_CLIENT_INSTALL_PATH=str(client), STEAM_COMPAT_APP_ID="3719590")

    def test_native_bootstrap_and_shim_forwarding(self):
        self.native_mode()
        result = self.run_tool("waitforexitandrun", "/game folder/game.exe", "--windowed", "literal $(`text`)")
        self.assertEqual(result.returncode, 0, result.stderr)
        steam = self.prefix_root / "pfx/drive_c/Program Files (x86)/Steam"
        self.assertEqual((steam / "steam.exe").read_bytes(), (self.bridge / "x86_64-windows/steam.exe").read_bytes())
        self.assertTrue((self.prefix_root / "pfx/drive_c/windows/syswow64/lsteamclient.dll").is_file())
        log = (self.prefix_root / "notproton-wine.log").read_text()
        self.assertIn(f"passed=[{steam / 'steam.exe'}]", log)
        self.assertIn("passed=[/game folder/game.exe]", log)
        self.assertIn("passed=[literal $(`text`)]", log)
        self.assertIn("override=[steamclient=n;steamclient64=n;lsteamclient=b] appid=[3719590]", log)
        self.assertIn(f"dllpath=[{self.bridge}:{self.runtime / 'lib/wine'}]", log)
        dll_line = next(line for line in log.splitlines() if line.startswith("dllpath=["))
        self.assertNotIn(str(steam), dll_line)
        self.assertNotIn("x86_64-windows", dll_line)
        self.assertNotIn("i386-windows", dll_line)
        self.assertNotIn("x86_64-unix", dll_line)
        self.assertIn("Experimental native SteamAPI bridge", log)
        self.assertNotIn("No native SteamAPI bridge.", log)

    def check_rosetta_avx_choices(self):
        for supplied in (None, "0", "1", "", "2", "true", "$(literal)"):
            with self.subTest(supplied=supplied):
                if supplied is None:
                    self.env.pop("ROSETTA_ADVERTISE_AVX", None)
                else:
                    self.env["ROSETTA_ADVERTISE_AVX"] = supplied
                result = self.run_tool("runinprefix", "/game with spaces.exe", "--literal", "argument kept")
                self.assertEqual(result.returncode, 0, result.stderr)
                log = (self.prefix_root / "notproton-wine.log").read_text()
                latest = log.rsplit("=== experimental Wine", 1)[-1]
                expected = supplied if supplied in ("0", "1") else "unset"
                self.assertIn(f"avx=[{expected}] other_rosetta=[unset]", latest)
                self.assertIn("passed=[/game with spaces.exe]", latest)
                self.assertIn("passed=[argument kept]", latest)
                if expected == "unset":
                    self.assertNotIn("Requested Rosetta AVX advertisement=", latest)
                else:
                    self.assertIn(f"Requested Rosetta AVX advertisement={expected}", latest)

    def test_raw_rosetta_avx_allows_only_explicit_zero_or_one(self):
        self.check_rosetta_avx_choices()

    def test_native_rosetta_avx_allows_only_explicit_zero_or_one(self):
        self.native_mode()
        self.check_rosetta_avx_choices()

    def test_native_runtime_abi_change_refused_before_write(self):
        self.native_mode()
        self.runtime_ntdll.write_text("updated runtime but same loader")
        result = self.run_tool("waitforexitandrun", "/game.exe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Runtime ntdll.so changed", result.stderr)
        self.assertFalse(self.data.exists())

    def test_native_bridge_corruption_refused_before_write(self):
        self.native_mode()
        (self.bridge / "x86_64-unix/lsteamclient.so").write_text("changed bridge")
        result = self.run_tool("waitforexitandrun", "/game.exe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Native bridge files changed", result.stderr)
        self.assertFalse(self.data.exists())

    def test_native_unknown_windows_steam_prefix_preserved(self):
        self.native_mode()
        steam = self.prefix_root / "pfx/drive_c/Program Files (x86)/Steam"
        steam.mkdir(parents=True)
        (steam / "steam.exe").write_text("real Windows Steam - preserve")
        result = self.run_tool("waitforexitandrun", "/game.exe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Windows Steam or an unknown shim", result.stderr)
        self.assertEqual((steam / "steam.exe").read_text(), "real Windows Steam - preserve")
        self.assertFalse((self.prefix_root / "engine").exists())
        self.assertFalse((self.prefix_root / "notproton-wine.log").exists())

    def test_native_direct_helpers_do_not_use_shim_or_game_identity(self):
        self.native_mode()
        self.env.update(SteamAppId="3719590", SteamGameId="3719590")
        result = self.run_tool("runinprefix", "cmd", "/c", "ver")
        self.assertEqual(result.returncode, 0, result.stderr)
        log = (self.prefix_root / "notproton-wine.log").read_text()
        self.assertIn("passed=[cmd]", log)
        self.assertNotIn("passed=[" + str(self.prefix_root / "pfx/drive_c/Program Files (x86)/Steam/steam.exe") + "]", log)
        self.assertIn("appid=[unset] gameid=[unset]", log)

    def test_native_mode_does_not_fallback_if_client_missing(self):
        self.native_mode()
        self.env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = str(self.base / "missing client")
        result = self.run_tool("waitforexitandrun", "/game.exe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Steam for Mac client library is missing", result.stderr)
        self.assertFalse(self.data.exists())

    def test_native_identical_ntdll_copy_is_refused(self):
        self.native_mode()
        target = self.bridge / "x86_64-unix/ntdll.so"
        target.unlink()
        target.write_bytes(self.runtime_ntdll.read_bytes())
        result = self.run_tool("waitforexitandrun", "/game.exe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must link to the exact runtime image", result.stderr)
        self.assertFalse(self.data.exists())

    def test_native_ntdll_link_to_identical_foreign_copy_is_refused(self):
        self.native_mode()
        foreign = self.base / "identical foreign ntdll.so"
        foreign.write_bytes(self.runtime_ntdll.read_bytes())
        target = self.bridge / "x86_64-unix/ntdll.so"
        target.unlink()
        target.symlink_to(foreign)
        result = self.run_tool("waitforexitandrun", "/game.exe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must link to the exact runtime image", result.stderr)
        self.assertFalse(self.data.exists())

    def test_native_other_bridge_symlinks_are_refused(self):
        self.native_mode()
        target = self.bridge / "x86_64-windows/steamclient64.dll"
        foreign = self.base / "identical forwarder.dll"
        foreign.write_bytes(target.read_bytes())
        target.unlink()
        target.symlink_to(foreign)
        result = self.run_tool("waitforexitandrun", "/game.exe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Only the runtime ntdll link", result.stderr)
        self.assertFalse(self.data.exists())

    def test_native_readiness_does_not_require_immediate_registry_persistence(self):
        self.native_mode()
        result = self.run_tool("waitforexitandrun", "/game.exe")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.prefix_root / "pfx/system.reg").exists())
        log = (self.prefix_root / "notproton-wine.log").read_text()
        self.assertIn("readiness command completed", log)
        self.assertIn("passed=[/game.exe]", log)

    def test_native_failed_readiness_prevents_game_and_bridge_staging(self):
        self.native_mode()
        self.env["FAKE_BOOT_STATUS"] = "31"
        result = self.run_tool("waitforexitandrun", "/game.exe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Wine prefix readiness check failed", result.stderr)
        self.assertFalse((self.prefix_root / "pfx/drive_c/Program Files (x86)/Steam/steam.exe").exists())
        log = (self.prefix_root / "notproton-wine.log").read_text()
        self.assertNotIn("passed=[/game.exe]", log)


if __name__ == "__main__":
    unittest.main()
