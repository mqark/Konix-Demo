; =====================================================================
; Konix Multi-System: DSP TEST HARNESS v2
;
; Adds tests T02-T06 to the v1 foundation. Each test renders one row
; of [test#] [expected] [actual] [status block] on the screen.
;
; Tests in this version:
;   T01 - Constants ROM read         (proven in v1)
;   T02 - DSP idle preserves DRAM    (NOP-only kernel, sentinel test)
;   T03 - Unsigned MULT (16*16=256)  (reads MZ0)
;   T04 - Signed MULT via DSP MOV MODE,(0x106)  (reads MZ1, expects FFFF)
;   T05 - Signed MULT via host MODE write to 0x296  (reads MZ1, expects FFFF)
;   T06 - Kernel writes to DRAM[5]   (tests non-zero DRAM offset)
;
; If T04 says 000F instead of FFFF, MODE=0x20 doesn't mean "signed" -
; that's a finding (not a regression). T05 vs T04 comparison tells us
; whether host MODE write works the same as DSP MOV MODE.
;
; Notes carried over from v1:
;   - cube3d_brute video setup (256-wide medium-res framebuffer at seg 0)
;   - Pixel write trick: AH=Y, AL=X, DI=AX, [es:di]
;   - AOTMC-style dsp_ld with read-back verify
;   - Brute-force PRAM pattern (kernel repeated to fill 256 words)
; =====================================================================
BITS 16
CPU 8086

%define DATA_PAD     0x2000

; --- ASIC ports ---
%define INTL         0x00
%define STARTL       0x02
%define ENDL         0x11
%define SCROLL1      0x08
%define SCROLL3      0x0A
%define ACK          0x0B
%define MODE_PORT    0x0C        ; renamed to avoid clash with DSP MODE
%define BORDL        0x0D
%define PMASK        0x0F
%define INDEX        0x10
%define DIS          0x16
%define MEM          0x13
%define BLPROG0      0x30
%define BLPROG2      0x32
%define BLSTAT       0x26
%define BLCON        0x34

; --- DSP host-side addresses (P89 mapping) ---
%define DSP_SEG      0x4100
%define DSP_DRAM     0x0300     ; offset to DRAM[0] within DSP_SEG
%define DSP_MODE     0x0296     ; offset to MODE register (DSP RAM word 0x14B)
%define DSP_PRAM     0x0400
%define DSP_STATUS   0x0600
%define DSP_DATA_SEG 0x4130     ; same as 0x4100:0x0300 (DRAM)
%define DSP_STOP     0x00
%define DSP_RUN      0x10

%define SENTINEL     0xDEAD     ; for DRAM[0]
%define SENTINEL2    0xCAFE     ; for DRAM[3], DRAM[5] (something distinct)

; -- Blitter run macro --
%macro bum_run 1
    out BLPROG0, ax
    mov al, 0x09
    mov ah, %1
    out BLPROG2, ax
%endmacro

; =====================================================================
; DATA SEGMENT (loads at 0x9000:0000)
; =====================================================================
SECTION data_seg vstart=0 start=0

; Clear screen blitter prog
clr_prog:    db 0,0,0,  0,1,0,  0x22,0xC0,  200,0,0,  0,0

; Scratch variables for draw helpers
dh_val:    dw 0
dh_x:      dw 0
dh_y:      dw 0

; Test result storage (16 slots, indexed by test number)
test_expected: times 16 dw 0
test_actual:   times 16 dw 0
test_state:    times 16 db 0       ; 0=untested, 1=PASS, 2=FAIL, 3=sentinel

; --- 5x7 digit font, pixel value 255 = on, 0 = off ---
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

; =====================================================================
; CODE SEGMENT (loads at 0x8000:0000)
; =====================================================================
SECTION code_seg vstart=0 start=DATA_PAD
start:
    mov ax, 0x9000
    mov ds, ax
    mov ss, ax
    mov sp, 0x0FFF
    cld

    ; --- Video init (cube3d_brute) ---
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

    ; --- Palette ---
    mov ax, 0x4000
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 256
.pz:
    stosw
    loop .pz
    mov di, 255*2
    mov ax, 0x0FFF              ; 255 = white (digits)
    stosw
    mov di, 254*2
    mov ax, 0x00F0              ; 254 = green (PASS)
    stosw
    mov di, 253*2
    mov ax, 0x0F00              ; 253 = red (FAIL)
    stosw
    mov di, 252*2
    mov ax, 0x0F0F              ; 252 = magenta (sentinel survived)
    stosw

    ; --- ISR + interrupts ---
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

    ; --- Clear screen via blitter ---
    mov ax, 0x9000
    mov es, ax
    mov ax, clr_prog
    bum_run 0x11
    call blit_wait

    ; -----------------------------------------------------------------
    ; SANITY ROW at y=2 - DEAD BEEF
    ; -----------------------------------------------------------------
    mov ax, 0xDEAD
    mov word [dh_x], 4
    mov word [dh_y], 2
    call draw_hex16
    mov ax, 0xBEEF
    mov word [dh_x], 40
    mov word [dh_y], 2
    call draw_hex16

    ; -----------------------------------------------------------------
    ; Run all tests
    ; -----------------------------------------------------------------
    call do_test_01
    call do_test_02
    call do_test_03
    call do_test_04
    call do_test_05
    call do_test_06

.spin:
    hlt
    jmp .spin

; =====================================================================
; --- DSP TEST PROCEDURES ---
; Each does: setup state, load PRAM, run, stop, read, classify, render.
; =====================================================================

; ---------------------------------------------------------------------
; T01 - Constants ROM
; Kernel: MOV X,(0x108) ; MOV (0x180),X ; NOP ; NOP
; Pre:    DRAM[0] = SENTINEL
; Expect: DRAM[0] = 0x0080
; ---------------------------------------------------------------------
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

; ---------------------------------------------------------------------
; T02 - Idle DSP preserves DRAM
; Kernel: all NOPs
; Pre:    DRAM[0] = 0x55AA
; Expect: DRAM[0] = 0x55AA (still)
; ---------------------------------------------------------------------
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
    mov dx, 0x55AA              ; sentinel == expected here; treat as no separate sentinel
    call classify_result
    mov [test_state + 2], al
    mov ax, 2
    mov cx, 30
    call render_test_row
    ret

; ---------------------------------------------------------------------
; T03 - Unsigned MULT (16 * 16 = 256)
; Kernel: MOV X,(0x180); MULT (0x181); NOP NOP; MOV (0x182),MZ0; NOP NOP NOP
; Pre:    DRAM[0]=0x0010, DRAM[1]=0x0010, DRAM[2]=SENTINEL2
; Expect: DRAM[2] = 0x0100 (=256)
; ---------------------------------------------------------------------
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

; ---------------------------------------------------------------------
; T04 - Signed MULT via DSP MOV MODE,(0x106) (MODE=0x0020)
; Kernel: MOV MODE,(0x106); MOV X,(0x180); MULT (0x181); NOP NOP;
;         MOV (0x183),MZ1; NOP NOP
; Pre:    DRAM[0]=0xFFFF, DRAM[1]=0x0010, DRAM[3]=SENTINEL2, MODE=0
; Expect: DRAM[3] = 0xFFFF  (if MODE=0x20 = signed -> -1*16 = -16)
;         (If we see 0x000F instead, MODE=0x20 does not mean signed.)
; ---------------------------------------------------------------------
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

; ---------------------------------------------------------------------
; T05 - Signed MULT via host MODE write to 0x296 (MODE=0x0020)
; Kernel: MOV X,(0x180); MULT (0x181); NOP NOP; MOV (0x183),MZ1; NOP NOP NOP
;         (no MOV MODE inside the kernel)
; Pre:    DRAM[0]=0xFFFF, DRAM[1]=0x0010, DRAM[3]=SENTINEL2,
;         MODE=0x0020 (host write)
; Expect: DRAM[3] = 0xFFFF
; ---------------------------------------------------------------------
do_test_05:
    mov word [test_expected + 5*2], 0xFFFF
    call dsp_pre_test
    mov word [es:DSP_DRAM + 0*2], 0xFFFF
    mov word [es:DSP_DRAM + 1*2], 0x0010
    mov word [es:DSP_DRAM + 3*2], SENTINEL2
    ; Host-set MODE = 0x0020 AFTER dsp_pre_test (which resets it to 0)
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

; ---------------------------------------------------------------------
; T06 - Kernel writes to DRAM[5] (non-zero address)
; Kernel: MOV X,(0x108) ; MOV (0x185),X ; NOP ; NOP
; Pre:    DRAM[5] = SENTINEL2 (=0xCAFE so we can tell apart from DEAD)
; Expect: DRAM[5] = 0x0080
; ---------------------------------------------------------------------
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

; =====================================================================
; --- DSP CONTROL HELPERS ---
; =====================================================================

; ---------------------------------------------------------------------
; dsp_pre_test - Stop DSP, set ES=DSP_SEG, reset MODE register to 0.
; After this, [es:offset] writes hit DSP host space directly.
; ---------------------------------------------------------------------
dsp_pre_test:
    mov ax, DSP_SEG
    mov es, ax
    mov al, DSP_STOP
    mov byte [es:DSP_STATUS], al
    mov word [es:DSP_MODE], 0x0000
    ret

; ---------------------------------------------------------------------
; load_pram_cs_si - Load 256 PRAM words from CS:SI with verify.
; SI = source offset in CS, ES must be DSP_SEG already.
; On verify failure: hangs in dsp_ld with cycling border.
; ---------------------------------------------------------------------
load_pram_cs_si:
    push ds
    push cs
    pop ds
    mov di, DSP_PRAM
    mov cx, 256
    call dsp_ld
    pop ds
    ret

; ---------------------------------------------------------------------
; dsp_kick - Dummy PRAM read, then write DSP_RUN to status.
; ES must be DSP_SEG.
; ---------------------------------------------------------------------
dsp_kick:
    mov al, byte [es:DSP_PRAM]
    mov al, DSP_RUN
    mov byte [es:DSP_STATUS], al
    ret

; ---------------------------------------------------------------------
; dsp_wait_stop - Wait CX*5 NOPs, then write DSP_STOP to status.
; ES must be DSP_SEG. CX = loop count (use 2000 by default).
; ---------------------------------------------------------------------
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

; ---------------------------------------------------------------------
; classify_result - Compare AX (actual) against BX (expected) and DX (sentinel).
; Returns AL: 1=PASS, 2=FAIL, 3=sentinel
; ---------------------------------------------------------------------
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

; ---------------------------------------------------------------------
; render_test_row - Render one full test row.
; AL = test number (0..15), CX = Y pixel position
; Reads test_expected[al], test_actual[al], test_state[al]
; ---------------------------------------------------------------------
render_test_row:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov bl, al
    mov bh, 0
    mov si, bx                  ; si = test index for byte arrays
    add bx, bx                  ; bx = 2*idx for word arrays

    ; Test number "NN" at x=4
    mov word [dh_x], 4
    mov [dh_y], cx
    mov al, bl                  ; al = test index
    call draw_dec2

    ; Expected at x=24
    mov ax, [test_expected + bx]
    mov word [dh_x], 24
    mov [dh_y], cx
    call draw_hex16

    ; Actual at x=60
    mov ax, [test_actual + bx]
    mov word [dh_x], 60
    mov [dh_y], cx
    call draw_hex16

    ; State marker at x=95
    mov al, [test_state + si]
    mov bx, 95
    ; cx already holds Y
    call draw_state_marker

    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =====================================================================
; --- DRAW HELPERS (unchanged from v1 except minor cleanup) ---
; =====================================================================

blit_wait:
.bw:
    in al, BLSTAT
    test al, al
    jnz .bw
    ret

vblank_isr:
    out ACK, al
    iret

; dsp_ld - byte-protocol PRAM upload with read-back verify (AOTMC style).
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
    mov bl, ah                  ; save units
    xor ah, ah
    call draw_one_nibble        ; tens
    add word [dh_x], 6
    mov al, bl
    xor ah, ah
    call draw_one_nibble        ; units
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
; Each fills 256 PRAM words via brute-force repetition so it doesn't
; matter where PC starts after the kick.
; =====================================================================

; T01: MOV X,(0x108) ; MOV (0x180),X ; NOP ; NOP    (x64)
t01_prog:
%rep 64
    dw 0x6908       ; MOV X,(0x108)
    dw 0x7180       ; MOV (0x180),X
    dw 0xF000       ; NOP
    dw 0xF000       ; NOP
%endrep

; T02: NOP ... NOP    (x256)  - DSP idle
t02_prog:
%rep 256
    dw 0xF000       ; NOP
%endrep

; T03: MOV X,(0x180); MULT (0x181); NOP NOP; MOV (0x182),MZ0; NOP NOP NOP  (x32)
;       0x6980        0x7981        0xF000 x2  0x0182          0xF000 x3
t03_prog:
%rep 32
    dw 0x6980       ; MOV X,(0x180)      - X = DRAM[0]
    dw 0x7981       ; MULT (0x181)       - X * DRAM[1]
    dw 0xF000       ; NOP
    dw 0xF000       ; NOP
    dw 0x0182       ; MOV (0x182),MZ0    - DRAM[2] = MZ0
    dw 0xF000       ; NOP
    dw 0xF000       ; NOP
    dw 0xF000       ; NOP
%endrep

; T04: MOV MODE,(0x106); MOV X,(0x180); MULT (0x181); NOP NOP;
;      MOV (0x183),MZ1; NOP NOP NOP  (x32)
;       0x5106         0x6980          0x7981        0xF000 x2
;       0x0983          0xF000 x3
;
; MOV MODE,(nn) opcode 0x0A -> (0x0A<<11)|0x106 = 0x5106
; MOV (nn),MZ1  opcode 0x01 -> (0x01<<11)|0x183 = 0x0983
t04_prog:
%rep 32
    dw 0x5106       ; MOV MODE,(0x106)   - MODE = constants[6] = 0x0020
    dw 0x6980       ; MOV X,(0x180)
    dw 0x7981       ; MULT (0x181)
    dw 0xF000       ; NOP
    dw 0xF000       ; NOP
    dw 0x0983       ; MOV (0x183),MZ1
    dw 0xF000       ; NOP
    dw 0xF000       ; NOP
%endrep

; T05: MOV X,(0x180); MULT (0x181); NOP NOP; MOV (0x183),MZ1; NOP NOP NOP  (x32)
;       (same as T03 but writing MZ1 instead of MZ0, and no MOV MODE)
;       (MODE is host-written before kick)
t05_prog:
%rep 32
    dw 0x6980       ; MOV X,(0x180)
    dw 0x7981       ; MULT (0x181)
    dw 0xF000       ; NOP
    dw 0xF000       ; NOP
    dw 0x0983       ; MOV (0x183),MZ1
    dw 0xF000       ; NOP
    dw 0xF000       ; NOP
    dw 0xF000       ; NOP
%endrep

; T06: MOV X,(0x108); MOV (0x185),X; NOP NOP   (x64)
;       0x6908        0x7185         0xF000 x2
t06_prog:
%rep 64
    dw 0x6908       ; MOV X,(0x108)      - X = constants[8] = 0x0080
    dw 0x7185       ; MOV (0x185),X      - DRAM[5] = X
    dw 0xF000       ; NOP
    dw 0xF000       ; NOP
%endrep
