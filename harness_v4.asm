; =====================================================================
; Konix Multi-System: DSP TEST HARNESS v4
;
; Adds T12-T14 to complete the primitive-verification suite:
;   T12 - MOV PC,(n) flow-control (unconditional jump)
;   T13 - DMA word read from main RAM to DSP DRAM
;   T14 - Conditional bit (cond=1) gates execution on Carry flag
;
; Also enhances dsp_pre_test to reset DSP PC to 0 (via host write to
; AddrPC at 0x294). This makes test execution deterministic - kernels
; start from PRAM word 0 rather than wherever PC happened to be from
; the previous test. The brute-force pattern in T01-T11 is now
; redundant but still works.
;
; Notes on pipeline:
;   The DSP has a 1-instruction prefetch pipeline (currentInstruction
;   from the previous fetch executes while nextInstruction is fetched).
;   This means:
;     - After kick, the first instruction executed is whatever was
;       prefetched before STOP - typically a leftover NOP, but could
;       be a stale instruction from the previous test's kernel.
;     - MOV PC,(n) has a "branch delay slot": the instruction AFTER
;       the jump (the one already in the pipeline) also executes.
;       T12 uses NOPs in delay slots.
; =====================================================================
BITS 16
CPU 8086

%define DATA_PAD     0x2000

%define INTL         0x00
%define STARTL       0x02
%define ENDL         0x11
%define SCROLL1      0x08
%define SCROLL3      0x0A
%define ACK          0x0B
%define MODE_PORT    0x0C
%define BORDL        0x0D
%define PMASK        0x0F
%define INDEX        0x10
%define DIS          0x16
%define MEM          0x13
%define BLPROG0      0x30
%define BLPROG2      0x32
%define BLSTAT       0x26
%define BLCON        0x34

%define DSP_SEG      0x4100
%define DSP_DRAM     0x0300
%define DSP_MODE     0x0296     ; word addr 0x14B  (ALU MODE)
%define DSP_PC       0x0294     ; word addr 0x14A  (program counter, bits 0..8)
%define DSP_PRAM     0x0400
%define DSP_STATUS   0x0600
%define DSP_DATA_SEG 0x4130
%define DSP_STOP     0x00
%define DSP_RUN      0x10

%define SENTINEL     0xDEAD
%define SENTINEL2    0xCAFE

%macro bum_run 1
    out BLPROG0, ax
    mov al, 0x09
    mov ah, %1
    out BLPROG2, ax
%endmacro

; =====================================================================
SECTION data_seg vstart=0 start=0

clr_prog:    db 0,0,0,  0,1,0,  0x22,0xC0,  200,0,0,  0,0

dh_val:    dw 0
dh_x:      dw 0
dh_y:      dw 0

test_expected: times 16 dw 0
test_actual:   times 16 dw 0
test_state:    times 16 db 0

