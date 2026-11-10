"""Minimal ELF32 little-endian reader: symbols and initialized data (no dependencies)."""
import struct


class Elf:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.raw = f.read()
        d = self.raw
        if d[:4] != b"\x7fELF" or d[4] != 1 or d[5] != 1:
            raise ValueError(f"{path}: not a little-endian ELF32 file")
        (_, _, _, _, phoff, shoff, _, _, phentsize, phnum, shentsize, shnum,
         _) = struct.unpack_from("<HHIIIIIHHHHHH", d, 16)
        self.segs = []
        for i in range(phnum):
            p_type, off, vaddr, _, filesz, memsz, _, _ = struct.unpack_from(
                "<8I", d, phoff + i * phentsize)
            if p_type == 1:
                self.segs.append((vaddr, off, filesz, memsz))
        secs = [struct.unpack_from("<10I", d, shoff + i * shentsize) for i in range(shnum)]
        self.syms = {}
        for s in secs:
            if s[1] != 2:  # SHT_SYMTAB
                continue
            strtab = secs[s[6]]
            for j in range(s[5] // 16):
                name, value, size, _, _, _ = struct.unpack_from("<IIIBBH", d, s[4] + j * 16)
                if not name:
                    continue
                end = d.index(b"\0", strtab[4] + name)
                self.syms[d[strtab[4] + name:end].decode()] = (value, size)

    def read(self, addr, size):
        """Initialized bytes at addr (None if not in a file-backed segment)."""
        for vaddr, off, filesz, _ in self.segs:
            if vaddr <= addr and addr + size <= vaddr + filesz:
                return self.raw[off + addr - vaddr: off + addr - vaddr + size]
        return None

    def sym(self, name):
        """Initialized bytes of a symbol, or None."""
        if name not in self.syms:
            return None
        return self.read(*self.syms[name])
