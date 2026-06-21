# Konix Multi-System DSP: A Programmer's Guide

**The patterns, idioms, and methodology for writing real code on the Konix DSP.**

This document is the companion to `KONIX_DSP_REFERENCE.md`. The reference is what you look up while coding; this guide is what you read first to understand the *shape* of working DSP code on this hardware.

The guide assumes you've at least skimmed the reference and understand the basic memory map and instruction format.

---

## Why a DSP at all?

The 8088 in the Konix runs at around 6 MHz with no hardware multiply. A 16×16 multiplication on the 8088 takes ~120 cycles. A 16×16 multiplication on the DSP is one instruction — call it 1 cycle. The DSP isn't just an audio chip in this machine; it's the *only* fast math available.

That means:

* 3D vertex math (rotation, perspective) belongs on the DSP
* Polygon fill setup (edge stepping, sub-pixel accumulation) belongs on the DSP
* Audio mixing (per-sample multiply + accumulate per channel) belongs on the DSP
* Most other "hot loops" with multiplication or accumulation belong on the DSP

What stays on the 8088: I/O, blitter setup, ISR handling, game logic, high-level coordination. The 8088 is the conductor; the DSP is the orchestra.

---

## Mental model

Think of the DSP as a tiny coprocessor with three properties that shape every program:

1. **256 PRAM words is tight.** You won't write big sprawling routines. A real demo will have small kernels — vertex transform, polygon edge stepper, sample mixer — each fitting in a few dozen instructions. Sometimes you swap kernels between phases (transform pass → fill pass).

2. **256 DRAM words is *very* tight.** Don't store data on the DSP that you don't need *right now*. Stream what you need in (via INTRUDE for short bursts or DMA for blocks), compute, stream results out. The DSP is a calculator, not a database.

3. **The pipeline is one cycle deep.** This is what makes the DSP fast (instruction prefetch overlaps execution), and also what creates the few gotchas you need to remember (branch delay slot; MULT result available "now-ish"). Once internalised, the pipeline disappears from your concerns.

---

## The two coordination patterns

There are exactly two ways the 8088 and the DSP usefully cooperate. Almost every Konix DSP program is one or both of these.

### Pattern A: Batch — host sets up, DSP computes, host reads back

```
8088: stop DSP
8088: write input data to DRAM (or have DSP DMA it in)
8088: load PRAM with the kernel
8088: kick DSP
8088: do something else (blitter? logic?) for a known number of cycles
8088: stop DSP
8088: read result from DRAM
```

This is the right shape when:

* You have a discrete computation (transform 8 vertices)
* You don't care about partial progress
* The computation fits in a known time budget

The harness tests T01–T09 and T11–T14 are all variations of this pattern.

### Pattern B: Streaming — DSP runs forever, host pokes data through INTRUDE

```
8088: stop DSP, load streaming kernel into PRAM, kick
loop:
    8088: write next input data to a known DRAM slot
    8088: wait briefly (let DSP execute next INTRUDE)
    8088: read result from another DRAM slot
    8088: ... do other things ...
    repeat
```

The DSP is in an infinite loop containing both real work and INTRUDE checkpoints. The host doesn't stop the DSP between updates — it just pokes new data into DRAM and the DSP picks it up at the next INTRUDE.

This is the right shape for:

* Audio mixing (DSP runs forever generating samples)
* Animated streaming demos (per-frame parameters poked in)
* Anything where "stop the DSP" would introduce audible/visible glitches

T10 in the harness tests the INTRUDE mechanism that makes this pattern possible.

You can also combine the two: a DSP that hosts a long-lived loop but occasionally gets stopped for a major reconfiguration, then resumed.

---

## The brute-force PRAM trick (and when you don't need it)

If you read the harness kernels for T01–T11, you'll notice almost all of them use the same trick: the kernel is N instructions long, and it's `%rep`'d to fill all 256 PRAM words. This is the **brute-force pattern**, and it deserves explanation.

### Why it exists

PRAM is 256 words and PC wraps from word 255 back to word 0. If you kick the DSP and the PC doesn't happen to be at the start of your kernel, your kernel still works — because every spot in PRAM is the start of *some* kernel iteration, and within one or two iterations the DSP converges to producing the right answer regardless of where it began. You also don't have to worry about the prefetch-pipeline stale instruction corrupting your first cycle; by iteration 2 it's irrelevant.

Combined with reading "the latest result" (you only ever look at DRAM[N] after the DSP has stopped, so you see the answer from the last completed iteration), this makes the brute-force pattern *extremely robust*. It worked beautifully in T01 and let us prove every primitive before worrying about PC management.

### When you don't need it

In `dsp_pre_test` (v4 of the harness), we added a host write to reset PC to 0 before each kick. With PC always starting at 0, your kernel can have a meaningful start; you don't need to repeat it. T12 (the jump test) uses a *structured* PRAM layout because the test depends on specific PC values.