%define CC 255
font_0: db 00,CC,CC,CC,00, CC,CC,00,CC,CC, CC,CC,00,CC,CC, CC,CC,00,CC,CC, CC,CC,00,CC,CC, CC,CC,00,CC,CC, 00,CC,CC,CC,00
font_1: db 00,00,CC,CC,00, 00,CC,CC,CC,00, 00,00,CC,CC,00, 00,00,CC,CC,00, 00,00,CC,CC,00, 00,00,CC,CC,00, 00,CC,CC,CC,CC
font_2: db 00,CC,CC,CC,00, CC,CC,00,CC,CC, 00,00,00,CC,CC, 00,00,CC,CC,00, 00,CC,CC,00,00, CC,CC,00,00,00, CC,CC,CC,CC,CC
font_3: db 00,CC,CC,CC,00, CC,CC,00,CC,CC, 00,00,00,CC,CC, 00,00,CC,CC,00, 00,00,00,CC,CC, CC,CC,00,CC,CC, 00,CC,CC,CC,00
font_4: db 00,00,00,CC,CC, 00,00,CC,CC,CC, 00,CC,CC,00,CC, CC,CC,00,00,CC, CC,CC,CC,CC,CC, 00,00,00,00,CC, 00,00,00,00,CC
font_5: db CC,CC,CC,CC,CC, CC,CC,00,00,00, CC,CC,00,00,00, CC,CC,CC,CC,00, 00,00,00,CC,CC, CC,CC,00,CC,CC, 00,CC,CC,CC,00
font_6: db 00,CC,CC,CC,00, CC,CC,00,CC,CC, CC,CC,00,00,00, CC,CC,CC,CC,00, CC,CC,00,CC,CC, CC,CC,00,CC,CC, 00,CC,CC,CC,00
font_7: db CC,CC,CC,CC,CC, 00,00,00,CC,CC, 00,00,00,CC,CC, 00,00,CC,CC,00, 00,CC,CC,00,00, 00,CC,CC,00,00, 00,CC,CC,00,00
font_8: db 00,CC,CC,CC,00, CC,CC,00,CC,CC, CC,CC,00,CC,CC, 00,CC,CC,CC,00, CC,CC,00,CC,CC, CC,CC,00,CC,CC, 00,CC,CC,CC,00
font_9: db 00,CC,CC,CC,00, CC,CC,00,CC,CC, CC,CC,00,CC,CC, 00,CC,CC,CC,CC, 00,00,00,CC,CC, CC,CC,00,CC,CC, 00,CC,CC,CC,00
font_A: db 00,CC,CC,CC,00, CC,CC,00,CC,CC, CC,CC,00,CC,CC, CC,CC,CC,CC,CC, CC,CC,00,CC,CC, CC,CC,00,CC,CC, CC,CC,00,CC,CC
font_B: db CC,CC,CC,CC,00, CC,CC,00,CC,CC, CC,CC,00,CC,CC, CC,CC,CC,CC,00, CC,CC,00,CC,CC, CC,CC,00,CC,CC, CC,CC,CC,CC,00
font_C: db 00,CC,CC,CC,00, CC,CC,00,CC,CC, CC,CC,00,00,00, CC,CC,00,00,00, CC,CC,00,00,00, CC,CC,00,CC,CC, 00,CC,CC,CC,00
font_D: db CC,CC,CC,CC,00, CC,CC,00,CC,CC, CC,CC,00,CC,CC, CC,CC,00,CC,CC, CC,CC,00,CC,CC, CC,CC,00,CC,CC, CC,CC,CC,CC,00
font_E: db CC,CC,CC,CC,CC, CC,CC,00,00,00, CC,CC,00,00,00, CC,CC,CC,CC,00, CC,CC,00,00,00, CC,CC,00,00,00, CC,CC,CC,CC,CC
font_F: db CC,CC,CC,CC,CC, CC,CC,00,00,00, CC,CC,00,00,00, CC,CC,CC,CC,00, CC,CC,00,00,00, CC,CC,00,00,00, CC,CC,00,00,00

font_table:
    dw font_0, font_1, font_2, font_3
    dw font_4, font_5, font_6, font_7
    dw font_8, font_9, font_A, font_B
    dw font_C, font_D, font_E, font_F

; DMA target: a known 16-bit value placed at a known physical address.
; Data segment loads at 0x9000:0000 = physical 0x90000, so this lands
; at physical 0x90800. The DSP DMA will read from this address.
times 0x800 - ($ - $$) db 0
dma_target: dw 0x1357

; =====================================================================
SECTION code_seg vstart=0 start=DATA_PAD
start:
    mov ax, 0x9000
    mov ds, ax
    mov ss, ax
    mov sp, 0x0FFF
    cld

    xor ax, ax
    out BORDL, ax
    mov ax, 60
    out STARTL, ax
    mov ax, 259
    out ENDL, ax
    mov al, 1
    out MEM, al
    out MODE_PORT, al
    xor al, al
    out PMASK, al
    out INDEX, al
    xor ax, ax
    out SCROLL1, ax
    out SCROLL3, al

    mov ax, 0x4000
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 256
.pz:
    stosw
    loop .pz
    mov di, 255*2
    mov ax, 0x0FFF
    stosw
    mov di, 254*2
    mov ax, 0x00F0
    stosw
    mov di, 253*2
    mov ax, 0x0F00
    stosw
    mov di, 252*2
    mov ax, 0x0F0F
    stosw

    push ds
    xor ax, ax
    mov ds, ax
    mov word [0x21*4], vblank_isr
    mov word [0x21*4+2], 0x8000
    pop ds
    mov ax, 255
    out INTL, ax
    mov al, 0x0F
    out ACK, al
    mov al, 0x0E
    out DIS, al
    xor al, al
    out BLCON, al
    sti

    mov ax, 0x9000
    mov es, ax
    mov ax, clr_prog
    bum_run 0x11
    call blit_wait

    ; Sanity row
    mov ax, 0xDEAD
    mov word [dh_x], 4
    mov word [dh_y], 2
    call draw_hex16
    mov ax, 0xBEEF
    mov word [dh_x], 40
    mov word [dh_y], 2
    call draw_hex16

    ; Run all tests
    call do_test_01
    call do_test_02
    call do_test_03
    call do_test_04
    call do_test_05
    call do_test_06
    call do_test_07
    call do_test_08
    call do_test_09
    call do_test_10
    call do_test_11
    call do_test_12
    call do_test_13
    call do_test_14

