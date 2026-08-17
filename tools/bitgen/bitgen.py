#!/usr/bin/env python3
"""Generate RFC-style ASCII bit-field diagrams, patent numbering (MSB left)."""

def diagram(width, fields, title=None):
    # fields: list of (label, hi, lo) covering [width-1 .. 0], no gaps/overlaps
    # validate coverage
    bits = [None]*width
    for label, hi, lo in fields:
        for b in range(lo, hi+1):
            assert bits[b] is None, f"overlap at bit {b} ({label})"
            bits[b] = label
    for b in range(width):
        assert bits[b] is not None, f"gap at bit {b}"
    cell = 2  # chars per bit
    total = width*cell + 1
    # rulers: bit numbers at each field's hi (left edge) and the final 0
    tens = [' ']*total
    units = [' ']*total
    def colL(b):   # left column of bit b (bit width-1 at col 0)
        return (width-1-b)*cell
    for label, hi, lo in fields:
        c = colL(hi)
        s = str(hi)
        tens[c] = s[0] if len(s) == 2 else ' '
        units[c] = s[-1]
    # always label bit 0 at right
    units[colL(0)] = '0'
    border = '+' + '-+'*width
    # field label row
    row = [' ']*total
    for c in range(0, total, cell):
        row[c] = '|'
    row[total-1] = '|'
    for label, hi, lo in fields:
        left = colL(hi)
        right = colL(lo)+cell  # position of right '|'
        row[left] = '|'
        row[right] = '|'
        inner_lo = left+1
        inner_hi = right           # exclusive
        span = inner_hi - inner_lo
        lab = label if len(label) <= span else label[:span]
        start = inner_lo + (span-len(lab))//2
        for i,ch in enumerate(lab):
            row[start+i] = ch
    out = []
    if title: out.append(title)
    out.append(''.join(tens).rstrip())
    out.append(''.join(units).rstrip())
    out.append(border)
    out.append(''.join(row))
    out.append(border)
    return '\n'.join(out)

# ---- 32-bit instruction formats (label, hi, lo) ----
OPC = ('Opcode', 6, 0)
def F(v): return ('Fnc4', 10, 7)

I32 = {
"Generic 32-bit parser instruction":
  [('. . . instruction-specific . . .',31,11), ('Fnc4',10,7), OPC],
"PLOAD / PLOADTLVLOOP  (Fnc4=0000)":
  [('X',31,31),('D',30,30),('Sz',29,28),('Blen',27,24),('Shift',23,21),('E',20,20),('Offset',19,11),('Fnc4',10,7),OPC],
"PTLVFASTLOOP  (Fnc4=0000, X=1,D=1)":
  [('X',31,31),('D',30,30),('Rsvd',29,24),('Shift',23,21),('F2',20,19),('Len',18,11),('Fnc4',10,7),OPC],
"PFLAGSLOOP  (Fnc4=0001)":
  [('Pos',31,30),('Sz',29,28),('R',27,27),('Mask',26,11),('Fnc4',10,7),OPC],
"Length group  (Fnc4=0010 PLENCUR/DATA/BND, 0011 TLV/PAD/EOL)":
  [('S',31,31),('D',30,30),('Sz',29,28),('Pos',27,24),('Shift',23,21),('F2',20,19),('Len',18,11),('Fnc4',10,7),OPC],
"PSTORE  (Fnc4=0100)":
  [('S',31,31),('F',30,30),('Sz',29,28),('Pos',27,24),('J',23,23),('Sind',22,20),('Offset',19,11),('Fnc4',10,7),OPC],
"PSTOREREG  (Fnc4=0101)":
  [('S',31,31),('F',30,30),('Sz',29,28),('Reg',27,23),('Pos',22,20),('Offset',19,11),('Fnc4',10,7),OPC],
"PSTOREIMM  (Fnc4=0110)":
  [('S',31,31),('F',30,30),('Sz',29,28),('Value',27,20),('Offset',19,11),('Fnc4',10,7),OPC],
"PEXTRACT / PLOOP  (Fnc4=0111, Fun=00/01)":
  [('S',31,31),('V',30,30),('Fun',29,28),('Preg',27,23),('BitPos',22,17),('BitLength',16,11),('Fnc4',10,7),OPC],
"Counter grp PINCCNTR/PSETCNTRBIT/PRESETCNTR  (Fnc4=0111, Fun=10/11)":
  [('S',31,31),('V',30,30),('Fun',29,28),('Cntr',27,23),('ValO',22,21),('F',20,20),('Bnum',19,17),('Rsvd',16,11),('Fnc4',10,7),OPC],
"CAM group  (Fnc4=1000)":
  [('S',31,31),('D',30,30),('Sz',29,28),('Pos',27,24),('Func3',23,21),('F',20,20),('Share',19,16),('Miss',15,11),('Fnc4',10,7),OPC],
"Array group  (Fnc4=1001)":
  [('S',31,31),('D',30,30),('Sz',29,28),('Pos',27,24),('Func3',23,21),('F',20,20),('Base',19,11),('Fnc4',10,7),OPC],
"Next/set grp PNEXTNODE/PSETIMM/PSETCODE/PSTP/PVARINT/PANDMASK (Fnc4=1010)":
  [('S',31,31),('V',30,30),('Pos',29,28),('A',27,27),('Payload',26,11),('Fnc4',10,7),OPC],
"PCMP* byte-compare LTB/LTEB/GTB/GTEB  (Fnc4=1011)":
  [('S',31,31),('D',30,30),('Sz',29,28),('Pos',27,24),('Func3',23,21),('Er',20,19),('Value',18,11),('Fnc4',10,7),OPC],
"PCMPIH  (Fnc4=1100, 16-bit compare)":
  [('Er',31,30),('Pos',29,28),('N',27,27),('Value',26,11),('Fnc4',10,7),OPC],
"PCMPIB / PCMPNEIB  (Fnc4=1101 / 1110)":
  [('Er',31,30),('Pos',29,27),('Value',26,19),('Mask',18,11),('Fnc4',10,7),OPC],
"PRUNTHREAD  (Fnc4=1111, F2=00)":
  [('S',31,31),('D',30,30),('F2',29,28),('N',27,27),('FuncNum',26,11),('Fnc4',10,7),OPC],
"PINITPARSER/PEVENTLOOP/PEVENTLOOPEND  (Fnc4=1111)":
  [('Rv',31,30),('F2',29,28),('Rsvd',27,11),('Fnc4',10,7),OPC],
"PDATAEXTRACT  (Fnc4=1111, F2=11)":
  [('S',31,31),('D',30,30),('F2',29,28),('InsIndex',27,16),('InsNum',15,11),('Fnc4',10,7),OPC],
"Next-node ADDRESS word  (bit31=0)":
  [('0',31,31),('E',30,30),('V',29,29),('NE',28,28),('NV',27,27),('0',26,24),('Address (24-bit rel)',23,0)],
"Next-node CODE word  (bit31=1)":
  [('1',31,31),('E',30,30),('V',29,29),('NE',28,28),('NV',27,27),('0',26,24),('ones',23,8),('Code',7,0)],
}