In real demos:

* For computation that just runs in a loop forever (audio mixer, infinite transform loop), use a structured kernel with `MOV PC,(n)` at the end to loop back. PC=0 to start, well-defined flow.
* For computation that needs to run "for a while and then we'll stop", you can either use brute force (simpler) or structured + PC=0 + ensure the kernel naturally stays in its body (e.g. the kernel itself is a `MOV PC,(loop_top)` loop). The structured approach is easier to reason about and uses less PRAM.

In short: the brute-force pattern was the right tool for the harness. Going forward, prefer structured kernels with PC=0 — and only fall back to brute-force if you're debugging "is the kernel even being reached?".

---

## The pipeline, in detail

The DSP's STEP cycle is roughly:

```
1.  PC      = RAM[AddrPC]
2.  currentInstruction = nextInstruction      (the one fetched last cycle)
3.  nextInstruction    = RAM[PC]              (fetch new one for next cycle)
4.  PC      = PC + 1
5.  RAM[AddrPC] = PC_ACTUAL                   (write back PC for next time)
6.  if condition matches: EXECUTE currentInstruction
```

Note that `nextInstruction` is held in a hardware register internal to the DSP — it is *not* in DSP RAM. This has two consequences:

### Branch delay slot

When a `MOV PC,(n)` instruction executes (step 6), it changes RAM[AddrPC] to a new target. But `nextInstruction` was already fetched from the *old* PC+1 in step 3 of this same cycle. On the next cycle:

* `currentInstruction` becomes the previously-fetched (old PC+1) instruction
* It executes
* *Then* on the cycle after that, fetch happens from the new PC

So the instruction immediately after `MOV PC,(n)` always executes, regardless of the jump. This is the **branch delay slot**. Always put a NOP there unless you specifically want that side effect.

```
MOV X,(0x108)         ; do useful work
MOV PC,(loop_top)     ; about to jump
NOP                   ; delay slot — executes before the jump completes
; we never reach here directly; we end up at loop_top
```

### Stale instruction after STOP

When the host stops the DSP and then restarts it later, the `nextInstruction` register still holds whatever was last prefetched — possibly an instruction from a kernel you've since overwritten in PRAM. After kicking, the first instruction executed is this stale one. It typically does no harm (the kernels we ran end with NOPs), but it's why preloading DRAM after STOP is good practice — any DRAM the stale instruction might write gets fixed before our real work runs.

### MULT/MAC latency

`MULT` and `MAC` deposit their results in MZ0/MZ1/MZ2 in the same cycle they execute. In principle you can read MZ0 the very next instruction. In practice, the harness inserts 2 NOPs after MULT/MAC before any `MOV (n),MZ0` and has had no problems. Going below this is fine if you measure; the conservative pattern is "1–2 NOPs after MULT/MAC".

---

## Idioms for real work

### Vertex transform (rotation)

Given a 3D point `(x, y, z)` in DRAM, multiply by a 3×3 matrix in DRAM, producing `(x', y', z')`. The MAC chain makes this almost a transliteration of the math:

```
; X' = m00*x + m01*y + m02*z
MOV X,(x);   MULT (m00)   ; MZ = m00*x
MOV X,(y);   MAC (m01)    ; MZ += m01*y
MOV X,(z);   MAC (m02)    ; MZ += m02*z
NOP NOP
MOV (xp),MZ0               ; xp = low word of result
; same pattern for Y' and Z'
```

About 12 instructions for one fully-transformed coordinate. Three of those per point = ~36 instructions per vertex. Plus a NOP for pipeline. Plus the index/loop overhead if you're iterating.

For Q-format math (e.g. fixed-point `Q8.8` or `Q4.12`): the matrix coefficients are scaled by 2^N; the multiply result has 2N fractional bits; you take MZ0 if the result fits in 16 bits, or use MZ0/MZ1 together for the full 32-bit product and shift right by N.

### Sample mixer (audio)

Per sample period, sum N channels each contributing `sample * volume`. The MAC chain again:

```
; per-sample mix of, say, 4 channels:
MOV X,(s0);  MULT (v0)    ; MZ = s0*v0
MOV X,(s1);  MAC (v1)     ; MZ += s1*v1
MOV X,(s2);  MAC (v2)     ; MZ += s2*v2
MOV X,(s3);  MAC (v3)     ; MZ += s3*v3
NOP NOP
MOV DAC12,(?)              ; output to DACs (need to move MZ0 into DRAM first)
```

