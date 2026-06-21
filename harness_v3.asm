; =====================================================================
; Konix Multi-System: DSP TEST HARNESS v3
;
; Builds on v2. Adds T07-T11 and fixes the test-number rendering bug
; in v2 (was showing 02,04,06,08,10,12 instead of 01,02,...).
;
; Tests in this version:
;   T01 - Constants ROM read
;   T02 - DSP idle preserves DRAM
;   T03 - Unsigned MULT
;   T04 - Signed MULT via DSP MOV MODE
;   T05 - Signed MULT via host MODE write
;   T06 - Kernel writes to DRAM[5] (non-zero offset)
;   T07 - MAC accumulates    (key question: does MAC add to or replace MZ?)
;   T08 - ADD / AZ output    (the ALU output path, separate from MULT)
;   T09 - MOV AZ,(n) round trip   (loading AZ from RAM works)
;   T10 - INTRUDE: host writes DRAM mid-execution (committed by DSP's
;         INTRUDE instruction - kernel MUST execute INTRUDE for it to work)
;   T11 - Index register: MOV IX,(n) + idx-bit-set instruction offsets address
;
; If T07 actual is 0x0190 (=400) instead of 0x01F4 (=500), MAC replaced
; the accumulator instead of adding to it. If 0x01F4, MAC accumulates.
;
; If T10 actual is CAFE (sentinel), INTRUDE didn't commit. Either the
; host write didn't queue or the DSP isn't actually executing INTRUDE.
;
; If T11 actual is CAFE2 (=DRAM[4] sentinel), the index bit was ignored.
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
%define DSP_MODE     0x0296
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

; 16 slots for test results
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

    ; Palette
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

    ; ISR + interrupts
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

    ; Clear screen
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

.spin:
    hlt
    jmp .spin

; =====================================================================
; --- TEST PROCEDURES ---
; =====================================================================

; T01 - Constants ROM
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

; T02 - Idle preserves DRAM
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

; T03 - Unsigned MULT 16*16
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

; T04 - Signed MULT via DSP MOV MODE
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

; T05 - Signed MULT via host MODE write
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

; T06 - Kernel writes to DRAM[5]
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

; ---------------------------------------------------------------------
; T07 - MAC accumulates
; Kernel: MOV X,(0x180); MULT (0x181); MOV X,(0x182); MAC (0x183);
;         NOP NOP; MOV (0x184),MZ0; NOP
; Pre:    DRAM[0]=10, DRAM[1]=10, DRAM[2]=20, DRAM[3]=20, DRAM[4]=sentinel
; Expect: DRAM[4] = 10*10 + 20*20 = 500 = 0x01F4
; ---------------------------------------------------------------------
do_test_07:
    mov word [test_expected + 7*2], 0x01F4
    call dsp_pre_test
    mov word [es:DSP_DRAM + 0*2], 0x000A     ; 10
    mov word [es:DSP_DRAM + 1*2], 0x000A     ; 10
    mov word [es:DSP_DRAM + 2*2], 0x0014     ; 20
    mov word [es:DSP_DRAM + 3*2], 0x0014     ; 20
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

; ---------------------------------------------------------------------
; T08 - ADD / AZ output
; Kernel: MOV X,(0x180); ADD (0x181); NOP NOP; MOV (0x182),AZ; NOP NOP NOP
; Pre:    DRAM[0]=0x1234, DRAM[1]=0x1111, DRAM[2]=sentinel
; Expect: DRAM[2] = 0x2345
; ---------------------------------------------------------------------
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

; ---------------------------------------------------------------------
; T09 - MOV AZ,(n) round trip through AZ
; Kernel: MOV AZ,(0x180); NOP NOP NOP; MOV (0x181),AZ; NOP NOP NOP
; Pre:    DRAM[0]=0xABCD, DRAM[1]=sentinel
; Expect: DRAM[1] = 0xABCD
; ---------------------------------------------------------------------
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

; ---------------------------------------------------------------------
; T10 - INTRUDE: host writes DRAM[10] while DSP runs INTRUDE-bearing kernel
; Kernel: NOP INTRUDE NOP INTRUDE ...   (so intrudes are scattered)
; Pre:    DRAM[10] = SENTINEL2 (=0xCAFE)
; Flow:   pre-load, kick DSP, short wait, host-write 0xBEEF to host
;         addr DSP_DRAM+10*2 = 0x314 (writes get queued + committed by
;         next INTRUDE), longer wait, stop, read.
; Expect: DRAM[10] = 0xBEEF
; ---------------------------------------------------------------------
do_test_10:
    mov word [test_expected + 10*2], 0xBEEF
    call dsp_pre_test
    mov word [es:DSP_DRAM + 10*2], SENTINEL2
    mov si, t10_prog
    call load_pram_cs_si
    call dsp_kick

    ; Brief wait to let DSP run some kernel iterations
    mov cx, 200
.spin1:
    nop
    loop .spin1

    ; Host word write while DSP is running.
    ; ES still = DSP_SEG; the byte-pair write triggers the INTRUDE queue.
    mov word [es:DSP_DRAM + 10*2], 0xBEEF

    ; Longer wait for next INTRUDE to commit the write
    mov cx, 1000