.spin:
    hlt
    jmp .spin

; =====================================================================
; --- TEST PROCEDURES ---
; =====================================================================

do_test_01:
    mov word [test_expected + 1*2], 0x0080
    call dsp_pre_test
    mov word [es:DSP_DRAM + 0*2], SENTINEL
    mov si, t01_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 2000
    call dsp_wait_stop
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:0*2]
    mov [test_actual + 1*2], ax
    mov bx, [test_expected + 1*2]
    mov dx, SENTINEL
    call classify_result
    mov [test_state + 1], al
    mov ax, 1
    mov cx, 20
    call render_test_row
    ret

do_test_02:
    mov word [test_expected + 2*2], 0x55AA
    call dsp_pre_test
    mov word [es:DSP_DRAM + 0*2], 0x55AA
    mov si, t02_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 2000
    call dsp_wait_stop
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:0*2]
    mov [test_actual + 2*2], ax
    mov bx, [test_expected + 2*2]
    mov dx, 0x55AA
    call classify_result
    mov [test_state + 2], al
    mov ax, 2
    mov cx, 30
    call render_test_row
    ret

do_test_03:
    mov word [test_expected + 3*2], 0x0100
    call dsp_pre_test
    mov word [es:DSP_DRAM + 0*2], 0x0010
    mov word [es:DSP_DRAM + 1*2], 0x0010
    mov word [es:DSP_DRAM + 2*2], SENTINEL2
    mov si, t03_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 2000
    call dsp_wait_stop
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:2*2]
    mov [test_actual + 3*2], ax
    mov bx, [test_expected + 3*2]
    mov dx, SENTINEL2
    call classify_result
    mov [test_state + 3], al
    mov ax, 3
    mov cx, 40
    call render_test_row
    ret

do_test_04:
    mov word [test_expected + 4*2], 0xFFFF
    call dsp_pre_test
    mov word [es:DSP_DRAM + 0*2], 0xFFFF
    mov word [es:DSP_DRAM + 1*2], 0x0010
    mov word [es:DSP_DRAM + 3*2], SENTINEL2
    mov si, t04_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 2000
    call dsp_wait_stop
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:3*2]
    mov [test_actual + 4*2], ax
    mov bx, [test_expected + 4*2]
    mov dx, SENTINEL2
    call classify_result
    mov [test_state + 4], al
    mov ax, 4
    mov cx, 50
    call render_test_row
    ret

do_test_05:
    mov word [test_expected + 5*2], 0xFFFF
    call dsp_pre_test
    mov word [es:DSP_DRAM + 0*2], 0xFFFF
    mov word [es:DSP_DRAM + 1*2], 0x0010
    mov word [es:DSP_DRAM + 3*2], SENTINEL2
    mov word [es:DSP_MODE], 0x0020
    mov si, t05_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 2000
    call dsp_wait_stop
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:3*2]
    mov [test_actual + 5*2], ax
    mov bx, [test_expected + 5*2]
    mov dx, SENTINEL2
    call classify_result
    mov [test_state + 5], al
    mov ax, 5
    mov cx, 60
    call render_test_row
    ret

do_test_06:
    mov word [test_expected + 6*2], 0x0080
    call dsp_pre_test
    mov word [es:DSP_DRAM + 5*2], SENTINEL2
    mov si, t06_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 2000
    call dsp_wait_stop
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:5*2]
    mov [test_actual + 6*2], ax
    mov bx, [test_expected + 6*2]
    mov dx, SENTINEL2
    call classify_result
    mov [test_state + 6], al
    mov ax, 6
    mov cx, 70
    call render_test_row
    ret