A practical mixer would: have the host stream new sample data into channel slots via INTRUDE; have the DSP run a long loop containing MULT/MAC chains, output to DAC, advance sample pointers, INTRUDE checkpoint, loop. The sample-pointer advancement is also done on the DSP (it's just an ADD or an indexed access).

### Counted loop

Combine `ADD (one)`, the Carry flag, and conditional `MOV PC`:

```
; counter = -N initially; loop until counter overflows (carries to 0+ side)
loop_top:
    ; ...body...
    MOV X,(counter)
    ADD (one)              ; counter += 1; C set when wrapped past 0xFFFF
    MOV (counter),AZ
    [cond=0] MOV PC,(loop_top_addr)   ; loop while not carried
    ; ...code after loop...
```

(Conditional bit gating on C means `[cond=1]` runs when C=1; for "loop while no carry", you'd need to invert — either flip the logic so C=1 means "exit", or use `[cond=1] MOV PC,(after_loop_addr)` to branch *out* of the loop on carry.)

This is the loop primitive. Add the body of your choice.

### Subroutine call/return

The DSP has no hardware stack, but `MOV (n),PC` and `MOV PC,(n)` together let you fake one:

```
; "call" — save return address in a known DRAM slot, jump to subroutine
MOV (ret_slot),PC          ; saves PC of *next* instruction (because PC has already advanced)
MOV PC,(subroutine_addr)
NOP                         ; delay slot

subroutine:
    ; ...do work...
    MOV PC,(ret_slot)       ; "return"
    NOP
```

Only one level of return address per slot — for nested subroutines, allocate one DRAM word per nesting level, or use a small DRAM "stack pointer" you increment by hand.

---

## How to use the harness for new investigations

The harness isn't just for the existing T01–T14 tests; it's a template for any "does the DSP actually do X?" question you have. The pattern is:

1. **Write a kernel that exercises X.** Keep it small — ideally one or two interesting instructions, padded with NOPs.
2. **Pre-load DRAM** with input values and sentinel values for outputs.
3. **Choose an expected output** based on your hypothesis. If you're not sure, pick the value the EDL implies and let the test confirm or refute it.
4. **Add a `do_test_NN` procedure** following the existing pattern, and a `tNN_prog` kernel.
5. **Call it from `start:` after the existing tests** and bump the y coordinate.
6. **Run, photograph, share the screenshot.**

If the test passes, you've verified another fact about the DSP. If it fails, the *value* in the actual column tells you what's actually happening — and that's data you couldn't have gotten any other way.

Recommended discipline: **don't delete tests once they pass**. The whole suite is the regression check. If a future change to your platform setup, emulator version, or kernel pattern breaks an assumption, re-running the harness will catch it immediately.

---

## What "good" Konix DSP code looks like

After all this work, here are the rules of thumb I'd suggest:

1. **Reset PC to 0 before kicking.** Deterministic start = simpler reasoning.
2. **Structured kernels with `MOV PC,(loop_top)` end.** Use brute force only for one-shot tests.
3. **NOPs in branch delay slots, always.** Don't try to be clever there until you have a measured reason.
4. **1–2 NOPs after MULT/MAC.** Conservative; cheap.
5. **Document the DRAM layout at the top of your file.** "DRAM[0..7] = input vertex, DRAM[8..16] = matrix, DRAM[17..24] = output, DRAM[25..31] = scratch."
6. **Use the constants ROM.** `MOV X,(0x101)` is the cheapest way to get 1; `MOV X,(0x109)` gives you -1; `MOV MODE,(0x106)` gives signed multiply. Almost any small constant you need is already in the ROM.
7. **Pre-load DRAM before every test/run.** Eliminates a whole class of "but I never set that" bugs.
8. **Leave the harness's display routines in your real demos.** Even if you only print one value (e.g. a debug counter), it's the only sane way to see what's happening when something goes wrong.
9. **For streaming, scatter INTRUDEs liberally.** They're free if there's no pending write.
10. **For DMA, set DMA1 first, then DMA0 (DMA0 triggers).** Order matters.

---

## Closing note: why this was worth doing

When we started this project, "writing Konix DSP code" meant "guess at opcodes, run the cube, look at the wonky output, change something, try again". The 3D cube was working but distorted, and we had no way to tell whether MULT was broken, or our MODE setup was wrong, or our memory addressing was off, or our pipeline assumptions were incorrect.

After fourteen tests, every one of those questions has been answered empirically. We know what MODE means. We know that DRAM works at any offset. We know MAC accumulates correctly. We know the host can write DRAM mid-execution via INTRUDE. We know DMA works exactly as the EDL describes.

We didn't just fix one bug — we built the *instrument* that lets us see what the DSP is actually doing, and then used it to systematically verify every primitive we'll ever need. The Konix DSP is no longer a mystery; it's a documented coprocessor with a clear, reliable programming model.

The cube can finally be built properly. Audio is no longer terrifying — it's just another set of kernels using the same primitives. And anyone who comes after us with a working Konix and an interest in writing for it now has a complete reference, instead of having to do this entire archaeology dig themselves.

That's a real result.
