# ITCM helper that lets the JTAG debugger fill DDR.
#
# The debug module reaches only ITCM/DTCM, so the host writes a chunk into
# ITCM and asks this loop (running from ITCM address 0) to copy it into DDR.
# Mailbox at DTCM 0x1ff000 (written by the host while the core is halted).
# Not ITCM: the core may load from ITCM, but a store there is an access
# fault, which sends the stub back to 0 before it ever reaches the mailbox.
#   +0  cmd    0 idle | 1 copy src->dst | 2 zero dst | 3 sum dst -> +20 | 4 jump dst
#              5 receive len bytes from UART1 into dst (the host streams them
#                over the USB-UART; ~70x faster than copying via ITCM)
#   +4  src    +8 dst   +12 len (bytes, multiple of 4)
#   +16 state  0x0ddc0de1 once the DDR controller reports calibration done
#   +20 result of cmd 3 (32-bit wrapping sum of the words)
#   +24 last GPIO DATA_IN seen while waiting for calibration, so the host can
#       tell the three bring-up cases apart (the debug module cannot read
#       0x40030000 itself): bit 0 calibrated, bit 1 controller out of reset
#   +28 UART1 CTRL (NCO << 16 | RX/TX enable) written before cmd 5; 0 = keep
#   +32 0x0d0e0d0e once tools/result_printer.S has printed the results
# The stub clears cmd when a command is finished.
# GPIO DATA_IN (0x40030000) bit 0 = DDR init_calib_complete (chip_vcu118).
#
# Rebuild (tools/ddr_run.py embeds the words; the cmd 5 words were encoded
# by hand on 11/04 and checked against this file's existing words, so
# re-assemble and compare when llvm-mc is at hand):
#   llvm-mc -triple=riscv32 -mattr=+zifencei -filetype=obj ddr_stub.S -o s.o
#   llvm-objcopy -O binary s.o s.bin

        .text
        .globl _start
_start:
        li      s0, 0x1ff000            # mailbox (DTCM; a store to ITCM faults)
        li      s1, 0x40030000          # GPIO DATA_IN
wait_cal:
        lw      t0, 0(s1)
        sw      t0, 24(s0)              # publish raw GPIO for the debugger
        andi    t0, t0, 1
        beqz    t0, wait_cal
        li      t0, 0x0ddc0de1
        sw      t0, 16(s0)
idle:
        lw      t0, 0(s0)
        beqz    t0, idle
        lw      a0, 4(s0)
        lw      a1, 8(s0)
        lw      a2, 12(s0)
        li      t1, 1
        beq     t0, t1, copy
        li      t1, 2
        beq     t0, t1, clear
        li      t1, 3
        beq     t0, t1, sum
        li      t1, 4
        beq     t0, t1, jump
        j       uart                    # cmd 5 lives after done, so the
copy:                                   # words above keep their offsets
        beqz    a2, done
1:      lw      t2, 0(a0)
        sw      t2, 0(a1)
        addi    a0, a0, 4
        addi    a1, a1, 4
        addi    a2, a2, -4
        bnez    a2, 1b
        j       done
clear:
        beqz    a2, done
1:      sw      zero, 0(a1)
        addi    a1, a1, 4
        addi    a2, a2, -4
        bnez    a2, 1b
        j       done
sum:
        li      t3, 0
        beqz    a2, 2f
1:      lw      t2, 0(a1)
        add     t3, t3, t2
        addi    a1, a1, 4
        addi    a2, a2, -4
        bnez    a2, 1b
2:      sw      t3, 20(s0)
        j       done
jump:
        sw      zero, 0(s0)
        fence
        fence.i
        jr      a1
done:
        fence
        sw      zero, 0(s0)
        j       idle
uart:
        li      t1, 5
        bne     t0, t1, done
        li      t2, 0x40010000          # UART1
        lw      t3, 28(s0)
        beqz    t3, 1f
        sw      t3, 16(t2)              # CTRL
1:      beqz    a2, done
2:      lw      t3, 20(t2)              # STATUS
        andi    t3, t3, 32              # RXEMPTY
        bnez    t3, 2b
        lw      t3, 24(t2)              # RDATA
        sb      t3, 0(a1)
        addi    a1, a1, 1
        addi    a2, a2, -1
        bnez    a2, 2b
        j       done
