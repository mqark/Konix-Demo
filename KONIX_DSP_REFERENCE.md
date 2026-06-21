# Konix Multi-System DSP Reference

**A concise, verified reference for the Konix Multi-System's on-die DSP (the "P89" / Slipstream ASIC variant).**

Everything in this document has been confirmed empirically using the `harness_v4` test suite on the Slipstream V1.0 emulator. Where uncertainty remains, it is marked. Where claims rest on the EDL source rather than empirical observation, they are also marked.

This is the **lookup-while-coding** reference. For the *why* behind these patterns, see `KONIX_DSP_GUIDE.md`.

---

## 1. DSP at a glance

* 16-bit instruction word, 9-bit address field per instruction
* 256-word PRAM (program memory)
* 256-word DRAM (data memory)
* 256-word SINE ROM at the bottom of the address space, available to read
* 128-byte constants ROM (16 useful values)
* 16-bit ALU with carry, separate 36-bit multiply-accumulator chain
* X register (16-bit), AZ output (16-bit), MZ0/MZ1/MZ2 multiply result chain
* MODE register controls multiply behaviour and a couple of other things
* IX register for indexed addressing (9-bit offset)
* PC is 9-bit (255 words of PRAM addressable, plus a high-bit base of 0x400)
* DMA engine for streaming words to/from main RAM (20-bit address space)
* INTRUDE mechanism: host-initiated DRAM writes that commit when DSP runs INTRUDE

---

## 2. DSP RAM address map (as seen from inside the DSP)

The DSP's 9-bit address field can reach any of these. Some regions are read-only; some serve double-duty as registers.

| DSP addr range | Contents | Notes |
| --- | --- | --- |
| `0x000`–`0x0FF` | SINE ROM (256 words) | Sine table, read-only |
| `0x100`–`0x10F` | Constants ROM (16 values) | Read-only; see §3 |
| `0x110`–`0x13F` | (unused / reserved) | |
| `0x140` | Intrude Data Register | DSP RAM word, written by host INTRUDE protocol |
| `0x142` | DMA Address 0 (low 16 bits) | Write triggers DMA |
| `0x143` | DMA Address 1 (control + high addr) | See §11 |
| `0x144` | DMA Data | The word read or to be written |
| `0x145` | MZ0 (multiply result low word) | |
| `0x146` | MZ1 (multiply result mid word) | |
| `0x147` | MZ2 (multiply result high + flags) | Includes the C (carry) flag at bit 5 |
| `0x14A` | PC (program counter) | Low 9 bits = PC_ACTUAL; high bits 0x400 implied |
| `0x14B` | MODE register | See §4 |
| `0x14C` | X register | |
| `0x14D` | AZ (ALU output) | |
| `0x14E` | Intrude Address Register | DSP RAM word, set by host INTRUDE protocol |
| `0x180`–`0x1FF` | DRAM (256 words) | Free RAM for program use. *This is where you put your data.* |
| `0x400`–`0x4FF` | PRAM (256 words) | Instructions live here. PC ranges 0x400..0x4FF. |

**Aliasing note.** Several DSP registers (MODE, PC, X, AZ, MZ, DMA, IntrudeData/Address) are actually fixed addresses in the DSP's RAM, not separate hardware registers. You can read or write them from a DSP instruction using their RAM address.

---

## 3. Constants ROM

| DSP addr | Value | Use |
| --- | --- | --- |
| `0x100` | `0x0000` | Zero |
| `0x101` | `0x0001` | One |
| `0x102` | `0x0002` | Two |
| `0x103` | `0x0004` | Four (handy for IX) |
| `0x104` | `0x0008` | Eight |
| `0x105` | `0x0010` | Sixteen |
| `0x106` | `0x0020` | MODE bit pattern: TCX = signed multiply |
| `0x107` | `0x0040` | MODE bit pattern: TCYN = signed multiply (other operand) |
| `0x108` | `0x0080` | 128 |
| `0x109` | `0xFFFF` | -1 / all-ones |
| `0x10A` | `0xFFFE` | -2 |
| `0x10B` | `0xFFFC` | -4 |
| `0x10C` | `0x8000` | Most-negative 16-bit value |
| `0x10D`–`0x10F` | (uninitialised) | Don't use |

