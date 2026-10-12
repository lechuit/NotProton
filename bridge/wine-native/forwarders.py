#!/usr/bin/env python3
"""Build descriptions and verify native PE forwarders against a built LSC DLL.

Export ordinals come from the PE itself, including Wine's auto-numbered exports.
Nothing here edits ntdll or a user's prefix.
"""

import argparse
import hashlib
import json
import re
import struct
from pathlib import Path


class PE:
    def __init__(self, path):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        if self.data[:2] != b"MZ" or len(self.data) < 64:
            raise ValueError("Not a PE image")
        pe = self.u32(0x3C)
        if self.bytes(pe, 4) != b"PE\0\0":
            raise ValueError("Invalid PE signature")
        self.machine, count = self.unpack("<HH", pe + 4)
        opt_size, characteristics = self.unpack("<HH", pe + 20)
        if not characteristics & 0x2000:
            raise ValueError("Reference or forwarder is not a DLL")
        opt = pe + 24
        magic = self.u16(opt)
        if magic == 0x20B and self.machine == 0x8664:
            dirs = opt + 112
        elif magic == 0x10B and self.machine == 0x14C:
            dirs = opt + 96
        else:
            raise ValueError("Expected an x86_64 or i386 Windows PE DLL")
        if count > 96 or opt_size < dirs - opt + 16:
            raise ValueError("Invalid PE section or optional header")
        self.size_headers = self.u32(opt + 60)
        self.entry = self.u32(opt + 16)
        self.export_rva, self.export_size = self.unpack("<II", dirs)
        self.import_rva, self.import_size = self.unpack("<II", dirs + 8)
        self.sections = []
        start = opt + opt_size
        for i in range(count):
            offset = start + i * 40
            name = self.bytes(offset, 8).rstrip(b"\0").decode("ascii")
            virtual_size, rva, raw_size, raw = self.unpack("<IIII", offset + 8)
            flags = self.u32(offset + 36)
            self.sections.append((name, rva, virtual_size, raw, raw_size, flags))
        self.exports, self.module = self.read_exports()

    def bytes(self, offset, size):
        if offset < 0 or size < 0 or offset + size > len(self.data):
            raise ValueError("PE structure exceeds file bounds")
        return self.data[offset : offset + size]

    def unpack(self, fmt, offset):
        return struct.unpack(fmt, self.bytes(offset, struct.calcsize(fmt)))

    def u16(self, offset):
        return self.unpack("<H", offset)[0]

    def u32(self, offset):
        return self.unpack("<I", offset)[0]

    def offset(self, rva, size=1):
        if rva < self.size_headers and rva + size <= self.size_headers:
            self.bytes(rva, size)
            return rva
        for _, start, _, raw, raw_size, _ in self.sections:
            if start <= rva and rva + size <= start + raw_size:
                self.bytes(raw + rva - start, size)
                return raw + rva - start
        raise ValueError("PE RVA does not name bytes present in the image")

    def string(self, rva):
        offset = self.offset(rva)
        stop = self.data.find(b"\0", offset, min(len(self.data), offset + 4096))
        if stop < 0:
            raise ValueError("Unterminated PE export string")
        return self.data[offset:stop].decode("ascii")

    def read_exports(self):
        if not self.export_rva or self.export_size < 40:
            raise ValueError("Image has no usable export table")
        export = self.offset(self.export_rva, 40)
        name_rva, base, funcs, names, funcs_rva, names_rva, ords_rva = self.unpack(
            "<IIIIIII", export + 12
        )
        if names > 65535 or funcs > 65535 or not names:
            raise ValueError("Invalid PE export count")
        function_table = self.offset(funcs_rva, funcs * 4)
        name_table = self.offset(names_rva, names * 4)
        ordinal_table = self.offset(ords_rva, names * 2)
        exports = {}
        named_indexes = set()
        for i in range(names):
            name = self.string(self.u32(name_table + i * 4))
            index = self.u16(ordinal_table + i * 2)
            if index >= funcs or name in exports or not re.fullmatch(r"[A-Za-z_]\w*", name):
                raise ValueError("Invalid or duplicate named PE export")
            rva = self.u32(function_table + index * 4)
            if not rva or base + index > 65535:
                raise ValueError("Invalid export address or ordinal")
            target = None
            if self.export_rva <= rva < self.export_rva + self.export_size:
                target = self.string(rva)
            exports[name] = {"ordinal": base + index, "forwarder": target}
            named_indexes.add(index)
        for index in range(funcs):
            if self.u32(function_table + index * 4) and index not in named_indexes:
                raise ValueError("Unnamed exports require a separately reviewed ordinal policy")
        return exports, self.string(name_rva)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def generate(args):
    reference = PE(args.reference)
    expected_machine = 0x8664 if args.module == "steamclient64" else 0x14C
    if reference.machine != expected_machine:
        raise ValueError("Reference architecture does not match forwarder name")
    if reference.module.lower() != "lsteamclient.dll":
        raise ValueError("Reference must be a built lsteamclient.dll")
    if any(item["forwarder"] for item in reference.exports.values()):
        raise ValueError("The LSC reference must export implementations directly")
    lines = [f"LIBRARY {args.module}.dll", "EXPORTS"]
    for name, item in sorted(reference.exports.items(), key=lambda entry: (entry[1]["ordinal"], entry[0])):
        lines.append(f"    {name}=lsteamclient.{name} @{item['ordinal']}")
    Path(args.output).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Generated {args.module}: {len(reference.exports)} exports from built LSC PE")


def verify(args):
    reference = PE(args.reference)
    forwarder = PE(args.forwarder)
    if reference.machine != forwarder.machine:
        raise ValueError("Forwarder architecture differs from its LSC")
    if forwarder.module.lower() != args.module + ".dll":
        raise ValueError("Incorrect forwarder module identity")
    if forwarder.entry or forwarder.import_rva or forwarder.import_size:
        raise ValueError("Forwarder unexpectedly has an entry point or imports")
    expected = {
        name: {"ordinal": item["ordinal"], "forwarder": "lsteamclient." + name}
        for name, item in reference.exports.items()
    }
    if forwarder.exports != expected:
        raise ValueError("Forwarder names, ordinals, or targets differ from built LSC")
    writable_data = sum(
        raw_size for name, _, _, _, raw_size, flags in forwarder.sections
        if name == ".data" and flags & 0x80000000
    )
    if writable_data < 65536:
        raise ValueError("Forwarder lacks the 64 KiB initialized writable interface reserve")
    result = {
        "module": args.module + ".dll",
        "machine": hex(forwarder.machine),
        "exports": len(expected),
        "initializedWritableDataBytes": writable_data,
        "lsteamclientSHA256": digest(args.reference),
        "forwarderSHA256": digest(args.forwarder),
        "imports": [],
        "entryPoint": 0,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    generation = commands.add_parser("generate")
    generation.add_argument("reference")
    generation.add_argument("--module", choices=["steamclient", "steamclient64"], required=True)
    generation.add_argument("--output", required=True)
    generation.set_defaults(run=generate)
    validation = commands.add_parser("verify")
    validation.add_argument("reference")
    validation.add_argument("forwarder")
    validation.add_argument("--module", choices=["steamclient", "steamclient64"], required=True)
    validation.add_argument("--report")
    validation.set_defaults(run=verify)
    args = parser.parse_args()
    try:
        args.run(args)
    except (OSError, ValueError, struct.error, UnicodeError) as error:
        parser.exit(1, f"forwarders: {error}\n")


if __name__ == "__main__":
    main()