do_test_07:
    mov word [test_expected + 7*2], 0x01F4
    call dsp_pre_test
    mov word [es:DSP_DRAM + 0*2], 0x000A
    mov word [es:DSP_DRAM + 1*2], 0x000A
    mov word [es:DSP_DRAM + 2*2], 0x0014
    mov word [es:DSP_DRAM + 3*2], 0x0014
    mov word [es:DSP_DRAM + 4*2], SENTINEL2
    mov si, t07_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 2000
    call dsp_wait_stop
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:4*2]
    mov [test_actual + 7*2], ax
    mov bx, [test_expected + 7*2]
    mov dx, SENTINEL2
    call classify_result
    mov [test_state + 7], al
    mov ax, 7
    mov cx, 80
    call render_test_row
    ret

do_test_08:
    mov word [test_expected + 8*2], 0x2345
    call dsp_pre_test
    mov word [es:DSP_DRAM + 0*2], 0x1234
    mov word [es:DSP_DRAM + 1*2], 0x1111
    mov word [es:DSP_DRAM + 2*2], SENTINEL2
    mov si, t08_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 2000
    call dsp_wait_stop
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:2*2]
    mov [test_actual + 8*2], ax
    mov bx, [test_expected + 8*2]
    mov dx, SENTINEL2
    call classify_result
    mov [test_state + 8], al
    mov ax, 8
    mov cx, 90
    call render_test_row
    ret

do_test_09:
    mov word [test_expected + 9*2], 0xABCD
    call dsp_pre_test
    mov word [es:DSP_DRAM + 0*2], 0xABCD
    mov word [es:DSP_DRAM + 1*2], SENTINEL2
    mov si, t09_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 2000
    call dsp_wait_stop
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:1*2]
    mov [test_actual + 9*2], ax
    mov bx, [test_expected + 9*2]
    mov dx, SENTINEL2
    call classify_result
    mov [test_state + 9], al
    mov ax, 9
    mov cx, 100
    call render_test_row
    ret

do_test_10:
    mov word [test_expected + 10*2], 0xBEEF
    call dsp_pre_test
    mov word [es:DSP_DRAM + 10*2], SENTINEL2
    mov si, t10_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 200
.spin1:
    nop
    loop .spin1
    mov word [es:DSP_DRAM + 10*2], 0xBEEF
    mov cx, 1000
.spin2:
    nop
    loop .spin2
    mov al, DSP_STOP
    mov byte [es:DSP_STATUS], al
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:10*2]
    mov [test_actual + 10*2], ax
    mov bx, [test_expected + 10*2]
    mov dx, SENTINEL2
    call classify_result
    mov [test_state + 10], al
    mov ax, 10
    mov cx, 110
    call render_test_row
    ret

do_test_11:
    mov word [test_expected + 11*2], 0x0080
    call dsp_pre_test
    mov word [es:DSP_DRAM + 0*2], SENTINEL
    mov word [es:DSP_DRAM + 4*2], SENTINEL2
    mov si, t11_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 2000
    call dsp_wait_stop
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:4*2]
    mov [test_actual + 11*2], ax
    mov bx, [test_expected + 11*2]
    mov dx, SENTINEL2
    call classify_result
    mov [test_state + 11], al
    mov ax, 11
    mov cx, 120
    call render_test_row
    ret

; ---------------------------------------------------------------------
; T12 - MOV PC,(n) unconditional jump
; PRAM is laid out NOT as brute force - has a specific structure:
;   word 0:  MOV X,(0x108)     ; X = 0x80
;   word 1:  MOV PC,(0x182)    ; jump to DRAM[2] = 0x0420
;   word 2..31: NOPs
;   word 32: MOV X,(0x108)     ; (re-set X at target)
;   word 33: MOV (0x183),X     ; DRAM[3] = X = 0x80 [TARGET REACHED]
;   word 34: MOV PC,(0x182)    ; loop back to target
;   word 35..255: NOPs
;
; Pre: DRAM[2] = 0x0420 (= word 32 + 0x400 base)
;      DRAM[3] = SENTINEL2
; Expect: DRAM[3] = 0x0080
; ---------------------------------------------------------------------
do_test_12:
    mov word [test_expected + 12*2], 0x0080
    call dsp_pre_test
    mov word [es:DSP_DRAM + 2*2], 0x0420    ; target PC value
    mov word [es:DSP_DRAM + 3*2], SENTINEL2
    mov si, t12_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 2000
    call dsp_wait_stop
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:3*2]
    mov [test_actual + 12*2], ax
    mov bx, [test_expected + 12*2]
    mov dx, SENTINEL2
    call classify_result
    mov [test_state + 12], al
    mov ax, 12
    mov cx, 130
    call render_test_row
    ret