Writing to addresses `0x100`–`0x17F` from the host is silently ignored (this is ROM space).

---

## 4. MODE register (DSP RAM 0x14B)

The MODE register controls multiplier behaviour and a couple of platform flags. Bit layout (MSB first):

```
bits 15..8 : (don't care, software defined)
bit 7      : MSUAlternateDataPage (P89-specific memory remap)
bit 6      : TCYN  - sign treatment of the "A" multiplicand (set = signed)
bit 5      : TCX   - sign treatment of the "X" multiplicand (set = signed)
bit 4      : M     - (reserved/unknown; leave 0)
bits 3..0  : S[4]  - shift amount applied during MAC (left shift on accumulator input)
```

**Common values:**
| MODE value | Effect |
| --- | --- |
| `0x0000` | Default. Unsigned multiply, no shift. Safe baseline. |
| `0x0020` | Signed multiply via TCX. (Verified by T04/T05 to produce signed results.) |
| `0x0060` | Both operands signed (TCX + TCYN). Use this for full signed multiplication. |

**How to set MODE:**

* **From the DSP**: `MOV MODE,(n)` where `n` holds the MODE value (e.g. `MOV MODE,(0x106)` for signed).
* **From the host**: write a word to host address `0x4100:0x0296`. This stays in effect across DSP runs.

Both paths verified to work identically (T04 vs T05).

---

## 5. Instruction encoding

Every DSP instruction is a single 16-bit word:

```
bits 15..11 : opcode      (5 bits)
bit 10      : Conditional (1 bit) — if 1, instruction only executes when C=1
bit 9       : Index       (1 bit) — if 1, IX register is added to the address
bits 8..0   : Address     (9 bits) — operand address (DSP space, 0..0x1FF)
```

Note: the 9-bit address can't directly reference PRAM (which starts at 0x400). The address only ever names a DSP RAM word (`0x000..0x1FF`). For control flow targets, store the desired PC value in DRAM and use `MOV PC,(n)`.

### Building an instruction by hand

```
instruction = (opcode << 11) | (cond << 10) | (idx << 9) | addr
```

### Full opcode table

| Opcode | Mnemonic | Action |
| --- | --- | --- |
| `0x00` | `MOV (nn),MZ0` | RAM[nn] = MZ0 |
| `0x01` | `MOV (nn),MZ1` | RAM[nn] = MZ1 |
| `0x02` | `MOV MZ0,(nn)` | MZ0 = RAM[nn] |
| `0x03` | `MOV MZ1,(nn)` | MZ1 = RAM[nn] |
| `0x04` | `CCF` | Complement Carry Flag (clear/set/toggle C — exact behaviour unverified) |
| `0x05` | `MOV DMA0,(nn)` | DMA0 = RAM[nn]; **triggers DMA cycle** |
| `0x06` | `MOV DMA1,(nn)` | DMA1 = RAM[nn]; sets control bits (no DMA cycle) |
| `0x07` | `MOV DMD,(nn)` | DMD = RAM[nn] |
| `0x08` | `MOV (nn),DMD` | RAM[nn] = DMD |
| `0x09` | `MAC (nn)` | MZ:MZ1:MZ2 += RAM[nn] * X (signed per MODE; accumulates) |
| `0x0A` | `MOV MODE,(nn)` | MODE = RAM[nn] |
| `0x0B` | `MOV IX,(nn)` | IX = RAM[nn] |
| `0x0C` | `MOV (nn),PC` | RAM[nn] = PC (for saving return addresses) |
| `0x0D` | `MOV X,(nn)` | X = RAM[nn] |
| `0x0E` | `MOV (nn),X` | RAM[nn] = X |
| `0x0F` | `MULT (nn)` | MZ0:MZ1:MZ2 = RAM[nn] * X (signed per MODE; **resets accumulator**) |
| `0x10` | `ADD (nn)` | AZ = X + RAM[nn]; updates C |
| `0x11` | `SUB (nn)` | AZ = X - RAM[nn]; updates C (no-borrow form) |
| `0x12` | `AND (nn)` | AZ = X & RAM[nn] |
| `0x13` | `OR (nn)` | AZ = X \| RAM[nn] |
| `0x14` | `ADC (nn)` | AZ = X + RAM[nn] + C; updates C |
| `0x15` | `SBC (nn)` | AZ = X - RAM[nn] - !C; updates C |
| `0x16` | `MOV (nn),AZ` | RAM[nn] = AZ |
| `0x17` | `MOV AZ,(nn)` | AZ = RAM[nn] |
| `0x19` | `MOV DAC1,(nn)` | DAC channel 1 = RAM[nn] (audio output, 14-bit signed effective) |
| `0x1A` | `MOV DAC2,(nn)` | DAC channel 2 = RAM[nn] |
| `0x1B` | `MOV DAC12,(nn)` | Both DACs = RAM[nn] |
| `0x1C` | `GAI (nn)` | Gain/saturate (semantics unverified — for audio output) |
| `0x1D` | `MOV PC,(nn)` | PC = RAM[nn] (jump) |
| `0x1E` | `NOP` | No operation |
| `0x1F` | `INTRUDE` | If host write pending, commit it now |

