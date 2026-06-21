; =====================================================================
; Konix Multi-System: DSP TEST HARNESS v1
;
; Goal: print hex values to screen + run a minimal DSP test (T01).
;
; If you see:
;   Top row : DEAD BEEF  (in white)
;   T01 row : 01  0080  0080  [green block]   = T01 PASS (constants ROM OK)
;             01  0080  DEAD  [magenta block] = sentinel (DSP didn't write)
;             01  0080  xxxx  [red block]     = unexpected value
;   Nothing : display setup wrong (or hung in dsp_ld verify)
;
; Tooling: nasm + make_p88.py from previous sessions, unchanged.
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
%define MODE         0x0C
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
%define DSP_DRAM     0x0300
%define DSP_PRAM     0x0400
%define DSP_STATUS   0x0600
%define DSP_DATA_SEG 0x4130     ; same as 0x4100:0x0300 (DRAM)
%define DSP_STOP     0x00
%define DSP_RUN      0x10

; --- Sentinel ---
%define SENTINEL     0xDEAD

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

; Scratch variables used by draw helpers (avoid juggling registers across calls)
dh_val:    dw 0         ; value to draw (hex16)
dh_x:      dw 0         ; current X for digit being drawn
dh_y:      dw 0         ; Y for digits
dh_base_x: dw 0         ; starting X (for advancing)

; Test result storage: 16 slots (indexed by test number)
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

    ; --- Video init (matches cube3d_brute exactly) ---
    xor ax, ax
    out BORDL, ax
    mov ax, 60
    out STARTL, ax
    mov ax, 259
    out ENDL, ax
    mov al, 1
    out MEM, al
    out MODE, al
    xor al, al
    out PMASK, al
    out INDEX, al
    xor ax, ax
    out SCROLL1, ax
    out SCROLL3, al

    ; --- Palette: writes to seg 0x4000 ---
    mov ax, 0x4000
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 256
.pz:
    stosw
    loop .pz
    mov di, 255*2
    mov ax, 0x0FFF              ; idx 255 = white  (digits)
    stosw
    mov di, 254*2
    mov ax, 0x00F0              ; idx 254 = green  (PASS)
    stosw
    mov di, 253*2
    mov ax, 0x0F00              ; idx 253 = red    (FAIL)
    stosw
    mov di, 252*2
    mov ax, 0x0F0F              ; idx 252 = magenta(sentinel)
    stosw

    ; --- ISR + interrupts (from cube3d_brute) ---
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

    ; --- Clear screen ---
    mov ax, 0x9000
    mov es, ax
    mov ax, clr_prog
    bum_run 0x11
    call blit_wait

    ; =================================================================
    ; SANITY ROW at y=2: draw "DEAD  BEEF" using the digit font.
    ; If this renders correctly we know display + font are working.
    ; =================================================================
    mov ax, 0xDEAD
    mov word [dh_x], 4
    mov word [dh_y], 2
    call draw_hex16

    mov ax, 0xBEEF
    mov word [dh_x], 40         ; small gap after DEAD (24 wide + gap)
    mov word [dh_y], 2
    call draw_hex16

    ; =================================================================
    ; TEST T01: Constants ROM read
    ; PRAM: MOV X,(0x108) ; MOV (0x180),X ; NOP ; NOP   (x64 reps)
    ; =================================================================

    mov word [test_expected + 1*2], 0x0080

    ; Stop DSP
    mov ax, DSP_SEG
    mov es, ax
    mov al, DSP_STOP
    mov byte [es:DSP_STATUS], al

    ; Preload DRAM[0] with sentinel  (word write hits both bytes)
    mov word [es:DSP_DRAM], SENTINEL

    ; Load t01_prog into PRAM (with verify)
    push ds
    push cs
    pop ds
    mov si, t01_prog
    mov di, DSP_PRAM
    mov cx, 256
    call dsp_ld
    pop ds

    ; Kick DSP
    mov al, byte [es:DSP_PRAM]
    mov al, DSP_RUN
    mov byte [es:DSP_STATUS], al

    ; Let it run a while (many passes through PRAM)
    mov cx, 2000
.t01_wait:
    nop
    loop .t01_wait

    ; Stop DSP
    mov al, DSP_STOP
    mov byte [es:DSP_STATUS], al

    ; Read DRAM[0] via DSP_DATA_SEG
    mov ax, DSP_DATA_SEG
    mov es, ax
    mov ax, word [es:0]
    mov [test_actual + 1*2], ax

    ; Classify result
    cmp ax, [test_expected + 1*2]
    je .t01_pass
    cmp ax, SENTINEL
    je .t01_sent
    mov byte [test_state + 1], 2    ; FAIL
    jmp .t01_render
.t01_pass:
    mov byte [test_state + 1], 1    ; PASS
    jmp .t01_render
.t01_sent:
    mov byte [test_state + 1], 3    ; SENTINEL

.t01_render:
    ; Test number "01" at x=4, y=20
    mov al, 1
    mov word [dh_x], 4
    mov word [dh_y], 20
    call draw_dec2
    ; Expected at x=20
    mov ax, [test_expected + 1*2]
    mov word [dh_x], 24
    mov word [dh_y], 20
    call draw_hex16
    ; Actual at x=55
    mov ax, [test_actual + 1*2]
    mov word [dh_x], 60
    mov word [dh_y], 20
    call draw_hex16
    ; Status marker at x=95
    mov al, [test_state + 1]
    mov bx, 95
    mov cx, 20
    call draw_state_marker

.spin:
    hlt
    jmp .spin

; =====================================================================
; --- Helpers ---
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

; ---------------------------------------------------------------------
; dsp_ld - byte-protocol PRAM upload with read-back verify (AOTMC style).
; DS:SI = source, ES:DI = host PRAM destination, CX = word count
; On failure: hangs forever cycling border colour.
; ---------------------------------------------------------------------
dsp_ld:
    lodsw                       ; AX = next program word
    mov byte [es:di], al        ; low byte
    inc di
    mov byte [es:di], ah        ; high byte
    dec di
    mov dl, byte [es:di]        ; read back low
    mov dl, byte [es:di]        ; (paranoid second read, AOTMC pattern)
    inc di
    mov dh, byte [es:di]        ; read back high
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

; ---------------------------------------------------------------------
; draw_hex16 - Draw value in AX as 4 hex digits at [dh_x], [dh_y]
; ---------------------------------------------------------------------
draw_hex16:
    push ax
    push bx
    push cx
    push dx
    mov [dh_val], ax
    ; digit 3 (bits 12..15)
    mov ax, [dh_val]
    mov cl, 12
    shr ax, cl
    and al, 0x0F
    call draw_one_nibble
    add word [dh_x], 6
    ; digit 2 (bits 8..11)
    mov ax, [dh_val]
    mov cl, 8
    shr ax, cl
    and al, 0x0F
    call draw_one_nibble
    add word [dh_x], 6
    ; digit 1 (bits 4..7)
    mov ax, [dh_val]
    mov cl, 4
    shr ax, cl
    and al, 0x0F
    call draw_one_nibble
    add word [dh_x], 6
    ; digit 0 (bits 0..3)
    mov ax, [dh_val]
    and al, 0x0F
    call draw_one_nibble
    add word [dh_x], 6
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ---------------------------------------------------------------------
; draw_dec2 - Draw 2-digit decimal number from AL at [dh_x], [dh_y]
; ---------------------------------------------------------------------
draw_dec2:
    push ax
    push bx
    push cx
    push dx
    xor ah, ah
    mov dl, 10
    div dl                      ; al=tens, ah=units
    mov bl, ah                  ; save units
    ; tens
    xor ah, ah
    call draw_one_nibble        ; tens (digit < 10 so hex_nibble path is fine)
    add word [dh_x], 6
    ; units
    mov al, bl
    xor ah, ah
    call draw_one_nibble
    add word [dh_x], 6
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ---------------------------------------------------------------------
; draw_one_nibble - draw one digit (0..15) from AL at [dh_x], [dh_y]
; This is the core glyph plotter.
; ---------------------------------------------------------------------
draw_one_nibble:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    cld
    ; Look up font pointer
    and ax, 0x000F
    shl ax, 1
    mov si, font_table
    add si, ax
    mov si, [si]                ; si -> 35 bytes of glyph data
    ; Compute screen address (seg 0, offset y*256 + x)
    xor ax, ax
    mov es, ax
    mov ax, [dh_y]
    mov ah, al                  ; ah = y (low byte)
    mov al, [dh_x]              ; al = x (low byte)
    mov di, ax                  ; di = y*256 + x
    ; Plot 7 rows of 5 pixels
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

; ---------------------------------------------------------------------
; draw_state_marker - draw 7x7 colour block at (BX,CX)
; AL: 1=PASS (green), 2=FAIL (red), 3=sentinel (magenta), else white
; ---------------------------------------------------------------------
draw_state_marker:
    push ax
    push bx
    push cx
    push dx
    push di
    push es
    ; pick colour index
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
    mov ah, cl                  ; y
    mov al, bl                  ; x
    mov di, ax
    mov cx, 7                   ; 7 rows
.row:
    push cx
    mov cx, 7                   ; 7 cols
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
; DSP TEST PROGRAMS
; =====================================================================

; T01 PRAM: brute-force pattern, 4 instructions x 64 reps = 256 words
;   MOV X,(0x108)   X = constants[8] = 0x0080
;   MOV (0x180),X   DRAM[0] = X
;   NOP
;   NOP
t01_prog:
%rep 64
    dw 0x6908       ; MOV X,(0x108)
    dw 0x7180       ; MOV (0x180),X
    dw 0xF000       ; NOP
    dw 0xF000       ; NOP
%endrep
