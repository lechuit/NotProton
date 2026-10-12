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
                        CX_TEST="inherited", NOTPROTON_TEST="inherited")

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


if __name__ == "__main__":
    unittest.main()