Opcode `0x18` is unassigned in the EDL.

### Common encoded forms

| Mnemonic | Encoding |
| --- | --- |
| `NOP` | `0xF000` |
| `INTRUDE` | `0xF800` |
| `MOV X,(0x108)` (X = 128) | `0x6908` |
| `MOV (0x180),X` (DRAM[0] = X) | `0x7180` |
| `MOV MODE,(0x106)` (signed) | `0x5106` |
| `MOV PC,(0x182)` (jump via DRAM[2]) | `0xE982` |
| `MULT (0x181)` (X *= DRAM[1]) | `0x7981` |
| `MAC (0x183)` (accumulate += X * DRAM[3]) | `0x4983` |
| `MOV (0x185),X` with cond=1 | `0x7585` |
| `MOV (0x180)+IX,X` (idx=1) | `0x7380` |

---

## 6. Host-side memory map (P89)

Accessed via segment `0x4100` (so `0x4100:OFFSET` reaches the offsets below). All access is byte-wide from the 8088 side; the host bus protocol handles the byte-to-word reassembly.

| Host offset | Contents | Notes |
| --- | --- | --- |
| `0x000`–`0x1FF` | DSP ROM (SINE table) | Reads return ROM contents; writes ignored |
| `0x200`–`0x27F` | Constants ROM | Reads return constants; writes ignored |
| `0x280`–`0x2FF` | DSP registers (R/W) | Mirrors DSP RAM `0x140`–`0x17F` |
| `0x300`–`0x3FF` | DRAM (R/W, 128 host bytes = 128 DSP words = DRAM[0..127]) | Word `N` at host offset `0x300 + N*2` |
| `0x400`–`0x5FF` | PRAM (R/W, 512 host bytes = 256 DSP words) | Byte protocol — see §8 |
| `0x600` | DSP status (low byte) | See §7 |
| `0x601` | DSP status (high byte) | |

For convenience the harness defines `DSP_DATA_SEG = 0x4130`, which is the same as `0x4100:0x0300` — i.e., the start of DRAM. Reading word `N` of DRAM is then just `mov ax, [es:N*2]` with `es = 0x4130`.

### Useful host-addressable DSP register offsets

| Host offset | DSP RAM | Register |
| --- | --- | --- |
| `0x280` | `0x140` | Intrude Data |
| `0x28A` | `0x145` | MZ0 |
| `0x28C` | `0x146` | MZ1 |
| `0x294` | `0x14A` | PC |
| `0x296` | `0x14B` | MODE |
| `0x298` | `0x14C` | X |
| `0x29A` | `0x14D` | AZ |
| `0x29C` | `0x14E` | Intrude Address |

---

## 7. DSP status register (host offset 0x600)

Bit 4 (`0x10`) is the RUN flag. The host controls execution by writing this byte:

| Value written | Effect |
| --- | --- |
| `0x10` (RUN) | Sets RUN; DSP begins/continues executing |
| `0x00` (STOP) | Clears RUN; **also triggers exactly one `DSP_STEP`** (a single instruction tick) |

