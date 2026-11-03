#!/usr/bin/env python3
"""Load a CoralNPU ELF whose code lives in DDR (0x8000_0000) over JTAG, run it,
and print the results it leaves in DTCM.

Upstream (Nexus) does this with nexus_loader over an FTDI SPI link. The VCU118
has no such link, and the RISC-V debug module only reaches ITCM/DTCM, so:

  1. reset-halt the core, put tools/ddr_stub.S at ITCM 0 and run it; it waits
     for the DDR controller's calibration (GPIO bit 0),
  2. with --uart: tell the stub to read each DDR segment from UART1 and stream
     it over the USB-UART (~90 KB/s at 921600). Without it: for each piece,
     halt, write it into ITCM (0x1000..) with the debugger, tell the stub to
     copy it to DDR, resume, wait (~1.3 KB/s: one abstract command per word),
  3. ask the stub for a checksum of every DDR segment and compare,
  4. zero the TCM .bss, load the TCM segments with the debugger,
  5. tell the stub to jump to the ELF entry, then poll (halt, read, resume)
     until the program has stored its return code in `_ret`,
  6. read inference_* / status_msg / the _write line buffer and print them.

Needs the vector_highmem DDR4 bitstream (ITCM 1 MB holds the stub + buffer).
Only the Python standard library is used.

  tools/ddr_run.py --cfg out/openocd_vcu118.cfg model.elf
  tools/ddr_run.py --dry-run model.elf      # only write the OpenOCD script
"""

import argparse
import os
import re
import struct
import subprocess
import sys
import tempfile
import time

# tools/ddr_stub.S assembled with llvm-mc (see the header of that file).
STUB_WORDS = [
    0x001ff437, 0x400304b7, 0x0004a283, 0x00542c23, 0x0012f293,
    0xfe028ae3, 0x0ddc12b7, 0xde128293, 0x00542823, 0x00042283,
    0xfe028ee3, 0x00442503, 0x00842583, 0x00c42603, 0x00100313,
    0x02628063, 0x00200313, 0x02628c63, 0x00300313, 0x04628463,
    0x00400313, 0x06628263, 0x07c0006f, 0x06060663, 0x00052383,
    0x0075a023, 0x00450513, 0x00458593, 0xffc60613, 0xfe0616e3,
    0x0500006f, 0x04060663, 0x0005a023, 0x00458593, 0xffc60613,
    0xfe061ae3, 0x0380006f, 0x00000e13, 0x00060c63, 0x0005a383,
    0x007e0e33, 0x00458593, 0xffc60613, 0xfe0618e3, 0x01c42a23,
    0x0140006f, 0x00042023, 0x0ff0000f, 0x0000100f, 0x00058067,
    0x0ff0000f, 0x00042023, 0xf55ff06f, 0x00500313, 0xfe6298e3,
    0x400103b7, 0x01c42e03, 0x000e0463, 0x01c3a823, 0xfc060ee3,
    0x0143ae03, 0x020e7e13, 0xfe0e1ce3, 0x0183ae03, 0x01c58023,
    0x00158593, 0xfff60613, 0xfe0612e3, 0xfb9ff06f,
]
# Mailbox in DTCM: a core store to ITCM is an access fault (Lsu.scala), so a
# mailbox there traps on the stub's first sw. Top of DTCM, inside the ELF's
# stack, which nothing touches until the stub jumps to the entry.
MBX = 0x1FF000
STATE_READY = 0x0DDC0DE1
BUF = 0x1000           # staging buffer in ITCM
BUF_MAX = 0x100000 - BUF
ITCM_END = 0x100000
DTCM = (0x100000, 0x200000)
DDR_BASE = 0x80000000
MBX_GPIO = 24          # stub publishes GPIO DATA_IN here while waiting
GPIO_UNSEEN = 0xA5A5A5A5   # seeded into MBX_GPIO; gpio_i is 8 bits, so never a real value
MBX_UART_CTRL = 28     # UART1 CTRL value the stub writes before cmd 5
RET_SENTINEL = 0x0BADD00D   # what the crt0 stores in _ret before main()
CLK_HZ = 50000000      # SoC main clock; the UART NCO is derived from it