; ---------------------------------------------------------------------
; T13 - DMA word read from main RAM
; Reads main RAM at physical 0x90800 (where dma_target = 0x1357 lives
; in our data segment) into DSP DRAM[2] via the DMA mechanism.
;
; DMA1 = 0x0409 (RW=1 read, BW=0 word, ADD_HI=9)
; DMA0 = 0x0800 (low 16 bits of physical address)
; Combined physical address = (0x9 << 16) | 0x0800 = 0x90800
;
; Kernel: MOV DMA1,(0x180); NOP; MOV DMA0,(0x181) [triggers DMA];
;         NOP NOP; MOV (0x182),DMD; NOP NOP
;
; Pre: DRAM[0]=0x0409, DRAM[1]=0x0800, DRAM[2]=SENTINEL2,
;      data_seg offset 0x800 = 0x1357
; Expect: DRAM[2] = 0x1357
; ---------------------------------------------------------------------
do_test_13:
    mov word [test_expected + 13*2], 0x1357
    call dsp_pre_test
    mov word [es:DSP_DRAM + 0*2], 0x0409    ; DMA1 control
    mov word [es:DSP_DRAM + 1*2], 0x0800    ; DMA0 address low
    mov word [es:DSP_DRAM + 2*2], SENTINEL2
    mov si, t13_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 2000
    call dsp_wait_stop
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:2*2]
    mov [test_actual + 13*2], ax
    mov bx, [test_expected + 13*2]
    mov dx, SENTINEL2
    call classify_result
    mov [test_state + 13], al
    mov ax, 13
    mov cx, 140
    call render_test_row
    ret

; ---------------------------------------------------------------------
; T14 - Conditional bit gates execution on Carry (C=0 case)
; Kernel runs an ADD that does NOT produce a carry, then attempts a
; conditional MOV. If conditional bit works correctly, the MOV is
; skipped and DRAM[5] keeps its preloaded value.
;
; Kernel: MOV X,(0x108)         ; X = 0x80
;         ADD (0x108)           ; AZ = 0x80 + 0x80 = 0x100, no carry. C=0.
;         MOV X,(0x109)         ; X = 0xFFFF (would-be wrong value)
;         [cond=1] MOV (0x185),X ; should NOT execute (C=0)
;         NOP NOP NOP NOP
;
; Pre: DRAM[5] = 0xACE1 (a marker value distinct from anything else)
; Expect: DRAM[5] = 0xACE1 (untouched)
; If conditional bit broken (always executes): DRAM[5] = 0xFFFF
; ---------------------------------------------------------------------
do_test_14:
    mov word [test_expected + 14*2], 0xACE1
    call dsp_pre_test
    mov word [es:DSP_DRAM + 5*2], 0xACE1
    mov si, t14_prog
    call load_pram_cs_si
    call dsp_kick
    mov cx, 2000
    call dsp_wait_stop
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:5*2]
    mov [test_actual + 14*2], ax
    mov bx, [test_expected + 14*2]
    mov dx, 0xACE1                  ; sentinel == expected, never triggers magenta
    call classify_result
    mov [test_state + 14], al
    mov ax, 14
    mov cx, 150
    call render_test_row
    ret

; =====================================================================
; --- DSP / RENDER HELPERS ---
; =====================================================================

; ---------------------------------------------------------------------
; dsp_pre_test (v4) - Stop DSP, set ES=DSP_SEG, reset MODE=0, reset PC=0.
; The PC reset (NEW in v4) makes test execution deterministic.
; ---------------------------------------------------------------------
dsp_pre_test:
    mov ax, DSP_SEG
    mov es, ax
    mov al, DSP_STOP
    mov byte [es:DSP_STATUS], al
    mov word [es:DSP_MODE], 0x0000
    mov word [es:DSP_PC], 0x0000        ; reset PC to start of PRAM
    ret