⚠ **The stop side-effect matters.** Writing `0x00` runs one instruction from whatever was in the prefetch pipeline. Because we always re-load DRAM and PRAM after stopping, this stray step doesn't actually corrupt our tests, but it explains why test code structure looks the way it does.

---

## 8. PRAM byte-write protocol (host loads program)

PRAM is word-organised in the DSP but the host writes it byte-at-a-time. The protocol that works (lifted from AOTMC and confirmed by all 14 tests):

```
For each word W to load at host PRAM offset DI:
    1. Write LOW byte of W to [es:DI]
    2. Write HIGH byte of W to [es:DI+1]
    3. Read LOW byte from [es:DI]      (twice, AOTMC pattern)
    4. Read LOW byte from [es:DI] again
    5. Read HIGH byte from [es:DI+1]
    6. Compare what you read to what you wrote — if mismatch, abort
    7. Advance DI by 2
```

The double-read of the low byte is kept "just because AOTMC does it"; presumed to be belt-and-braces against an edge case in the byte protocol when the DSP is running. Doesn't hurt when stopped.

A verify mismatch should hang the loader visibly (e.g. flash the border) rather than silently continuing — the harness's `dsp_ld` does this.

DRAM has the same byte protocol but in practice a 16-bit `mov word [es:0x300+N*2], value` works in one go for stopped-DSP writes.

---

## 9. Starting / stopping the DSP

The reliable sequence:

```asm
; --- STOP and reset everything ---
mov ax, 0x4100
mov es, ax
mov al, 0x00            ; DSP_STOP
mov byte [es:0x600], al
mov word [es:0x296], 0  ; MODE = 0
mov word [es:0x294], 0  ; PC = 0   (start at PRAM word 0)

; --- Preload DRAM ---
mov word [es:0x300 + N*2], value   ; for each DRAM[N] we care about

; --- Load PRAM (byte protocol + verify, see harness dsp_ld) ---
; ... source bytes 0..511 written to host PRAM offsets 0x400..0x5FF ...

; --- KICK ---
mov al, byte [es:0x400] ; dummy read (AOTMC pattern; possibly redundant)
mov al, 0x10            ; DSP_RUN
mov byte [es:0x600], al

; --- WAIT for the kernel to run enough iterations ---
; e.g. count 2000 NOPs on 8088 = many hundreds of kernel cycles

; --- STOP again ---
mov al, 0x00
mov byte [es:0x600], al
```

---

## 10. INTRUDE: host writes DRAM mid-execution

To inject data into DSP memory while the DSP is running, the host writes to the DRAM byte addresses *as normal*, but the actual commit happens at the DSP's next `INTRUDE` instruction. The DSP **must** execute an `INTRUDE` opcode (`0xF800`) for the write to take effect.

```asm
; while DSP is running...
mov ax, 0x4100
mov es, ax
mov word [es:0x300 + 10*2], 0xBEEF   ; queue write to DRAM[10]
; ...the DSP's next INTRUDE commits it to DRAM[10]
```

**Kernel pattern for INTRUDE-receptive code:**

```
loop_top:
    ; ...do work...
    NOP             ; pipeline filler
    INTRUDE         ; checkpoint: commit pending host write if any
    ; ...more work...
    INTRUDE         ; more frequent = lower latency
    MOV PC,(loop_top_addr)
```

INTRUDE is harmless if there's no pending write — it's effectively a NOP. So scatter them liberally in any kernel meant to receive runtime data.

**Important limit:** the host must wait for one INTRUDE to commit before issuing the next write. There is no acknowledgment signal we've explored yet; in practice, give the DSP at least a few instruction cycles between consecutive host writes. (TODO: empirically determine the safe rate.)

---

## 11. DMA: DSP reads/writes main RAM

The DMA engine handles transfers between DSP DRAM (via DMD register) and main RAM (up to 20-bit address space). It's how the DSP gets at large data sets that won't fit in 256 DRAM words.

### Registers

| DSP RAM | Name | Layout |
| --- | --- | --- |
| `0x142` | DMA0 | Low 16 bits of main-RAM address; *write triggers DMA cycle* |
| `0x143` | DMA1 | Control bits + high 4 bits of address |
| `0x144` | DMD | Data word (read result, or value to write) |