KEY20 = {
"CAM key — shared form  (Shared!=0), 20-bit":
  [('Shared',19,16),('Match (up to 16b)',15,0)],
"CAM key — selector form  (Shared==0), 20-bit":
  [('0000',19,16),('Selector',15,8),('Match',7,0)],
}

R64 = {
"CurHdr (p1) / DataHdr (p2)":
  [('Offset',63,32),('Length',31,0)],
"Counters (p7)":
  [('Cntr7',63,56),('Cntr6',55,48),('Cntr5',47,40),('Cntr4',39,32),('Cntr3',31,24),('Cntr2',23,16),('Cntr1',15,8),('Encap',7,0)],
"CounterLimitsConfig":
  [('Cntr7',63,56),('Cntr6',55,48),('Cntr5',47,40),('Cntr4',39,32),('Cntr3',31,24),('Cntr2',23,16),('Cntr1',15,8),('E7',7,7),('E6',6,6),('E5',5,5),('E4',4,4),('E3',3,3),('E2',2,2),('E1',1,1),('R',0,0)],
"ParserExitCode (p14)":
  [('Error (parser code)',63,48),('Rsvd',47,24),('Address (rel)',23,0)],
"TLVSpec  (FIG 41)":
  [('Rsvd',63,46),('E',45,45),('N',44,44),('P',43,43),('Disp',42,40),('EOL',39,32),('PADN',31,24),('PAD1',23,16),('IgnMask',15,8),('IgnVal',7,0)],
}

CP32 = {  # custom-3 coprocessor instructions, Opcode[6:0]=0x7b=1111011 (FIG 43)
"Coprocessor R-form  (custom-3): CPPRSRD/CPPRSWR/CPPRSRDCAM/RDARRAY/WRCAM/WRARRAY":
  [('CoP',31,29),('Cpreg',28,24),('C/D',23,23),('S',22,22),('I',21,21),('R',20,20),('Rs',19,15),('Func3',14,12),('Rd',11,7),('Opcode',6,0)],
"CPPRSWRIMM  (custom-3, I=1): 11-bit imm = Imm1 + (Imm2<<5)":
  [('CoP',31,29),('Cpreg',28,24),('C',23,23),('S',22,22),('I',21,21),('Imm2',20,15),('Func3',14,12),('Imm1',11,7),('Opcode',6,0)],
}

import sys
print("="*72); print("32-BIT INSTRUCTION FORMATS  (Opcode[6:0]=0x0b=0001011)"); print("="*72)
for t,f in I32.items():
    print(); print(diagram(32, f, t))
print(); print("="*72); print("CUSTOM-3 COPROCESSOR FORMATS  (Opcode[6:0]=0x7b=1111011)"); print("="*72)
for t,f in CP32.items():
    print(); print(diagram(32, f, t))
for t,f in KEY20.items():
    print(); print(diagram(20, f, t))
print(); print("="*72); print("64-BIT PARSER REGISTERS"); print("="*72)
for t,f in R64.items():
    print(); print(diagram(64, f, t))
