# ITCM helper that lets the JTAG debugger fill DDR.
#
# The debug module reaches only ITCM/DTCM, so the host writes a chunk into
# ITCM and asks this loop (running from ITCM address 0) to copy it into DDR.
# Mailbox at ITCM 0x100 (written by the host while the core is halted):
#   +0  cmd    0 idle | 1 copy src->dst | 2 zero dst | 3 sum dst -> +20 | 4 jump dst
#   +4  src    +8 dst   +12 len (bytes, multiple of 4)
#   +16 state  0x0ddc0de1 once the DDR controller reports calibration done
#   +20 result of cmd 3 (32-bit wrapping sum of the words)
# The stub clears cmd when a command is finished.
# GPIO DATA_IN (0x40030000) bit 0 = DDR init_calib_complete (chip_vcu118).
#
# Rebuild (tools/ddr_run.py embeds the words):
#   llvm-mc -triple=riscv32 -mattr=+zifencei -filetype=obj ddr_stub.S -o s.o
#   llvm-objcopy -O binary s.o s.bin

        .text
        .globl _start
_start:
        li      s0, 0x100               # mailbox
        li      s1, 0x40030000          # GPIO DATA_IN
wait_cal:
        lw      t0, 0(s1)
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
        j       done
copy:
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