### DMA1 bit layout

```
bits 15..12 : 0
bit 11      : HLD       - DMA hold (will pause CPU)
bit 10      : RW        - 1 = read from main RAM, 0 = write to main RAM
bit 9       : BW        - 1 = byte transfer, 0 = word transfer
bit 8       : LOHI      - byte mode: which half of the DMD word
bits 7..4   : 0
bits 3..0   : ADD_HI    - top 4 bits of 20-bit physical address
```

### DMA word-read sequence (DSP point of view)

```
MOV DMA1,(addr_of_control)   ; set RW=1, BW=0, ADD_HI=high 4 bits
NOP                          ; (settle)
MOV DMA0,(addr_of_low16)     ; ** TRIGGERS DMA **; DMD now holds word read
NOP NOP                      ; (settle, just in case)
MOV (target),DMD             ; copy result into DRAM
```

Example: read word at physical `0x90800`.

- Control word: RW=1 (0x0400), BW=0, ADD_HI=0x9 → DMA1 = `0x0409`
- Address low: `0x0800` → DMA0 = `0x0800`
- After triggering, DMD contains the word that was at `0x90800`.

DMA write is symmetric: set RW=0, put data in DMD first via `MOV DMD,(n)`, then trigger with `MOV DMA0,(n)`.

---

## 12. Pipeline notes (gotchas)

* **One-instruction prefetch.** Each DSP cycle executes the previously-fetched instruction while fetching the next one. This means:
  * After kicking the DSP, the *first* instruction executed is the one prefetched before the previous STOP — typically a stale leftover. Preloading DRAM after STOP fixes most damage.
  * After `MOV PC,(n)`, the instruction at the *old* PC+1 still executes (it's already in the pipeline). Treat this as a **branch delay slot** — put a NOP there.

* **MULT/MAC pipeline.** `MULT` and `MAC` results land in MZ0/MZ1/MZ2 in the same cycle, but defensive style is to put 1–2 NOPs before reading them. The harness uses 2 NOPs and has never seen a problem.

* **C flag persistence.** Only ADD/SUB/ADC/SBC update C. Other instructions preserve it. You can run a long stretch of non-arithmetic between setting C and using it conditionally.

* **PC wrap.** PC is 9-bit; it wraps from `0x4FF` back to `0x400`. PRAM is effectively a circular buffer. Brute-force kernels (filling all 256 words with copies of an N-instruction sequence) exploit this; structured kernels with `MOV PC,(n)` jumps don't need it.

---

## 13. Verified-vs-unverified

**Empirically verified (T01–T14 in `harness_v4`):**

* All memory regions and addressing
* All MOV variants between X, AZ, MZ0, MZ1, DRAM
* Unsigned and signed MULT (both MODE paths)
* MAC accumulation
* ADD and AZ output
* INTRUDE host-to-DRAM write
* DMA word read from main RAM
* `MOV PC,(n)` jump (with branch delay)
* Conditional bit gating on C

**Confirmed from EDL but not yet exercised:**

* SUB, ADC, SBC, AND, OR (mechanics in EDL look identical to ADD)
* `MOV MZ0,(n)` / `MOV MZ1,(n)` (load multiply registers from RAM)
* CCF (complement carry — exact semantics unverified)
* DMA byte mode, DMA write direction
* DAC instructions (DAC1, DAC2, DAC12, GAI)
* `MOV (n),PC` (save current PC, for subroutine returns)
* TCYN behaviour (only TCX exercised in tests)
* The `M` and `S[4]` MODE bits

These would be next on a future test pass if you find yourself relying on any of them.

**Genuinely unknown / undocumented:**

* Exact DSP clock rate (instructions per host millisecond — only inferred from delay-loop counts that "feel right")
* INTRUDE backpressure — how to tell the host the DSP is ready for another write
* DMA HLD behaviour — does it stall the host CPU? For how long?
* Interrupt vectors and conditions
* Reset state of MZ0/MZ1/MZ2/X/AZ/IX (zero initially, but post-reset behaviour after stop/restart is uncertain)