# DTCM symbols worth reading back, in print order.
RESULT_SYMS = [
    "_ret", "inference_status", "inference_status_code", "inference_stage",
    "inference_argmax", "inference_out_count", "inference_max_value",
    "inference_out_sum", "cyc_setup", "cyc_invoke", "status_msg_len",
    "hp_start", "hp_end", "hp_cur", "hp_sbrk_ok", "hp_malloc_ok",
]
TEXT_SYMS = ["status_msg", "_ZZ6_writeE18_write_line_buffer"]
ARRAY_SYMS = ["inference_output"]


# --------------------------------------------------------------------------
# ELF32 little-endian reader (program headers + symbol table)
def read_elf(path):
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF" or data[4] != 1 or data[5] != 1:
        sys.exit(f"{path}: not a 32-bit little-endian ELF")
    (e_entry, e_phoff, e_shoff) = struct.unpack_from("<III", data, 24)
    (e_phentsize, e_phnum, e_shentsize, e_shnum) = struct.unpack_from("<HHHH", data, 42)
    segs = []
    for i in range(e_phnum):
        p_type, p_off, _vaddr, p_paddr, p_filesz, p_memsz = struct.unpack_from(
            "<IIIIII", data, e_phoff + i * e_phentsize)
        if p_type == 1 and p_memsz:
            segs.append(dict(addr=p_paddr, filesz=p_filesz, memsz=p_memsz,
                             data=data[p_off:p_off + p_filesz]))
    syms = {}
    shdrs = [struct.unpack_from("<IIIIIIIIII", data, e_shoff + i * e_shentsize)
             for i in range(e_shnum)]
    for sh in shdrs:
        if sh[1] != 2:          # SHT_SYMTAB
            continue
        strtab = shdrs[sh[6]]
        for off in range(sh[4], sh[4] + sh[5], 16):
            st_name, st_value, st_size = struct.unpack_from("<III", data, off)
            if not st_name:
                continue
            end = data.index(b"\0", strtab[4] + st_name)
            syms[data[strtab[4] + st_name:end].decode()] = (st_value, st_size)
    return e_entry, segs, syms


