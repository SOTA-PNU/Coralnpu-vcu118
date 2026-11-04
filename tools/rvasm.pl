#!/usr/bin/env perl
# Minimal RV32I assembler for the loader's hand-written helpers
# (tools/ddr_stub.S, tools/result_printer.S). Two passes, one instruction per
# line, no expressions beyond numbers and labels. It exists because the
# hosts this repo runs on do not reliably have llvm-mc; `--check` re-assembles
# ddr_stub.S and compares it with the words embedded in tools/ddr_run.py.
#
#   perl tools/rvasm.pl file.S [base]   -> one hex word per line
#
# Supported: lui addi andi ori xori slli srli add sub lw lbu sw sb
#            beq bne blt bge bltu bgeu beqz bnez bltz jal jalr j jr ret
#            li (12-bit or lui+addi) la (lui+addi) fence fence.i .word .asciz .align
use strict;
use warnings;

my %R;
my @abi = qw(zero ra sp gp tp t0 t1 t2 s0 s1 a0 a1 a2 a3 a4 a5 a6 a7
             s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t3 t4 t5 t6);
$R{$abi[$_]} = $_ for 0 .. 31;
$R{"x$_"} = $_ for 0 .. 31;
$R{fp} = 8;

sub reg { my $r = shift; exists $R{$r} or die "bad register '$r'\n"; $R{$r} }
sub num { my $v = shift; $v =~ /^-?0x/i ? ($v =~ /^-/ ? -hex(substr $v, 1) : hex $v) : $v + 0 }

sub I { my ($op, $f3, $rd, $rs1, $imm) = @_;
  (($imm & 0xfff) << 20) | ($rs1 << 15) | ($f3 << 12) | ($rd << 7) | $op }
sub S { my ($f3, $rs2, $rs1, $imm) = @_;
  ((($imm >> 5) & 0x7f) << 25) | ($rs2 << 20) | ($rs1 << 15) | ($f3 << 12) | (($imm & 0x1f) << 7) | 0x23 }
sub B { my ($f3, $rs1, $rs2, $off) = @_; my $i = $off & 0x1fff;
  ((($i >> 12) & 1) << 31) | ((($i >> 5) & 0x3f) << 25) | ($rs2 << 20) | ($rs1 << 15) |
  ($f3 << 12) | ((($i >> 1) & 0xf) << 8) | ((($i >> 11) & 1) << 7) | 0x63 }
sub J { my ($rd, $off) = @_; my $i = $off & 0x1fffff;
  ((($i >> 20) & 1) << 31) | ((($i >> 1) & 0x3ff) << 21) | ((($i >> 11) & 1) << 20) |
  ((($i >> 12) & 0xff) << 12) | ($rd << 7) | 0x6f }
sub U { my ($op, $rd, $imm20) = @_; (($imm20 & 0xfffff) << 12) | ($rd << 7) | $op }
sub hi { my $v = shift; (($v + 0x800) >> 12) & 0xfffff }
sub lo { my $v = shift; my $l = $v & 0xfff; $l >= 0x800 ? $l - 0x1000 : $l }

my %BR = (beq => 0, bne => 1, blt => 4, bge => 5, bltu => 6, bgeu => 7);
my %ALUI = (addi => 0, xori => 4, ori => 6, andi => 7);

