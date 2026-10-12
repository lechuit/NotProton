#!/usr/bin/env python3
"""Exercise PE identity and fail-closed forwarding checks on actual build output."""
import argparse
import contextlib
import io
import struct
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import forwarders


class ForwarderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.original = Path(FIXTURE.forwarder).read_bytes()

    def modified(self, edit):
        data = bytearray(self.original)
        edit(data)
        path = Path(self.temp.name) / "modified.dll"
        path.write_bytes(data)
        return path

    def verify(self, path):
        args = SimpleNamespace(reference=FIXTURE.reference, forwarder=path,
                               module=FIXTURE.module, report=None)
        with contextlib.redirect_stdout(io.StringIO()):
            forwarders.verify(args)

    def test_built_forwarder_matches_reference(self):
        self.verify(FIXTURE.forwarder)

    def test_tampered_forwarding_target_rejected(self):
        def edit(data):
            offset = data.index(b"lsteamclient.CreateInterface\0")
            data[offset] = ord("x")
        with self.assertRaisesRegex(ValueError, "targets differ"):
            self.verify(self.modified(edit))

    def test_executable_entry_point_rejected(self):
        def edit(data):
            pe = struct.unpack_from("<I", data, 0x3C)[0]
            struct.pack_into("<I", data, pe + 24 + 16, 0x1000)
        with self.assertRaisesRegex(ValueError, "entry point or imports"):
            self.verify(self.modified(edit))

    def test_import_directory_rejected(self):
        def edit(data):
            pe = struct.unpack_from("<I", data, 0x3C)[0]
            opt = pe + 24
            magic = struct.unpack_from("<H", data, opt)[0]
            dirs = opt + (112 if magic == 0x20B else 96)
            struct.pack_into("<II", data, dirs + 8, 0x1000, 20)
        with self.assertRaisesRegex(ValueError, "entry point or imports"):
            self.verify(self.modified(edit))

    def test_read_only_interface_reserve_rejected(self):
        def edit(data):
            pe = struct.unpack_from("<I", data, 0x3C)[0]
            count = struct.unpack_from("<H", data, pe + 6)[0]
            opt_size = struct.unpack_from("<H", data, pe + 20)[0]
            start = pe + 24 + opt_size
            for i in range(count):
                section = start + 40 * i
                if data[section:section + 8].rstrip(b"\0") == b".data":
                    flags = struct.unpack_from("<I", data, section + 36)[0]
                    struct.pack_into("<I", data, section + 36, flags & ~0x80000000)
                    return
            self.fail("Fixture has no data reserve")
        with self.assertRaisesRegex(ValueError, "writable interface reserve"):
            self.verify(self.modified(edit))

    def test_forwarder_cannot_be_reference(self):
        args = SimpleNamespace(reference=FIXTURE.forwarder, module=FIXTURE.module,
                               output=Path(self.temp.name) / "unsafe.def")
        with self.assertRaisesRegex(ValueError, "built lsteamclient"):
            forwarders.generate(args)

    def test_truncated_pe_rejected(self):
        path = Path(self.temp.name) / "truncated.dll"
        path.write_bytes(self.original[:128])
        with self.assertRaises(ValueError):
            self.verify(path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference")
    parser.add_argument("forwarder")
    parser.add_argument("--module", choices=["steamclient", "steamclient64"], required=True)
    FIXTURE = parser.parse_args()
    unittest.main(argv=["test_forwarders"], verbosity=2)