.spin2:
    nop
    loop .spin2

    ; Stop DSP
    mov al, DSP_STOP
    mov byte [es:DSP_STATUS], al

    ; Read DRAM[10]
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

; ---------------------------------------------------------------------
; T11 - Index register: MOV IX,(n) plus index-bit on a write instruction.
; Kernel: MOV X,(0x108); MOV IX,(0x103); MOV (0x180)+IX,X; NOP*5
;         Index bit set on MOV (0x180),X => effective addr = 0x180 + IX
;         IX is loaded from constants[3] = 0x0004, so writes go to DRAM[4].
; Pre:    DRAM[0] = SENTINEL  (would catch a write that ignores IX)
;         DRAM[4] = SENTINEL2 (the slot we expect to be written)
; Expect: DRAM[4] = 0x0080
; ---------------------------------------------------------------------
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

; =====================================================================
; --- DSP / RENDER HELPERS ---
; =====================================================================

dsp_pre_test:
    mov ax, DSP_SEG
    mov es, ax
    mov al, DSP_STOP
    mov byte [es:DSP_STATUS], al
    mov word [es:DSP_MODE], 0x0000
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

; ---------------------------------------------------------------------
; render_test_row (FIXED from v2)
; Bug in v2: BX was doubled before draw_dec2 read AL, so AL was 2x idx.
; Fix: draw the test number FIRST (while AL still holds the raw idx),
; then compute offsets.
; AL = test idx, CX = Y pixel.
; ---------------------------------------------------------------------
render_test_row:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    ; Draw test number (AL untouched, CX = Y)
    mov word [dh_x], 4
    mov [dh_y], cx
    call draw_dec2              ; AL/CX preserved across the call

    ; Now safe to compute offsets - AL still has the test idx
    mov bl, al
    mov bh, 0
    mov si, bx                  ; si = idx for byte-array (test_state)
    add bx, bx                  ; bx = 2*idx for word arrays

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
    dw 0x6908       ; MOV X,(0x108)
    dw 0x7180       ; MOV (0x180),X
    dw 0xF000
    dw 0xF000
%endrep

t02_prog:
%rep 256
    dw 0xF000       ; NOP
%endrep

t03_prog:
%rep 32
    dw 0x6980       ; MOV X,(0x180)
    dw 0x7981       ; MULT (0x181)
    dw 0xF000
    dw 0xF000
    dw 0x0182       ; MOV (0x182),MZ0
    dw 0xF000
    dw 0xF000
    dw 0xF000
%endrep

t04_prog:
%rep 32
    dw 0x5106       ; MOV MODE,(0x106)
    dw 0x6980       ; MOV X,(0x180)
    dw 0x7981       ; MULT (0x181)
    dw 0xF000
    dw 0xF000
    dw 0x0983       ; MOV (0x183),MZ1
    dw 0xF000
    dw 0xF000
%endrep

t05_prog:
%rep 32
    dw 0x6980       ; MOV X,(0x180)
    dw 0x7981       ; MULT (0x181)
    dw 0xF000
    dw 0xF000
    dw 0x0983       ; MOV (0x183),MZ1
    dw 0xF000
    dw 0xF000
    dw 0xF000
%endrep

t06_prog:
%rep 64
    dw 0x6908       ; MOV X,(0x108)
    dw 0x7185       ; MOV (0x185),X
    dw 0xF000
    dw 0xF000
%endrep

; T07 - MAC
;   MOV X,(0x180)    0x6980    X = DRAM[0] = 10
;   MULT (0x181)     0x7981    MZ = 10*10 = 100
;   MOV X,(0x182)    0x6982    X = DRAM[2] = 20
;   MAC (0x183)      0x4983    MZ = 100 + 20*20 = 500
;   NOP NOP
;   MOV (0x184),MZ0  0x0184    DRAM[4] = MZ0 = 500 = 0x01F4
;   NOP
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

; T08 - ADD / AZ
;   MOV X,(0x180)   0x6980
;   ADD (0x181)     0x8181    AZ = X + DRAM[1] = 0x1234 + 0x1111 = 0x2345
;   NOP NOP
;   MOV (0x182),AZ  0xB182
;   NOP NOP NOP
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

; T09 - MOV AZ,(n) then MOV (n),AZ
;   MOV AZ,(0x180)  0xB980    AZ = DRAM[0] = 0xABCD
;   NOP NOP NOP
;   MOV (0x181),AZ  0xB181    DRAM[1] = AZ
;   NOP NOP NOP
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

; T10 - NOPs interleaved with INTRUDEs (so host writes can commit)
;   NOP            0xF000
;   INTRUDE        0xF800
;   NOP            0xF000
;   INTRUDE        0xF800
t10_prog:
%rep 64
    dw 0xF000
    dw 0xF800
    dw 0xF000
    dw 0xF800
%endrep

; T11 - Index register
;   MOV X,(0x108)              0x6908   X = 0x80
;   MOV IX,(0x103)             0x5903   IX = constants[3] = 4
;   MOV (0x180)+IX,X (idx=1)   0x7380   = (0x0E<<11)|(1<<9)|0x180
;                                       writes X to address 0x180+IX = 0x184 = DRAM[4]
;   NOP * 5
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