load_pram_cs_si:
    push ds
    push cs
    pop ds
    mov di, DSP_PRAM
    mov cx, 256
    call dsp_ld
    pop ds
    ret

dsp_kick:
    mov al, byte [es:DSP_PRAM]
    mov al, DSP_RUN
    mov byte [es:DSP_STATUS], al
    ret

dsp_wait_stop:
.lp:
    nop
    nop
    nop
    nop
    nop
    loop .lp
    mov al, DSP_STOP
    mov byte [es:DSP_STATUS], al
    ret

classify_result:
    cmp ax, bx
    je .pass
    cmp ax, dx
    je .sent
    mov al, 2
    ret
.pass:
    mov al, 1
    ret
.sent:
    mov al, 3
    ret

render_test_row:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov word [dh_x], 4
    mov [dh_y], cx
    call draw_dec2
    mov bl, al
    mov bh, 0
    mov si, bx
    add bx, bx
    mov ax, [test_expected + bx]
    mov word [dh_x], 24
    mov [dh_y], cx
    call draw_hex16
    mov ax, [test_actual + bx]
    mov word [dh_x], 60
    mov [dh_y], cx
    call draw_hex16
    mov al, [test_state + si]
    mov bx, 95
    call draw_state_marker
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

blit_wait:
.bw:
    in al, BLSTAT
    test al, al
    jnz .bw
    ret

vblank_isr:
    out ACK, al
    iret

dsp_ld:
    lodsw
    mov byte [es:di], al
    inc di
    mov byte [es:di], ah
    dec di
    mov dl, byte [es:di]
    mov dl, byte [es:di]
    inc di
    mov dh, byte [es:di]
    inc di
    cmp ax, dx
    je .ok
.fail:
    inc ax
    out BORDL, al
    jmp .fail
.ok:
    loop dsp_ld
    ret

draw_hex16:
    push ax
    push bx
    push cx
    push dx
    mov [dh_val], ax
    mov ax, [dh_val]
    mov cl, 12
    shr ax, cl
    and al, 0x0F
    call draw_one_nibble
    add word [dh_x], 6
    mov ax, [dh_val]
    mov cl, 8
    shr ax, cl
    and al, 0x0F
    call draw_one_nibble
    add word [dh_x], 6
    mov ax, [dh_val]
    mov cl, 4
    shr ax, cl
    and al, 0x0F
    call draw_one_nibble
    add word [dh_x], 6
    mov ax, [dh_val]
    and al, 0x0F
    call draw_one_nibble
    add word [dh_x], 6
    pop dx
    pop cx
    pop bx
    pop ax
    ret

draw_dec2:
    push ax
    push bx
    push cx
    push dx
    xor ah, ah
    mov dl, 10
    div dl
    mov bl, ah
    xor ah, ah
    call draw_one_nibble
    add word [dh_x], 6
    mov al, bl
    xor ah, ah
    call draw_one_nibble
    add word [dh_x], 6
    pop dx
    pop cx
    pop bx
    pop ax
    ret

draw_one_nibble:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    cld
    and ax, 0x000F
    shl ax, 1
    mov si, font_table
    add si, ax
    mov si, [si]
    xor ax, ax
    mov es, ax
    mov ax, [dh_y]
    mov ah, al
    mov al, [dh_x]
    mov di, ax
    mov dx, 7
.row:
    movsb
    movsb
    movsb
    movsb
    movsb
    add di, 256-5
    dec dx
    jnz .row
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

draw_state_marker:
    push ax
    push bx
    push cx
    push dx
    push di
    push es
    cmp al, 1
    je .pass
    cmp al, 2
    je .fail
    cmp al, 3
    je .sent
    mov dl, 255
    jmp .have
.pass:
    mov dl, 254
    jmp .have
.fail:
    mov dl, 253
    jmp .have
.sent:
    mov dl, 252
.have:
    xor ax, ax
    mov es, ax
    mov ah, cl
    mov al, bl
    mov di, ax
    mov cx, 7
.row:
    push cx
    mov cx, 7