def wsum(b):
    b = b + b"\0" * (-len(b) % 4)
    return sum(struct.unpack("<%dI" % (len(b) // 4), b)) & 0xFFFFFFFF


# --------------------------------------------------------------------------
def build_script(elf, tmp, chunk, run_timeout, poll_s, zero_ddr_bss, uart_ctrl=None):
    """uart_ctrl: UART1 CTRL word to stream DDR segments over the USB-UART
    instead of JTAG; the payloads to send are returned in `uart`."""
    entry, segs, syms = read_elf(elf)
    ddr = [s for s in segs if s["addr"] >= DDR_BASE]
    tcm = [s for s in segs if s["addr"] < DDR_BASE]
    for s in tcm:
        if s["addr"] < ITCM_END:
            sys.exit(f"segment at {s['addr']:#x} is in ITCM, which the loader uses itself")
        if not (DTCM[0] <= s["addr"] and s["addr"] + s["memsz"] <= DTCM[1]):
            sys.exit(f"segment at {s['addr']:#x}+{s['memsz']:#x} is outside DTCM")
    if not (entry >= DDR_BASE or DTCM[0] <= entry < DTCM[1]):
        sys.exit(f"entry {entry:#x} is not in DDR/DTCM")

    stub = os.path.join(tmp, "stub.bin")
    with open(stub, "wb") as f:
        f.write(struct.pack("<%dI" % len(STUB_WORDS), *STUB_WORDS))

    L = []
    w = L.append
    w("# generated by tools/ddr_run.py for %s" % os.path.basename(elf))
    w("proc mbx {off} { mem2array v 32 [expr {%d + $off}] 1; return $v(0) }" % MBX)
    w("proc rd32 {a} { mem2array v 32 $a 1; return $v(0) }")
    # Wait for the stub: let it run, look at the mailbox while halted.
    w("proc wait_stub {what limit} {")
    w("  for {set i 0} {$i < $limit} {incr i} {")
    w("    resume; sleep 20; halt")
    w("    if {[mbx 0] == 0} { return }")
    w("  }")
    w("  error \"DDRLOAD: stub did not finish: $what\"")
    w("}")
    w("proc stub_cmd {cmd src dst len what} {")
    w("  mww %d $src; mww %d $dst; mww %d $len; mww %d $cmd" % (MBX + 4, MBX + 8, MBX + 12, MBX))
    w("  wait_stub $what 3000")
    w("}")
    # cmd 5: the stub reads $len bytes from UART1 into $dst. The host sends
    # them once it sees "UART GO" and creates $flag when the last byte is out.
    # The core must not be halted meanwhile: the RX FIFO holds only a few
    # dozen bytes, a few ms of line time.
    w("proc uart_rx {dst len idx flag limit} {")
    w("  mww %d $dst; mww %d $len; mww %d 5" % (MBX + 8, MBX + 12, MBX))
    w("  resume")
    w("  echo \"DDRLOAD: UART GO $idx\"")
    w("  for {set i 0} {![file exists $flag]} {incr i} {")
    w("    if {$i > $limit} { error \"DDRLOAD: host never finished sending segment $idx\" }")
    w("    sleep 50")
    w("  }")
    w("  sleep 200; halt")
    w("  if {[mbx 0] != 0} { wait_stub {uart receive} 250 }")
    w("}")
    w("init")
    w("catch {riscv set_ebreakm off}")   # ebreak in the program traps, as on Nexus
    w("if {[catch {reset halt}]} { halt }")
    w("load_image %s 0x0 bin" % stub)
    # Seed the GPIO slot with a value the stub can never store, so a 0x0 read
    # back means GPIO really is 0 and not that the stub never got that far.
    w("mww %d 0; mww %d 0; mww %d %d" % (MBX, MBX + 16, MBX + MBX_GPIO, GPIO_UNSEEN))
    w("echo \"DDRLOAD: stub loaded, waiting for DDR calibration\"")
    w("resume 0x0")
    w("set ok 0")
    w("for {set i 0} {$i < 250} {incr i} {")
    w("  sleep 20; halt")
    w("  if {[mbx 16] == %d} { set ok 1; break }" % STATE_READY)
    w("  resume")
    w("}")
    # On timeout, read the SoC GPIO input register before giving up:
    #   bit 0 = DDR init_calib_complete, bit 1 = controller out of reset
    # (patches/0011 wired bit 1). Three samples so a toggling bit shows up.
    w("if {!$ok} {")
    w("  catch {halt}")
    w("  set g [mbx %d]" % MBX_GPIO)
    # Where the stub is: wait_cal is the lw/sw/andi/beqz loop at 0x8..0x14.
    # A pc parked on the lw at 0x8 every time (or a halt that fails) means
    # the GPIO read itself never completes.
    w("  for {set i 0} {$i < 3} {incr i} {")
    w("    if {[catch {reg pc} p]} { set p \"unreadable: $p\" }")
    w("    echo \"DDRLOAD: stub $p\"")
    w("    catch {resume}; sleep 20; catch {halt}")
    w("  }")
    w("  if {$g == %d} {" % GPIO_UNSEEN)
    w("    error \"DDRLOAD: the stub never stored GPIO DATA_IN (slot still %#010x): it is not running or its load from 0x40030000 never returns\"" % GPIO_UNSEEN)
    w("  }")
    w("  echo [format \"DDRLOAD: GPIO DATA_IN = 0x%08x  calibrated=%d  ctrl-out-of-reset=%d  eos=%d  por-held=%d\" $g [expr {$g & 1}] [expr {($g >> 1) & 1}] [expr {($g >> 2) & 1}] [expr {($g >> 3) & 1}]]")
    # bits 2/3 exist only from patches/0012 on; on an older bitstream they read 0.
    w("  if {($g & 8) == 0 && ($g & 2) == 0} {")
    w("    echo \"DDRLOAD: power-on reset already released but the controller is still in reset -> the 250 MHz reference clock is not reaching the IP (or this bitstream predates patches/0012)\"")
    w("  }")
    w("  error \"DDRLOAD: DDR not calibrated after 5 s. LEDs: 5 blinking = controller clock, 6 on = out of reset, 7 on = calibrated\"")
    w("}")
    w("echo \"DDRLOAD: DDR calibrated\"")

    total = sum(len(s["data"]) for s in ddr)
    done = 0
    n = 0
    uart = []
    if uart_ctrl is not None:
        w("mww %d %d" % (MBX + MBX_UART_CTRL, uart_ctrl))
    for s in ddr:
        data = s["data"] + b"\0" * (-len(s["data"]) % 4)
        if uart_ctrl is not None:
            flag = os.path.join(tmp, "uart%d.sent" % len(uart))
            # 50 ms polls: three times the line time at 9600 baud, plus a minute.
            limit = (len(data) * 10 * 3 // 9600 + 60) * 20
            w("uart_rx %#x %#x %d %s %d" % (s["addr"], len(data), len(uart), flag, limit))
            uart.append((data, flag))
            n += 1
            done += len(data)
            w("echo \"DDRLOAD: %d / %d KB\"" % (done // 1024, total // 1024))
        for off in range(0, len(data) if uart_ctrl is None else 0, chunk):
            piece = data[off:off + chunk]
            p = os.path.join(tmp, "ddr%04d.bin" % n)
            with open(p, "wb") as f:
                f.write(piece)
            n += 1
            done += len(piece)
            w("load_image %s %#x bin" % (p, BUF))
            w("stub_cmd 1 %#x %#x %#x {copy to %#x}" % (BUF, s["addr"] + off, len(piece), s["addr"] + off))
            w("echo \"DDRLOAD: %d / %d KB\"" % (done // 1024, total // 1024))
        exp = wsum(s["data"])
        w("stub_cmd 3 0 %#x %#x {checksum}" % (s["addr"], len(data)))
        w("set got [mbx 20]")
        w("if {$got != %d} { error [format \"DDRLOAD: checksum %%08x != %08x at %#x\" $got] }" % (exp, exp, s["addr"]))
        w("echo \"DDRLOAD: checksum ok %#x+%#x\"" % (s["addr"], len(data)))
        tail = s["memsz"] - len(data)
        if zero_ddr_bss and tail > 0:
            w("stub_cmd 2 0 %#x %#x {zero ddr bss}" % (s["addr"] + len(data), tail & ~3))

    for s in tcm:
        start = s["addr"] + ((s["filesz"] + 3) & ~3)
        end = s["addr"] + s["memsz"]
        if end > start:
            w("stub_cmd 2 0 %#x %#x {zero tcm bss}" % (start, (end - start) & ~3))
        if s["filesz"]:
            p = os.path.join(tmp, "tcm_%x.bin" % s["addr"])
            with open(p, "wb") as f:
                f.write(s["data"])
            w("load_image %s %#x bin" % (p, s["addr"]))
            w("verify_image %s %#x bin" % (p, s["addr"]))
    if "_ret" in syms:
        w("mww %#x %d" % (syms["_ret"][0], RET_SENTINEL))

    # Go.
    w("echo \"DDRLOAD: start %#x\"" % entry)
    w("mww %d %#x; mww %d 4" % (MBX + 8, entry, MBX))
    w("set t0 [clock seconds]")
    w("resume")
    if "_ret" in syms:
        ret = syms["_ret"][0]
        w("set fin 0")
        w("while {[clock seconds] - $t0 < %d} {" % run_timeout)
        w("  sleep %d; halt" % int(poll_s * 1000))
        w("  if {[rd32 %#x] != %d} { set fin 1; break }" % (ret, RET_SENTINEL))
        w("  resume")
        w("}")
        w("echo \"DDRLOAD: finished $fin after [expr {[clock seconds] - $t0}] s\"")
    else:
        w("sleep %d; halt" % (run_timeout * 1000))
    w("echo \"DDRLOAD: pc [reg pc]\"")

    # Results.
    for name in RESULT_SYMS:
        if name in syms:
            w("echo \"RES %s [format %%08x [rd32 %#x]]\"" % (name, syms[name][0]))
    for name in TEXT_SYMS + ARRAY_SYMS:
        if name in syms:
            addr, size = syms[name]
            nw = max(1, min((size + 3) // 4, 1024))
            w("mem2array a 32 %#x %d" % (addr, nw))
            w("set s {}; for {set i 0} {$i < %d} {incr i} { append s [format \" %%08x\" $a($i)] }" % nw)
            w("echo \"RES %s$s\"" % name)
    w("shutdown")

    script = os.path.join(tmp, "ddr_run.tcl")
    with open(script, "w") as f:
        f.write("\n".join(L) + "\n")
    return script, entry, segs, syms, total, n, uart


def words_to_text(ws):
    b = b"".join(struct.pack("<I", int(x, 16)) for x in ws)
    return b.split(b"\0")[0].decode("utf-8", "replace")


def f32(h):
    return struct.unpack("<f", struct.pack("<I", int(h, 16)))[0]


def uart_ctrl_word(baud):
    """UART1 CTRL: NCO in [31:16], RX and TX enable (as fpga/sw/uart.c)."""
    nco = (baud << 20) // CLK_HZ
    if not 0 < nco < 1 << 16:
        sys.exit("baud %d is out of the UART NCO range at %d Hz" % (baud, CLK_HZ))
    return (nco << 16) | 3


def open_uart(dev, baud):
    import termios
    speed = getattr(termios, "B%d" % baud, None)
    if speed is None:
        sys.exit("this host has no termios.B%d" % baud)
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY)
    attr = termios.tcgetattr(fd)
    attr[0] = 0                                                    # iflag
    attr[1] = 0                                                    # oflag
    attr[2] = termios.CS8 | termios.CREAD | termios.CLOCAL         # cflag: 8N1, no flow control
    attr[3] = 0                                                    # lflag
    attr[4] = attr[5] = speed
    termios.tcsetattr(fd, termios.TCSANOW, attr)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def uart_send(fd, data):
    import termios
    view = memoryview(data)
    while view:
        k = os.write(fd, view[:65536])
        view = view[k:]
    termios.tcdrain(fd)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("elf")
    ap.add_argument("--cfg", default="out/openocd_vcu118.cfg")
    ap.add_argument("--chunk", type=lambda x: int(x, 0), default=0x80000,
                    help="bytes per JTAG transfer (<= %#x)" % BUF_MAX)
    ap.add_argument("--timeout", type=int, default=900, help="run time limit, s")
    ap.add_argument("--poll", type=float, default=2.0, help="poll period while running, s")
    ap.add_argument("--zero-ddr-bss", action="store_true",
                    help="also zero DDR memsz beyond filesz (heap; ~112 MB, slow)")
    ap.add_argument("--uart", default="",
                    help="USB-UART tty: send the DDR segments over it instead of JTAG")
    ap.add_argument("--baud", type=int, default=921600)
    ap.add_argument("--jtag", action="store_true", help="load over JTAG even if --uart is given")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--keep", action="store_true", help="keep the temp directory")
    a = ap.parse_args()
    if not 4 <= a.chunk <= BUF_MAX or a.chunk % 4:
        sys.exit("--chunk must be a multiple of 4 up to %#x" % BUF_MAX)

    use_uart = bool(a.uart) and not a.jtag
    if use_uart and not os.path.exists(a.uart):
        print("==> no UART at %r; loading over JTAG" % a.uart)
        use_uart = False
    tmp = tempfile.mkdtemp(prefix="ddr_run_")
    script, entry, segs, syms, total, n, uart = build_script(
        a.elf, tmp, a.chunk, a.timeout, a.poll, a.zero_ddr_bss,
        uart_ctrl_word(a.baud) if use_uart else None)
    print("==> %s: entry %#x, %d KB to DDR in %d pieces over %s" % (
        a.elf, entry, total // 1024, n, "%s @ %d" % (a.uart, a.baud) if use_uart else "JTAG"))
    for s in segs:
        print("    seg %#010x filesz %#x memsz %#x" % (s["addr"], s["filesz"], s["memsz"]))
    if a.dry_run:
        print("==> dry run; OpenOCD script:", script)
        return

    fd = open_uart(a.uart, a.baud) if use_uart else None
    t0 = time.time()
    proc = subprocess.Popen(["openocd", "-f", a.cfg, "-f", script],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    res = {}
    log = []
    for line in proc.stdout:
        log.append(line)
        if line.startswith("DDRLOAD:"):
            print("    %6.1fs %s" % (time.time() - t0, line.rstrip()), flush=True)
            m = re.match(r"DDRLOAD: UART GO (\d+)", line)
            if m and fd is not None:
                data, flag = uart[int(m.group(1))]
                ts = time.time()
                uart_send(fd, data)
                dt = time.time() - ts
                print("    %6.1fs UART sent %d KB in %.1f s (%.1f KB/s)" % (
                    time.time() - t0, len(data) // 1024, dt, len(data) / 1024 / max(dt, 1e-3)), flush=True)
                open(flag, "w").close()
        elif line.startswith("RES "):
            parts = line.split()
            res[parts[1]] = parts[2:]
    rc = proc.wait()
    if fd is not None:
        os.close(fd)
    logf = os.path.join(tmp, "openocd.log")
    with open(logf, "w") as f:
        f.writelines(log)
    if not res:
        print("".join(log[-30:]))
        sys.exit("ERROR: no results (OpenOCD exit %d); log %s" % (rc, logf))

    print("==> results")
    for name in RESULT_SYMS:
        if name in res:
            h = res[name][0]
            extra = ""
            if name == "_ret":
                v = int(h, 16)
                extra = ("  (still %08x: did not finish)" % RET_SENTINEL if v == RET_SENTINEL
                         else "  (0 = success)" if v == 0 else "  (nonzero = failure)")
            elif name in ("inference_max_value", "inference_out_sum"):
                extra = "  (as f32: %g)" % f32(h)
            elif name.startswith("cyc_"):
                extra = "  (%d cycles = %.1f ms at 50 MHz)" % (int(h, 16), int(h, 16) / 50e3)
            print("    %-22s %s%s" % (name, h, extra))
    for name in TEXT_SYMS:
        if name in res:
            print("    %-22s %r" % (name, words_to_text(res[name])))
    for name in ARRAY_SYMS:
        if name in res:
            ws = res[name]
            cnt = int(res.get("inference_out_count", ["%x" % len(ws)])[0], 16)
            cnt = max(1, min(cnt, len(ws)))
            print("    %s[%d] (hex | as f32):" % (name, cnt))
            for i in range(0, min(cnt, 64), 8):
                print("      %3d: %s" % (i, " ".join(ws[i:i + 8])))
                print("           %s" % " ".join("%8.4g" % f32(x) for x in ws[i:i + 8]))
    print("==> total %.1f s, OpenOCD log %s" % (time.time() - t0, logf))
    if not a.keep:
        for f in os.listdir(tmp):
            if f.endswith(".bin"):
                os.remove(os.path.join(tmp, f))


if __name__ == "__main__":
    main()
