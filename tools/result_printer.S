# ITCM helper that prints a model's results on the USB-UART from the board.
#
# The IREE model ELFs end in crt0 with
#     sw a0, _ret ; beqz a0, 1f ; ebreak ; j 2f ; 1: csrr ; csrr ; mpause ; 2: j .
# and never write to the UART themselves (_write only fills a DTCM line
# buffer). tools/ddr_run.py patches the beqz/ebreak pair, in the DDR image it
# sends, into "lui t0, 0 ; jalr x0, 0x400(t0)", so both the success and the
# failure path land here once _ret is stored. This prints every result
# symbol from DTCM/DDR, then sets a done flag and parks like crt0 does.
#
# Assembled at ITCM 0x400 by tools/rvasm.pl; ddr_run.py loads it with the
# debugger next to the stub. The host builds the table at ITCM 0x800:
#   +0  UART1 CTRL word (NCO << 16 | RX/TX enable), 0 = keep
#   +4  DTCM address of the done flag (the stub mailbox +32)
#   +8  entries {name, addr, n}, ended by name = 0
#       name  ITCM address of a NUL-terminated label
#       n     words to print in hex; bit 31 set = text, up to n bytes or NUL
# Output, one line per entry:  "<label> <hex word> <hex word> ..." or
# "<label> <text>". Only loads from ITCM (a store there would fault).

        .text
printer:
        li      t2, 0x40010000          # UART1
        la      s1, hexdigits
        li      s0, 0x800               # table
        lw      t3, 0(s0)
        beqz    t3, 1f
        sw      t3, 16(t2)              # CTRL
1:      addi    s0, s0, 8
entry:
        lw      a3, 0(s0)
        beqz    a3, finish
        lw      a4, 4(s0)
        lw      a5, 8(s0)
        addi    s0, s0, 12
name:
        lbu     a0, 0(a3)
        beqz    a0, body
        jal     ra, putc
        addi    a3, a3, 1
        j       name
body:
        bltz    a5, text
words:
        beqz    a5, eol
        li      a0, 32
        jal     ra, putc
        lw      a6, 0(a4)
        li      a7, 8
hex:
        srli    a0, a6, 28
        add     a0, a0, s1
        lbu     a0, 0(a0)
        jal     ra, putc
        slli    a6, a6, 4
        addi    a7, a7, -1
        bnez    a7, hex
        addi    a4, a4, 4
        addi    a5, a5, -1
        j       words
text:
        slli    a5, a5, 1               # drop the text flag: byte count
        srli    a5, a5, 1
        li      a0, 32
        jal     ra, putc
2:      beqz    a5, eol
        lbu     a0, 0(a4)
        beqz    a0, eol
        jal     ra, putc
        addi    a4, a4, 1
        addi    a5, a5, -1
        j       2b
eol:
        li      a0, 10
        jal     ra, putc
        j       entry
finish:
        lw      t5, 20(t2)              # wait for TXIDLE: the last byte is out
        andi    t5, t5, 8
        beqz    t5, finish
        li      t4, 0x800
        lw      t4, 4(t4)
        li      t3, 0x0d0e0d0e
        sw      t3, 0(t4)
        fence
        .word   0x08000073              # mpause, as crt0
3:      j       3b
putc:
        lw      t5, 20(t2)              # STATUS.TXFULL
        andi    t5, t5, 1
        bnez    t5, putc
        sw      a0, 28(t2)              # WDATA
        ret
hexdigits:
        .asciz  "0123456789abcdef"