.col:
    mov [es:di], dl
    inc di
    loop .col
    add di, 256-7
    pop cx
    loop .row
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =====================================================================
; --- DSP TEST KERNELS ---
; =====================================================================

t01_prog:
%rep 64
    dw 0x6908
    dw 0x7180
    dw 0xF000
    dw 0xF000
%endrep

t02_prog:
%rep 256
    dw 0xF000
%endrep

t03_prog:
%rep 32
    dw 0x6980
    dw 0x7981
    dw 0xF000
    dw 0xF000
    dw 0x0182
    dw 0xF000
    dw 0xF000
    dw 0xF000
%endrep

t04_prog:
%rep 32
    dw 0x5106
    dw 0x6980
    dw 0x7981
    dw 0xF000
    dw 0xF000
    dw 0x0983
    dw 0xF000
    dw 0xF000
%endrep

t05_prog:
%rep 32
    dw 0x6980
    dw 0x7981
    dw 0xF000
    dw 0xF000
    dw 0x0983
    dw 0xF000
    dw 0xF000
    dw 0xF000
%endrep

t06_prog:
%rep 64
    dw 0x6908
    dw 0x7185
    dw 0xF000
    dw 0xF000
%endrep

t07_prog:
%rep 32
    dw 0x6980
    dw 0x7981
    dw 0x6982
    dw 0x4983
    dw 0xF000
    dw 0xF000
    dw 0x0184
    dw 0xF000
%endrep

t08_prog:
%rep 32
    dw 0x6980
    dw 0x8181
    dw 0xF000
    dw 0xF000
    dw 0xB182
    dw 0xF000
    dw 0xF000
    dw 0xF000
%endrep

t09_prog:
%rep 32
    dw 0xB980
    dw 0xF000
    dw 0xF000
    dw 0xF000
    dw 0xB181
    dw 0xF000
    dw 0xF000
    dw 0xF000
%endrep

t10_prog:
%rep 64
    dw 0xF000
    dw 0xF800
    dw 0xF000
    dw 0xF800
%endrep

t11_prog:
%rep 32
    dw 0x6908
    dw 0x5903
    dw 0x7380
    dw 0xF000
    dw 0xF000
    dw 0xF000
    dw 0xF000
    dw 0xF000
%endrep

; T12 - NOT brute force. Specific PRAM layout for jump test.
;   word 0 .. word 1: setup + jump
;   words 2..31: NOPs (filler)
;   words 32..34: target (X = const, write to DRAM[3], jump back)
;   words 35..255: NOPs (filler)
t12_prog:
    dw 0x6908       ; word 0:  MOV X,(0x108)
    dw 0xE982       ; word 1:  MOV PC,(0x182)  - jump to 0x0420
    times 30 dw 0xF000   ; words 2..31: NOPs (delay slot + filler)
    dw 0x6908       ; word 32: MOV X,(0x108)  - target start
    dw 0x7183       ; word 33: MOV (0x183),X  - DRAM[3] = X
    dw 0xE982       ; word 34: MOV PC,(0x182) - loop back to 0x0420
    times 221 dw 0xF000  ; words 35..255: NOPs

; T13 - DMA word read
;   MOV DMA1,(0x180)  0x3180   ; set control reg
;   NOP
;   MOV DMA0,(0x181)  0x2981   ; set address + TRIGGER DMA
;   NOP NOP                    ; settle
;   MOV (0x182),DMD   0x4182   ; copy DMD to DRAM[2]
;   NOP NOP
t13_prog:
%rep 32
    dw 0x3180
    dw 0xF000
    dw 0x2981
    dw 0xF000
    dw 0xF000
    dw 0x4182
    dw 0xF000
    dw 0xF000
%endrep

; T14 - Conditional bit (C=0 case)
;   MOV X,(0x108)             0x6908   X = 0x80
;   ADD (0x108)               0x8108   AZ = 0x80 + 0x80 = 0x100. C=0 (no carry).
;   MOV X,(0x109)             0x6909   X = 0xFFFF
;   [cond=1] MOV (0x185),X    0x7585   SKIPPED if C=0 (correct behaviour)
;   NOP NOP NOP NOP
t14_prog:
%rep 32
    dw 0x6908
    dw 0x8108
    dw 0x6909
    dw 0x7585
    dw 0xF000
    dw 0xF000
    dw 0xF000
    dw 0xF000
%endrep