sub parse {
  my $file = shift;
  open my $fh, '<', $file or die "$file: $!\n";
  my @items;
  while (my $line = <$fh>) {
    $line =~ s/#.*//; $line =~ s/^\s+|\s+$//g;
    next if $line eq '';
    while ($line =~ s/^([A-Za-z_.][\w.]*|\d+):\s*//) { push @items, [label => $1]; }
    next if $line eq '';
    next if $line =~ /^\.(text|globl|section)\b/;
    my ($mn, $rest) = $line =~ /^(\S+)\s*(.*)$/;
    if ($mn eq '.asciz') {
      my ($s) = $rest =~ /^"(.*)"$/ or die "bad .asciz: $line\n";
      $s =~ s/\\n/\n/g; $s =~ s/\\t/\t/g;
      push @items, [bytes => $s . "\0"]; next;
    }
    my @a = map { s/^\s+|\s+$//gr } split /,/, $rest;
    push @items, [insn => $mn, @a];
  }
  @items;
}

sub size_of {
  my ($it, $pc) = @_;
  return 0 if $it->[0] eq 'label';
  return length $it->[1] if $it->[0] eq 'bytes';
  my ($mn, @a) = @{$it}[1 .. $#$it];
  return (-$pc) & (num($a[0]) - 1) if $mn eq '.align';
  if ($mn eq 'li') { my $v = num($a[1]); return ($v >= -2048 && $v < 2048) ? 4 : (lo($v) ? 8 : 4) }
  return 8 if $mn eq 'la';
  4;
}

sub assemble {
  my ($file, $base) = @_;
  my @items = parse($file);
  my (%lab, @numlab);
  my $pc = $base;
  for my $it (@items) {
    if ($it->[0] eq 'label') {
      if ($it->[1] =~ /^\d+$/) { push @numlab, [$it->[1], $pc] } else { $lab{$it->[1]} = $pc }
    }
    push @$it, $pc if $it->[0] ne 'label';
    $pc += size_of($it, $pc);
  }
  my $target = sub {
    my ($t, $here) = @_;
    if ($t =~ /^(\d+)([fb])$/) {
      my @c = grep { $_->[0] eq $1 } @numlab;
      my @m = $2 eq 'f' ? grep { $_->[1] > $here } @c : reverse grep { $_->[1] <= $here } @c;
      @m or die "no local label $t\n";
      return $m[0][1];
    }
    return $lab{$t} if exists $lab{$t};
    return num($t) if $t =~ /^-?(0x)?[0-9a-f]+$/i;
    die "unknown label '$t'\n";
  };
  my $out = '';
  for my $it (@items) {
    next if $it->[0] eq 'label';
    my $at = $it->[-1];
    if ($it->[0] eq 'bytes') { $out .= $it->[1]; next }
    my ($mn, @a) = @{$it}[1 .. $#$it - 1];
    my @w;
    if ($mn eq '.word') { @w = (num($a[0]) & 0xffffffff) }
    elsif ($mn eq '.align') { $out .= "\0" x size_of($it, $at); next }
    elsif ($mn eq 'lui') { @w = U(0x37, reg($a[0]), num($a[1])) }
    elsif (exists $ALUI{$mn}) { @w = I(0x13, $ALUI{$mn}, reg($a[0]), reg($a[1]), num($a[2])) }
    elsif ($mn eq 'slli') { @w = I(0x13, 1, reg($a[0]), reg($a[1]), num($a[2]) & 31) }
    elsif ($mn eq 'srli') { @w = I(0x13, 5, reg($a[0]), reg($a[1]), num($a[2]) & 31) }
    elsif ($mn eq 'add') { @w = (reg($a[2]) << 20) | (reg($a[1]) << 15) | (reg($a[0]) << 7) | 0x33 }
    elsif ($mn eq 'sub') { @w = (0x20 << 25) | (reg($a[2]) << 20) | (reg($a[1]) << 15) | (reg($a[0]) << 7) | 0x33 }
    elsif ($mn =~ /^(lw|lbu)$/) {
      my ($off, $rs) = $a[1] =~ /^(-?\w*)\((\w+)\)$/ or die "bad mem operand '$a[1]'\n";
      @w = I(0x03, $mn eq 'lw' ? 2 : 4, reg($a[0]), reg($rs), num($off eq '' ? 0 : $off));
    }
    elsif ($mn =~ /^(sw|sb)$/) {
      my ($off, $rs) = $a[1] =~ /^(-?\w*)\((\w+)\)$/ or die "bad mem operand '$a[1]'\n";
      @w = S($mn eq 'sw' ? 2 : 0, reg($a[0]), reg($rs), num($off eq '' ? 0 : $off));
    }
    elsif (exists $BR{$mn}) { @w = B($BR{$mn}, reg($a[0]), reg($a[1]), $target->($a[2], $at) - $at) }
    elsif ($mn eq 'beqz') { @w = B(0, reg($a[0]), 0, $target->($a[1], $at) - $at) }
    elsif ($mn eq 'bnez') { @w = B(1, reg($a[0]), 0, $target->($a[1], $at) - $at) }
    elsif ($mn eq 'bltz') { @w = B(4, reg($a[0]), 0, $target->($a[1], $at) - $at) }
    elsif ($mn eq 'j') { @w = J(0, $target->($a[0], $at) - $at) }
    elsif ($mn eq 'jal') { @a == 1 and unshift @a, 'ra'; @w = J(reg($a[0]), $target->($a[1], $at) - $at) }
    elsif ($mn eq 'jalr') {
      my ($off, $rs) = $a[1] =~ /^(-?\w*)\((\w+)\)$/ or die "bad jalr operand\n";
      @w = I(0x67, 0, reg($a[0]), reg($rs), num($off eq '' ? 0 : $off));
    }
    elsif ($mn eq 'jr') { @w = I(0x67, 0, 0, reg($a[0]), 0) }
    elsif ($mn eq 'ret') { @w = I(0x67, 0, 0, 1, 0) }
    elsif ($mn eq 'fence') { @w = 0x0ff0000f }
    elsif ($mn eq 'fence.i') { @w = 0x0000100f }
    elsif ($mn eq 'li' || $mn eq 'la') {
      my $rd = reg($a[0]);
      my $v = $mn eq 'la' ? $target->($a[1], $at) : num($a[1]);
      if ($mn eq 'li' && $v >= -2048 && $v < 2048) { @w = I(0x13, 0, $rd, 0, $v) }
      else {
        @w = U(0x37, $rd, hi($v));
        push @w, I(0x13, 0, $rd, $rd, lo($v)) if $mn eq 'la' || lo($v);
      }
    }
    else { die "unsupported '$mn'\n" }
    $out .= pack 'V*', @w;
  }
  $out .= "\0" x ((-length $out) & 3);
  ($out, \%lab);
}

if (@ARGV && $ARGV[0] eq '--check') {
  my $dir = $0 =~ s{[^/\\]*$}{}r;
  open my $py, '<', "${dir}ddr_run.py" or die;
  my $src = do { local $/; <$py> };
  my $bad = 0;
  for my $c (['ddr_stub.S', 0, 'STUB_WORDS'], ['result_printer.S', 0x400, 'PRINTER_WORDS']) {
    my ($file, $base, $var) = @$c;
    my ($bin) = assemble("$dir$file", $base);
    my ($block) = $src =~ /\n$var = \[(.*?)\]/s or die "no $var in ddr_run.py\n";
    my @want = map { hex } $block =~ /0x([0-9a-f]{8})/gi;
    my @got = unpack 'V*', $bin;
    my $n = 0;
    for my $i (0 .. ($#want > $#got ? $#want : $#got)) {
      next if defined $want[$i] && defined $got[$i] && $want[$i] == $got[$i];
      printf "%s word %d (0x%x): ddr_run.py %s, %s %s\n", $var, $i, $base + 4 * $i,
        defined $want[$i] ? sprintf('%08x', $want[$i]) : '-', $file,
        defined $got[$i] ? sprintf('%08x', $got[$i]) : '-';
      $n++;
    }
    print $n ? "MISMATCH: $file vs $var ($n words)\n" : "ok: $file == $var (" . scalar(@want) . " words)\n";
    $bad += $n;
  }
  exit($bad ? 1 : 0);
}

my ($file, $base) = @ARGV;
defined $file or die "usage: rvasm.pl file.S [base] | --check\n";
my ($bin, $lab) = assemble($file, defined $base ? num($base) : 0);
printf "%08x\n", $_ for unpack 'V*', $bin;
printf STDERR "%s = 0x%x\n", $_, $lab->{$_} for sort { $lab->{$a} <=> $lab->{$b} } keys %$lab;
