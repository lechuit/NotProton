#!/usr/bin/env python3
"""Check vendor version/source refusal gates without fetching or building Wine."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
COMMITS = {"11.17": "36b6a2cf679fb395f668a917b76537190e212d9c",
           "11.18": "7b3fff76fa5178f6ce0141b2c776afa2a822f101",
           "11.19": "455e3509b98a6919fd4ad1def4803e08c41c03b2"}


class VersionPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="np-wine-version-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "tools"
        self.bin.mkdir()
        self.work = self.root / "workspace"
        self.output = self.root / "output"
        self.runtime = self.root / "Wine runtime with spaces"
        self.ntdll = self.runtime / "lib/wine/x86_64-unix/ntdll.so"
        self.ntdll.parent.mkdir(parents=True)
        self.ntdll.write_bytes(b"unchanged stock runtime")
        self.executable(self.runtime / "bin/wine", 'printf "%s\\n" "$TEST_RUNTIME_VERSION"')
        self.toolchain = self.root / "toolchain"
        for name in ("x86_64-w64-mingw32-gcc", "x86_64-w64-mingw32-g++",
                     "i686-w64-mingw32-gcc", "i686-w64-mingw32-g++"):
            self.executable(self.toolchain / "bin" / name, "exit 95")
        self.bison = self.executable(self.bin / "bison", 'if [ "$1" = --version ]; then echo "bison 3.8.2"; else cat >/dev/null; fi')
        self.executable(self.bin / "uname", "echo Darwin")
        self.executable(self.bin / "lipo", "echo x86_64")
        self.executable(self.bin / "git", 'if [ "$3" = rev-parse ]; then echo "$TEST_SOURCE_COMMIT"; else exit 95; fi')
        for name in ("make", "flex", "rsync", "xcrun", "nm", "otool", "install_name_tool", "codesign"):
            self.executable(self.bin / name, "exit 95")
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        TEST_RUNTIME_VERSION="wine-11.17", TEST_SOURCE_COMMIT=COMMITS["11.17"])

    def executable(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/bin/sh\nset -eu\n{body}\n")
        path.chmod(0o755)
        return path

    def invoke(self, version=None, extra=()):
        args = ["sh", str(HERE / "build-lsteamclient.sh"), "--toolchain", str(self.toolchain),
                "--bison", str(self.bison), "--runtime-root", str(self.runtime),
                "--work", str(self.work), "--output", str(self.output)]
        if version is not None:
            args += ["--wine-version", version]
        result = subprocess.run(args + list(extra), env=self.env, text=True,
                                capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(result.returncode, 95, "Preflight must refuse before fetching/building")
        self.assertFalse(self.output.exists())
        self.assertEqual(self.ntdll.read_bytes(), b"unchanged stock runtime")
        return result.stderr

    def source(self):
        source = self.work / "source"
        (source / ".git").mkdir(parents=True)
        return source

    def test_default_remains_exact_11_17(self):
        self.env["TEST_RUNTIME_VERSION"] = "wine-11.18"
        self.assertIn("expected wine-11.17", self.invoke())
        self.assertFalse(self.work.exists())

    def test_11_18_rejects_11_17_runtime(self):
        self.assertIn("expected wine-11.18", self.invoke("11.18"))
        self.assertFalse(self.work.exists())

    def test_runtime_staging_is_rejected(self):
        for version in COMMITS:
            with self.subTest(version=version):
                self.env["TEST_RUNTIME_VERSION"] = f"wine-{version} (Staging)"
                self.assertIn(f"expected wine-{version}", self.invoke(version))
                self.assertFalse(self.work.exists())

    def test_11_19_rejects_other_runtime_versions(self):
        for actual in ("11.17", "11.18", "11.20"):
            with self.subTest(actual=actual):
                self.env["TEST_RUNTIME_VERSION"] = f"wine-{actual}"
                self.assertIn("expected wine-11.19", self.invoke("11.19"))
                self.assertFalse(self.work.exists())

    def test_unknown_versions_are_rejected_by_both_helpers(self):
        for version in ("11.20", "11.18 (Staging)", "11.19 (Staging)", "wine-11.19"):
            with self.subTest(version=version):
                self.assertIn("Unsupported --wine-version", self.invoke(version))
                result = subprocess.run(["sh", str(HERE / "build.sh"), "--wine-version", version,
                                         "--output", str(self.output)], text=True, capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Unsupported --wine-version", result.stderr)
                self.assertFalse(self.work.exists())
                self.assertFalse(self.output.exists())

    def test_matching_runtime_cannot_use_other_source_commit(self):
        self.source()
        for version, other in ((version, other) for version in COMMITS for other in COMMITS if version != other):
            with self.subTest(version=version):
                self.env["TEST_RUNTIME_VERSION"] = f"wine-{version}"
                self.env["TEST_SOURCE_COMMIT"] = COMMITS[other]
                self.assertIn(f"not pinned commit {COMMITS[version]}", self.invoke(version))
                self.assertFalse((self.work / "build").exists())

    def test_matching_source_cannot_reuse_another_version_build(self):
        source = self.source()
        build = self.work / "build"
        (build / "include").mkdir(parents=True)
        (build / "Makefile").write_text(f"srcdir = {source}\n")
        (build / "config.status").write_text("host_cpu = x86_64\n")
        for version, other in ((version, other) for version in COMMITS for other in COMMITS if version != other):
            with self.subTest(version=version, other=other):
                self.env.update(TEST_RUNTIME_VERSION=f"wine-{version}", TEST_SOURCE_COMMIT=COMMITS[version])
                (build / "include/config.h").write_text(f'#define PACKAGE_VERSION "{other}"\n')
                self.assertIn(f"Existing build is not Wine {version}", self.invoke(version))
                self.assertFalse((source / "dlls/lsteamclient").exists())

    def test_probe_compiler_receives_exact_version_for_both_architectures(self):
        # Replace build dependencies in this private fixture, never compile or run Wine.
        harness = self.root / "builder with spaces"
        harness.mkdir()
        shutil.copyfile(HERE / "build.sh", harness / "build.sh")
        (harness / "forwarders.py").write_text("import sys\n")
        sdk = self.root / "SDK with spaces"
        sdk.mkdir()
        (sdk / "steam_api.h").write_text("// fixture headers\n")
        record = self.root / "compiler-args.jsonl"
        compiler = ("import json, os, sys\n"
                    "with open(os.environ['TEST_COMPILER_RECORD'], 'a') as f:\n"
                    "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n")
        for arch in ("x86_64", "i686"):
            self.executable(self.toolchain / f"bin/{arch}-w64-mingw32-clang", "exit 0")
            path = self.toolchain / f"bin/{arch}-w64-mingw32-clang++"
            path.write_text("#!/usr/bin/env python3\n" + compiler)
            path.chmod(0o755)
        self.executable(self.toolchain / "bin/lld-link", "exit 0")
        for version in COMMITS:
            with self.subTest(version=version):
                record.unlink(missing_ok=True)
                args = ["sh", str(harness / "build.sh"), "--toolchain", str(self.toolchain),
                        "--lsteamclient-x64", str(self.root / "x64.dll"),
                        "--lsteamclient-x86", str(self.root / "x86.dll"),
                        "--sdk-root", str(sdk), "--output", str(self.root / f"probe {version}")]
                if version != "11.17":
                    args += ["--wine-version", version]
                result = subprocess.run(args, env=dict(self.env, TEST_COMPILER_RECORD=str(record)),
                                        text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in record.read_text().splitlines()]
                self.assertEqual(len(calls), 2)
                for call in calls:
                    self.assertIn(f'-DNP_EXPECTED_WINE_VERSION="{version}"', call)
                    self.assertEqual(call.count(f'-DNP_EXPECTED_WINE_VERSION="{version}"'), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
