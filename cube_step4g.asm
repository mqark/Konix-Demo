; =====================================================================
; Konix Multi-System: STEP 4G - Blitter-accelerated scanline fill
;
; In step 4E the CPU was still doing the polygon scanline fill via
; REP STOSB. With backface culling we fill ~3 visible faces, each ~100
; scanlines tall, each scanline ~50-100 bytes wide. That is ~24000
; bytes per frame the CPU writes by hand. That is now the dominant
; per-frame cost.
;
; PREVIOUS STEP 4F BUG (CORRECTED HERE)
;   I had the P88 chained command size and CMD byte position wrong.
;   The correct format per asic.c TickBlitterP88() is:
;
;       byte 0,1,2 : SRC low, mid, FLAGS
;       byte 3,4,5 : DST low, mid, FLAGS (page nibble in low bits of byte 5)
;       byte 6     : MODE
;       byte 7     : CPLG
;       byte 8     : OUTER_CNT
;       byte 9     : INNER_CNT
;       byte 10    : STEP
;       byte 11    : PAT
;       byte 12    : CMD (read AFTER DoBlit; bit 0 = continue, 0 = stop)
;
;   So each command is 13 BYTES, with CMD at byte 12 and NO ENH byte
;   (ENH is an MSU-only thing).  Step 4F used 14 bytes with CMD at
;   byte 13 -> blitter read byte 12 (which I'd set to ENH=0) as the
;   next CMD -> loop exited after FIRST span every time.  That is why
;   the cube rendered wireframe only: only the first 1-pixel span per
;   frame ever got drawn.
;
;   The clear program (clr_prog_a/b) also followed the wrong layout;
;   it kept working because it was a SINGLE command and byte 12 = 0
;   = stop happened to be correct by accident.
;
; Expected: vblanks_per_frame should drop further from 05 down to
; 02-03. Approaching the Flare One demo's perceived speed.
; =====================================================================
;
; DSP DRAM layout (DSP addresses; offsets = 0x180 + word index):
;   [ 0.. 7] X[0..7]        input X coords (Q.0, written once at startup)
;   [ 8..15] Y[0..7]        input Y coords
;   [16..23] Z[0..7]        input Z coords
;   [24..32] m00..m22       3x3 matrix row-major (Q8.8, written per frame)
;   [33..40] X'[0..7]       output (signed; /256 = pixel offset)
;   [41..48] Y'[0..7]
;   [49..56] Z'[0..7]
;   [57]     loop_target    = 216 (self-loop address for kernel's MOV PC)
;
; Cube vertices (model space, half-extent CUBE_SIZE):
;   v0..v3 = front face (z=-CUBE_SIZE)
;   v4..v7 = back  face (z=+CUBE_SIZE)
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

%define CUBE_SIZE    35
%define CENTER_X     128
%define CENTER_Y     120
%define FOCAL        200

; --- DSP ---
%define DSP_SEG      0x4100
%define DSP_DRAM     0x0300
%define DSP_MODE     0x0296
%define DSP_PC       0x0294
%define DSP_PRAM     0x0400
%define DSP_STATUS   0x0600
%define DSP_DATA_SEG 0x4130
%define DSP_STOP     0x00
%define DSP_RUN      0x10

%define CC 0xFF

; ---------------------------------------------------------------------
; bum_run: kick the blitter.
; Inputs:
;   AX = offset (within data segment 0x9000) of the blitter program
;   %1 = command byte (typically 0x11 = start, no loop)
; Wraps OUT BLPROG0,AX (sets BLTPC bits 0-15 from AX) then a single
; OUT BLPROG2,AX with AL=0x09 (BLTPC bits 16-19 = 9, since data seg is
; at physical 0x90000) and AH=%1 (BLTCMD byte, bit 0 triggers).
; ---------------------------------------------------------------------
%macro bum_run 1
    out BLPROG0, ax
    mov al, 0x09
    mov ah, %1
    out BLPROG2, ax
%endmacro

; ---------------------------------------------------------------------
; VTRANSFORM macro: emits 27 DSP instructions to transform vertex i.
; Inputs:  X[i] @ 0x180+i, Y[i] @ 0x188+i, Z[i] @ 0x190+i
;          matrix m00..m22 @ 0x198..0x1A0
; Outputs: X'[i] @ 0x1A1+i, Y'[i] @ 0x1A9+i, Z'[i] @ 0x1B1+i
;
; For each output coord we do MULT then 2x MAC (3 products summed),
; then 2 NOPs, then write MZ0. MULT resets the accumulator; MAC adds.
; ---------------------------------------------------------------------
%macro VTRANSFORM 1
    %assign vi %1
    ; X'[vi] = m00*X[vi] + m01*Y[vi] + m02*Z[vi]
    dw 0x6980 + vi           ; MOV X,(X[vi])
    dw 0x7998                ; MULT (m00)
    dw 0x6988 + vi           ; MOV X,(Y[vi])
    dw 0x4999                ; MAC (m01)
    dw 0x6990 + vi           ; MOV X,(Z[vi])
    dw 0x499A                ; MAC (m02)
    dw 0xF000
    dw 0xF000
    dw 0x01A1 + vi           ; MOV (X'[vi]),MZ0
    ; Y'[vi] = m10*X[vi] + m11*Y[vi] + m12*Z[vi]
    dw 0x6980 + vi
    dw 0x799B                ; MULT (m10)
    dw 0x6988 + vi
    dw 0x499C                ; MAC (m11)
    dw 0x6990 + vi
    dw 0x499D                ; MAC (m12)
    dw 0xF000
    dw 0xF000
    dw 0x01A9 + vi
    ; Z'[vi] = m20*X[vi] + m21*Y[vi] + m22*Z[vi]
    dw 0x6980 + vi
    dw 0x799E                ; MULT (m20)
    dw 0x6988 + vi
    dw 0x499F                ; MAC (m21)
    dw 0x6990 + vi
    dw 0x49A0                ; MAC (m22)
    dw 0xF000
    dw 0xF000
    dw 0x01B1 + vi
%endmacro

; CHECK_EDGE A, B: test if edge from vertex A to vertex B crosses
; scanline [_fq_sy]; if so, update [_fq_xL]/[_fq_xR].
; A and B are immediate vertex indices 0..3 into face_verts.
%macro CHECK_EDGE 2
    ; ya in BX, yb in CX, sy in AX
    mov bx, [face_verts + %1*4 + 2]
    mov cx, [face_verts + %2*4 + 2]
    mov ax, [_fq_sy]
    cmp bx, ax
    jg %%ya_above
    ; ya <= sy: need yb > sy for crossing
    cmp cx, ax
    jle %%no_cross
    jmp %%compute
%%ya_above:
    ; ya > sy: need yb <= sy
    cmp cx, ax
    jg %%no_cross
%%compute:
    ; x_int = xa + (xb - xa) * (sy - ya) / (yb - ya)
    mov ax, [face_verts + %2*4]
    sub ax, [face_verts + %1*4]              ; AX = xb - xa
    mov bx, [_fq_sy]
    sub bx, [face_verts + %1*4 + 2]          ; BX = sy - ya
    imul bx                                  ; DX:AX = signed product
    mov bx, [face_verts + %2*4 + 2]
    sub bx, [face_verts + %1*4 + 2]          ; BX = yb - ya (non-zero)
    idiv bx                                  ; AX = quotient
    add ax, [face_verts + %1*4]              ; AX = xa + (...)
    cmp ax, [_fq_xL]
    jge %%no_xL
    mov [_fq_xL], ax
%%no_xL:
    cmp ax, [_fq_xR]
    jle %%no_xR
    mov [_fq_xR], ax
%%no_xR:
%%no_cross:
%endmacro

; =====================================================================
SECTION data_seg vstart=0 start=0

clr_prog:    db 0,0,0,  0,1,0,  0x22,0xC0,  200,0,0,  0,0

dh_val: dw 0
dh_x:   dw 0
dh_y:   dw 0

; --- font (hex digits 0..F, from harness) ---
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

; --- cube model coords ---
; v0,v1,v2,v3 = front face (z=-45) running CCW from top-left
; v4,v5,v6,v7 = back  face (z=+45), same XY pattern
cube_mx: dw -CUBE_SIZE,  CUBE_SIZE,  CUBE_SIZE, -CUBE_SIZE, -CUBE_SIZE,  CUBE_SIZE,  CUBE_SIZE, -CUBE_SIZE
cube_my: dw -CUBE_SIZE, -CUBE_SIZE,  CUBE_SIZE,  CUBE_SIZE, -CUBE_SIZE, -CUBE_SIZE,  CUBE_SIZE,  CUBE_SIZE
cube_mz: dw -CUBE_SIZE, -CUBE_SIZE, -CUBE_SIZE, -CUBE_SIZE,  CUBE_SIZE,  CUBE_SIZE,  CUBE_SIZE,  CUBE_SIZE

; --- projected screen coords ---
screen_x: times 8 dw 0
screen_y: times 8 dw 0

; --- edge list: 12 edges, each is two vertex indices ---
edges:
    db 0,1, 1,2, 2,3, 3,0      ; front face
    db 4,5, 5,6, 6,7, 7,4      ; back face
    db 0,4, 1,5, 2,6, 3,7      ; connectors

; --- face data: 6 faces, 4 vertex indices each (winding doesn't matter
;     for painter's algorithm; we just need 4 consistent vertices) ---
face_idx:
    db 0, 1, 2, 3      ; 0 front (z=-)
    db 4, 5, 6, 7      ; 1 back  (z=+)
    db 0, 3, 7, 4      ; 2 left  (x=-)
    db 1, 5, 6, 2      ; 3 right (x=+)
    db 0, 4, 5, 1      ; 4 top   (y=-)
    db 2, 3, 7, 6      ; 5 bot   (y=+)

; palette indices for each face
face_color: db 1, 2, 3, 4, 5, 6

; per-frame visibility flag for each of 6 faces (1 = front-facing, 0 = back)
face_visible: times 6 db 0

; sort order: face indices to paint (back to front)
face_order: db 0, 1, 2, 3, 4, 5

; depth value per face (sum of 4 vertex Zs in MODEL space, used for sort)
face_depth: times 6 dw 0

; --- rotation state ---
frame_count: dw 0
angle_y:     dw 0
angle_x:     dw 0

; --- page-flipping state ---
; draw_seg = segment we are currently drawing into (the BACK page).
; scroll3_val = current value written to SCROLL3 (selects displayed page).
; They are toggled in lock-step after each frame.
draw_seg:    dw 0x1000      ; start by drawing to page B (display shows A)
scroll3_val: db 0           ; display currently shows page A (SCROLL high byte 0)

; --- blitter clear programs (P88 format; see header comment) ---
;
; P88 blitter command layout (13 bytes - see asic.c TickBlitterP88):
;   bytes [0,1,2] : SRC low/mid/FLAGS
;   bytes [3,4,5] : DST low/mid/FLAGS
;   byte  [6]     : MODE
;   byte  [7]     : CPLG
;   byte  [8]     : OUTER_CNT
;   byte  [9]     : INNER_CNT
;   byte  [10]    : STEP
;   byte  [11]    : PAT
;   byte  [12]    : CMD (post-DoBlit; bit 0 set = continue, 0 = stop)

; clr_prog_a: clear page A from offset 0x400 onward.  CMD = 0 at byte 12.
clr_prog_a: db 0,0,0,  0,4,0,  0x22,0xC0,  196,0,0, 0,  0

; clr_prog_b: clear page B (physical 0x10000) entirely.  CMD = 0 at byte 12.
clr_prog_b: db 0,0,0,  0,0,1,  0x22,0xC0,  200,0,0, 0,  0

; --- chained blitter command list ---
; Up to MAX_SPANS span-fill commands (13 bytes each), kicked once per frame.
; The last command's byte 12 is patched to 0 so the blitter stops.
;
; MAX_SPANS sizing:
;   3 visible faces x ~100 scanlines = 300 worst case (cube fills less
;   than half-screen height after perspective). 13 bytes per command.
%define MAX_SPANS 400
%define CMD_SZ    13
blit_list: times (MAX_SPANS * CMD_SZ) db 0
blit_ptr:  dw 0         ; next write position within blit_list

cosY: dw 0
sinY: dw 0
cosX: dw 0
sinX: dw 0

; rotation matrix elements (Q8.8 signed): m00..m22 row-major
mat: times 9 dw 0

; transformed vertex Z values (signed) - used for painter's sort
trans_z: times 8 dw 0

; --- DSP-computed transform results (read back from DSP DRAM each frame) ---
; These are signed Q8.8 values direct from DSP MZ0; the screen coord is
; (DSP_result / 256) + CENTER.
dsp_tx: times 8 dw 0
dsp_ty: times 8 dw 0
dsp_tz: times 8 dw 0

; --- perspective projection scratch ---
_persp_tx:    dw 0
_persp_ty:    dw 0
_persp_tz:    dw 0
_persp_denom: dw 0

; --- vblank-based frame-rate measurement ---
; ISR increments vblank_count on every vblank. Main loop computes the
; delta since last iteration as "vblanks_per_frame": 1 = ~50Hz, 2 = ~25Hz.
vblank_count:      dw 0
last_loop_vblank:  dw 0
vblanks_per_frame: dw 0

; --- sine table: 256 entries, sin(i/256 * 2*pi) * 256 (signed Q8.8) ---
; cos(i) = sine_table[(i + 64) & 0xFF]
sine_table:
    dw      0,      6,     13,     19,     25,     31,     38,     44
    dw     50,     56,     62,     68,     74,     80,     86,     92
    dw     98,    104,    109,    115,    121,    126,    132,    137
    dw    142,    147,    152,    157,    162,    167,    172,    177
    dw    181,    185,    190,    194,    198,    202,    206,    209
    dw    213,    216,    220,    223,    226,    229,    231,    234
    dw    237,    239,    241,    243,    245,    247,    248,    250
    dw    251,    252,    253,    254,    255,    255,    256,    256
    dw    256,    256,    256,    255,    255,    254,    253,    252
    dw    251,    250,    248,    247,    245,    243,    241,    239
    dw    237,    234,    231,    229,    226,    223,    220,    216
    dw    213,    209,    206,    202,    198,    194,    190,    185
    dw    181,    177,    172,    167,    162,    157,    152,    147
    dw    142,    137,    132,    126,    121,    115,    109,    104
    dw     98,     92,     86,     80,     74,     68,     62,     56
    dw     50,     44,     38,     31,     25,     19,     13,      6
    dw      0,     -6,    -13,    -19,    -25,    -31,    -38,    -44
    dw    -50,    -56,    -62,    -68,    -74,    -80,    -86,    -92
    dw    -98,   -104,   -109,   -115,   -121,   -126,   -132,   -137
    dw   -142,   -147,   -152,   -157,   -162,   -167,   -172,   -177
    dw   -181,   -185,   -190,   -194,   -198,   -202,   -206,   -209
    dw   -213,   -216,   -220,   -223,   -226,   -229,   -231,   -234
    dw   -237,   -239,   -241,   -243,   -245,   -247,   -248,   -250
    dw   -251,   -252,   -253,   -254,   -255,   -255,   -256,   -256
    dw   -256,   -256,   -256,   -255,   -255,   -254,   -253,   -252
    dw   -251,   -250,   -248,   -247,   -245,   -243,   -241,   -239
    dw   -237,   -234,   -231,   -229,   -226,   -223,   -220,   -216
    dw   -213,   -209,   -206,   -202,   -198,   -194,   -190,   -185
    dw   -181,   -177,   -172,   -167,   -162,   -157,   -152,   -147
    dw   -142,   -137,   -132,   -126,   -121,   -115,   -109,   -104
    dw    -98,    -92,    -86,    -80,    -74,    -68,    -62,    -56
    dw    -50,    -44,    -38,    -31,    -25,    -19,    -13,     -6

; --- polygon fill workspace ---
; face_verts is 4 (x, y) pairs that fill_quad operates on
face_verts: times 8 dw 0
_fq_color: dw 0
_fq_ymin:  dw 0
_fq_ymax:  dw 0
_fq_xL:    dw 0
_fq_xR:    dw 0
_fq_sy:    dw 0

; --- bresenham state ---
lx0: dw 0
ly0: dw 0
lx1: dw 0
ly1: dw 0
ldx: dw 0
ldy: dw 0
lsx: dw 0
lsy: dw 0
lerr: dw 0
le2:  dw 0
lcol: db 0

; =====================================================================
SECTION code_seg vstart=0 start=DATA_PAD
start:
    mov ax, 0x9000
    mov ds, ax
    mov ss, ax
    mov sp, 0x0FFF
    cld

    ; --- video setup (same as harness) ---
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

    ; --- palette ---
    mov ax, 0x4000
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 256
.pz: stosw
    loop .pz
    ; palette entries 1..6 for faces
    mov di, 1*2
    mov ax, 0x0F00      ; 1 = red
    stosw
    mov ax, 0x0F60      ; 2 = orange
    stosw
    mov ax, 0x0FF0      ; 3 = yellow
    stosw
    mov ax, 0x00F0      ; 4 = green
    stosw
    mov ax, 0x000F      ; 5 = blue
    stosw
    mov ax, 0x0F0F      ; 6 = magenta
    stosw
    ; entry 255 = white (used for wireframe lines AND debug text)
    mov di, 255*2
    mov ax, 0x0FFF
    stosw

    ; --- clear page A (segment 0) BEFORE ISR setup ---
    ; Segment 0 contains BOTH the IVT (offsets 0..0x3FF) and page A's
    ; framebuffer (offsets 0x400+). The clear here covers ALL 51200 bytes
    ; including the IVT region; the ISR vector is then re-installed AFTER.
    xor ax, ax
    mov es, ax
    xor di, di
    mov cx, 256*200/2       ; 25600 words = 51200 bytes
    rep stosw

    ; --- clear page B (segment 0x1000) all the way through ---
    ; No IVT concern here, so we wipe the whole displayable area including
    ; offsets 0..0x3FF (top 4 rows) which our per-frame clear skips.
    mov ax, 0x1000
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 256*200/2
    rep stosw

    ; --- ISR for vblank ---
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

    ; =================================================================
    ; DSP ONE-TIME INIT
    ; =================================================================
    ; 1. Stop DSP, set MODE=0x60 (both signed), reset PC.
    ; 2. Write cube vertex coords to DRAM[0..23] (these never change).
    ; 3. Write self-loop target (216) to DRAM[57] so the kernel can
    ;    MOV PC,(0x1B9) and spin without re-running the transform.
    ; 4. Load the 256-word transform_kernel into PRAM.
    mov ax, DSP_SEG
    mov es, ax
    mov al, DSP_STOP
    mov byte [es:DSP_STATUS], al
    mov word [es:DSP_MODE], 0x0060
    mov word [es:DSP_PC], 0x0000

    ; Copy 8 X coords from cube_mx -> DSP DRAM[0..7]
    mov si, cube_mx
    mov di, DSP_DRAM + 0*2
    mov cx, 8
    rep movsw
    ; Y coords
    mov si, cube_my
    mov di, DSP_DRAM + 8*2
    mov cx, 8
    rep movsw
    ; Z coords
    mov si, cube_mz
    mov di, DSP_DRAM + 16*2
    mov cx, 8
    rep movsw
    ; Restore DS=0x9000 (movsw used DS:SI)
    mov ax, 0x9000
    mov ds, ax

    ; Loop target: PRAM word index of the MOV PC,(self) instruction = 216
    mov word [es:DSP_DRAM + 57*2], 216

    ; Load PRAM kernel (cs:transform_kernel -> DSP PRAM)
    push ds
    push cs
    pop ds
    mov si, transform_kernel
    mov di, DSP_PRAM
    mov cx, 256
    call dsp_ld
    pop ds

    ; =================================================================
    ; MAIN LOOP
    ; =================================================================
main_loop:
    ; --- compute vblanks-per-frame for FPS display ---
    ; vblank_count is incremented by the ISR. Subtract last iteration's
    ; snapshot to get how many vblanks elapsed during the prior frame.
    mov ax, [vblank_count]
    sub ax, [last_loop_vblank]
    mov [vblanks_per_frame], ax
    mov ax, [vblank_count]
    mov [last_loop_vblank], ax

    ; --- bump angles & frame counter ---
    inc word [frame_count]
    mov ax, [angle_y]
    add ax, 3
    and ax, 0xFF
    mov [angle_y], ax
    mov ax, [angle_x]
    add ax, 2
    and ax, 0xFF
    mov [angle_x], ax

    ; --- look up sinY, cosY, sinX, cosX from sine_table ---
    mov bx, [angle_y]
    shl bx, 1
    mov ax, [sine_table + bx]
    mov [sinY], ax
    mov bx, [angle_y]
    add bx, 64
    and bx, 0xFF
    shl bx, 1
    mov ax, [sine_table + bx]
    mov [cosY], ax

    mov bx, [angle_x]
    shl bx, 1
    mov ax, [sine_table + bx]
    mov [sinX], ax
    mov bx, [angle_x]
    add bx, 64
    and bx, 0xFF
    shl bx, 1
    mov ax, [sine_table + bx]
    mov [cosX], ax

    ; --- compute 3x3 rotation matrix (Q8.8) ---
    ; Rotation: first Y (yaw) then X (pitch), so M = R_x * R_y.
    ;   m00 = cosY               m01 = 0                  m02 = sinY
    ;   m10 = sinX*sinY/256      m11 = cosX               m12 = -sinX*cosY/256
    ;   m20 = -cosX*sinY/256     m21 = sinX               m22 = cosX*cosY/256
    ;
    ; Helper: after imul, DX:AX = signed 32-bit product. To get >>8:
    ;   mov al, ah  ; AL <- AH (mid byte)
    ;   mov ah, dl  ; AH <- DL (next byte)
    ; AX = bits 23..8 of product (arithmetic-right-shift by 8).

    ; m00 = cosY
    mov ax, [cosY]
    mov [mat + 0*2], ax
    ; m01 = 0
    mov word [mat + 1*2], 0
    ; m02 = sinY
    mov ax, [sinY]
    mov [mat + 2*2], ax
    ; m10 = (sinX * sinY) >> 8
    mov ax, [sinX]
    imul word [sinY]
    mov al, ah
    mov ah, dl
    mov [mat + 3*2], ax
    ; m11 = cosX
    mov ax, [cosX]
    mov [mat + 4*2], ax
    ; m12 = -(sinX * cosY) >> 8
    mov ax, [sinX]
    imul word [cosY]
    mov al, ah
    mov ah, dl
    neg ax
    mov [mat + 5*2], ax
    ; m20 = -(cosX * sinY) >> 8
    mov ax, [cosX]
    imul word [sinY]
    mov al, ah
    mov ah, dl
    neg ax
    mov [mat + 6*2], ax
    ; m21 = sinX
    mov ax, [sinX]
    mov [mat + 7*2], ax
    ; m22 = (cosX * cosY) >> 8
    mov ax, [cosX]
    imul word [cosY]
    mov al, ah
    mov ah, dl
    mov [mat + 8*2], ax

    ; --- BACKFACE CULLING: compute per-face visibility ---
    ; For axis-aligned face normals, the rotated normal's Z component
    ; reduces to one matrix element. Face visible (front-facing) when
    ; that signed element has the right sign (see header for the table).
    ; This iteration does it inline with TEST..JS (sign flag).
    ;
    ; The 6 stores below leave face_visible[i] = 1 for the 3 front-facing
    ; faces, 0 for the 3 back-facing ones.
    xor ax, ax
    mov word [face_visible + 0], ax     ; clear faces 0,1 (2 bytes)
    mov word [face_visible + 2], ax     ; clear faces 2,3
    mov word [face_visible + 4], ax     ; clear faces 4,5

    ; faces 0 (front) / 1 (back) -- m22
    mov ax, [mat + 8*2]
    test ax, ax
    js .m22_neg
    mov byte [face_visible + 0], 1      ; m22 > 0 -> face 0 visible
    jmp .m22_done
.m22_neg:
    mov byte [face_visible + 1], 1      ; m22 < 0 -> face 1 visible
.m22_done:

    ; faces 2 (left) / 3 (right) -- m20
    mov ax, [mat + 6*2]
    test ax, ax
    js .m20_neg
    mov byte [face_visible + 2], 1
    jmp .m20_done
.m20_neg:
    mov byte [face_visible + 3], 1
.m20_done:

    ; faces 4 (top) / 5 (bottom) -- m21
    mov ax, [mat + 7*2]
    test ax, ax
    js .m21_neg
    mov byte [face_visible + 4], 1
    jmp .m21_done
.m21_neg:
    mov byte [face_visible + 5], 1
.m21_done:

    ; --- KICK DSP TRANSFORM ---
    ; Send the matrix to DSP DRAM, then kick. DSP will produce
    ; transformed vertices in DRAM[33..56] while CPU continues.
    push ds
    mov ax, DSP_SEG
    mov es, ax
    mov al, DSP_STOP
    mov byte [es:DSP_STATUS], al
    mov word [es:DSP_MODE], 0x0060
    mov word [es:DSP_PC], 0x0000
    ; Write 9 matrix coeffs to DRAM[24..32]
    mov si, mat
    mov di, DSP_DRAM + 24*2
    mov cx, 9
    rep movsw
    pop ds
    ; Dummy read + kick (AOTMC pattern)
    mov al, byte [es:DSP_PRAM]
    mov al, DSP_RUN
    mov byte [es:DSP_STATUS], al

    ; --- screen clear via BLITTER (separately, like step 4D) ---
    mov ax, 0x9000
    mov es, ax
    cmp word [draw_seg], 0
    je .clear_page_a_4f
    mov ax, clr_prog_b
    jmp .do_clear_4f
.clear_page_a_4f:
    mov ax, clr_prog_a
.do_clear_4f:
    bum_run 0x11
.wait_clear_4f:
    in al, BLSTAT
    test al, al
    jnz .wait_clear_4f

    ; --- Reset blit_list / blit_ptr for spans-only ---
    ; The list now contains ONLY span commands, no clear at the head.
    ; This isolates "do my spans work?" from "does my chain work?".
    mov word [blit_ptr], blit_list

    ; --- stop DSP, read transformed vertices into dsp_tx/ty/tz ---
    push ds
    mov ax, DSP_SEG
    mov es, ax
    mov al, DSP_STOP
    mov byte [es:DSP_STATUS], al
    mov ax, DSP_DATA_SEG
    mov ds, ax
    mov si, 33*2
    mov ax, 0x9000
    mov es, ax
    mov di, dsp_tx
    mov cx, 8
    rep movsw
    mov si, 41*2
    mov di, dsp_ty
    mov cx, 8
    rep movsw
    mov si, 49*2
    mov di, dsp_tz
    mov cx, 8
    rep movsw
    pop ds

    ; --- project DSP outputs to screen WITH PERSPECTIVE ---
    ; For each vertex:
    ;   tx_q0 = (dsp_tx >> 8)  [signed, ~ -60..60]
    ;   ty_q0 = (dsp_ty >> 8)
    ;   tz_q0 = (dsp_tz >> 8)
    ;   denom = FOCAL + tz_q0       (always positive: FOCAL >> max |tz|)
    ;   screen_x = (FOCAL * tx_q0) / denom + CENTER_X
    ;   screen_y = (FOCAL * ty_q0) / denom + CENTER_Y
    ; trans_z uses Q.0 too so face_depth (sum of 4) cannot overflow int16.
    xor si, si
    mov cx, 8
.proj_loop:
    push cx
    ; tx_q0
    mov ax, [dsp_tx + si]
    mov al, ah
    cbw
    mov [_persp_tx], ax
    ; ty_q0
    mov ax, [dsp_ty + si]
    mov al, ah
    cbw
    mov [_persp_ty], ax
    ; tz_q0 (also depth-sort value)
    mov ax, [dsp_tz + si]
    mov al, ah
    cbw
    mov [_persp_tz], ax
    mov [trans_z + si], ax
    ; denom = FOCAL + tz_q0
    mov ax, FOCAL
    add ax, [_persp_tz]
    mov [_persp_denom], ax
    ; screen_x = FOCAL * tx_q0 / denom + CENTER_X
    mov ax, FOCAL
    imul word [_persp_tx]
    idiv word [_persp_denom]
    add ax, CENTER_X
    mov [screen_x + si], ax
    ; screen_y = FOCAL * ty_q0 / denom + CENTER_Y
    mov ax, FOCAL
    imul word [_persp_ty]
    idiv word [_persp_denom]
    add ax, CENTER_Y
    mov [screen_y + si], ax
    add si, 2
    pop cx
    loop .proj_loop

    ; --- fill faces in arbitrary order, skip back-facing ---
    ; With backface culling there are at most 3 visible faces. On a
    ; convex cube no two visible faces overlap on screen, so the order
    ; in which we draw them doesn't matter. We can skip the depth
    ; computation AND the painter's sort entirely.
    xor si, si              ; si = face index 0..5
.fill_loop:
    ; visibility check first; cheapest possible reject
    mov bx, si
    cmp byte [face_visible + bx], 0
    je .fill_skip
    ; load 4 vertex (sx, sy) pairs into face_verts
    mov ax, si
    shl ax, 1
    shl ax, 1               ; AX = si * 4 (face_idx is 4 bytes per face)
    mov bx, face_idx
    add bx, ax              ; BX = &face_idx[si][0]
    push si
    mov si, bx
    ; v0
    xor bh, bh
    mov bl, [si + 0]
    add bx, bx
    mov ax, [screen_x + bx]
    mov [face_verts + 0], ax
    mov ax, [screen_y + bx]
    mov [face_verts + 2], ax
    ; v1
    xor bh, bh
    mov bl, [si + 1]
    add bx, bx
    mov ax, [screen_x + bx]
    mov [face_verts + 4], ax
    mov ax, [screen_y + bx]
    mov [face_verts + 6], ax
    ; v2
    xor bh, bh
    mov bl, [si + 2]
    add bx, bx
    mov ax, [screen_x + bx]
    mov [face_verts + 8], ax
    mov ax, [screen_y + bx]
    mov [face_verts + 10], ax
    ; v3
    xor bh, bh
    mov bl, [si + 3]
    add bx, bx
    mov ax, [screen_x + bx]
    mov [face_verts + 12], ax
    mov ax, [screen_y + bx]
    mov [face_verts + 14], ax
    pop si
    ; colour for THIS face index
    mov bx, si
    mov al, [face_color + bx]
    call fill_quad
.fill_skip:
    inc si
    cmp si, 6
    jl .fill_loop

    ; --- patch last command CMD = 0 and kick blitter (only if spans) ---
    mov ax, [blit_ptr]
    cmp ax, blit_list
    je .no_spans                ; nothing emitted, skip kick
    mov di, ax
    sub di, CMD_SZ              ; di = start of last command
    mov byte [di + 12], 0       ; CMD = 0 -> stop after this command

    mov ax, 0x9000
    mov es, ax
    mov ax, blit_list
    bum_run 0x11
.wait_blitlist:
    in al, BLSTAT
    test al, al
    jnz .wait_blitlist
.no_spans:

    ; --- draw 12 edges ---
    mov word [lcol], 0xFF       ; palette index 255 (white)
    mov si, edges
    mov cx, 12
.edge_loop:
    push cx
    push si
    ; first vertex index
    xor bh, bh
    mov bl, [si]
    add bx, bx                  ; bx = vidx * 2
    mov ax, [screen_x + bx]
    mov [lx0], ax
    mov ax, [screen_y + bx]
    mov [ly0], ax
    ; second vertex index
    mov bl, [si + 1]
    xor bh, bh
    add bx, bx
    mov ax, [screen_x + bx]
    mov [lx1], ax
    mov ax, [screen_y + bx]
    mov [ly1], ax
    call line
    pop si
    add si, 2
    pop cx
    loop .edge_loop

    ; --- draw debug overlay: 8 vertices as XY hex8 pairs ---
    ; Row 1 (y=4):  v0  v1  v2  v3
    ; Row 2 (y=14): v4  v5  v6  v7
    ; Each entry: X (2 hex digits), space (6 px), Y (2 hex digits)
    ; Per vertex slot is 30 px wide; 4 per row in 256 wide screen.

    ; Vertex 0
    mov ax, [screen_x + 0*2]
    mov word [dh_x], 4
    mov word [dh_y], 4
    call draw_hex8
    mov ax, [screen_y + 0*2]
    mov word [dh_x], 20
    mov word [dh_y], 4
    call draw_hex8

    ; Vertex 1
    mov ax, [screen_x + 1*2]
    mov word [dh_x], 40
    mov word [dh_y], 4
    call draw_hex8
    mov ax, [screen_y + 1*2]
    mov word [dh_x], 56
    mov word [dh_y], 4
    call draw_hex8

    ; Vertex 2
    mov ax, [screen_x + 2*2]
    mov word [dh_x], 76
    mov word [dh_y], 4
    call draw_hex8
    mov ax, [screen_y + 2*2]
    mov word [dh_x], 92
    mov word [dh_y], 4
    call draw_hex8

    ; Vertex 3
    mov ax, [screen_x + 3*2]
    mov word [dh_x], 112
    mov word [dh_y], 4
    call draw_hex8
    mov ax, [screen_y + 3*2]
    mov word [dh_x], 128
    mov word [dh_y], 4
    call draw_hex8

    ; Vertex 4
    mov ax, [screen_x + 4*2]
    mov word [dh_x], 4
    mov word [dh_y], 14
    call draw_hex8
    mov ax, [screen_y + 4*2]
    mov word [dh_x], 20
    mov word [dh_y], 14
    call draw_hex8

    ; Vertex 5
    mov ax, [screen_x + 5*2]
    mov word [dh_x], 40
    mov word [dh_y], 14
    call draw_hex8
    mov ax, [screen_y + 5*2]
    mov word [dh_x], 56
    mov word [dh_y], 14
    call draw_hex8

    ; Vertex 6
    mov ax, [screen_x + 6*2]
    mov word [dh_x], 76
    mov word [dh_y], 14
    call draw_hex8
    mov ax, [screen_y + 6*2]
    mov word [dh_x], 92
    mov word [dh_y], 14
    call draw_hex8

    ; Vertex 7
    mov ax, [screen_x + 7*2]
    mov word [dh_x], 112
    mov word [dh_y], 14
    call draw_hex8
    mov ax, [screen_y + 7*2]
    mov word [dh_x], 128
    mov word [dh_y], 14
    call draw_hex8

    ; --- row 3 (y=24): frame counter, angle Y, angle X ---
    mov ax, [frame_count]
    mov word [dh_x], 4
    mov word [dh_y], 24
    call draw_hex16             ; 4 digits

    mov ax, [angle_y]
    mov word [dh_x], 40
    mov word [dh_y], 24
    call draw_hex8              ; 2 digits

    mov ax, [angle_x]
    mov word [dh_x], 64
    mov word [dh_y], 24
    call draw_hex8              ; 2 digits

    ; vblanks per frame: 01 = 50Hz, 02 = 25Hz, 0A = 5Hz, etc.
    mov ax, [vblanks_per_frame]
    mov word [dh_x], 88
    mov word [dh_y], 24
    call draw_hex8

    ; --- debug row 4 (y=34): DSP-computed v0 raw Q8.8 values ---
    ; tx, ty, tz of vertex 0 from the DSP, in their native Q8.8 form.
    ; Useful for sanity-checking the DSP is still computing.
    mov ax, [dsp_tx + 0*2]
    mov word [dh_x], 4
    mov word [dh_y], 34
    call draw_hex16
    mov ax, [dsp_ty + 0*2]
    mov word [dh_x], 40
    mov word [dh_y], 34
    call draw_hex16
    mov ax, [dsp_tz + 0*2]
    mov word [dh_x], 76
    mov word [dh_y], 34
    call draw_hex16

    ; --- row 5 (y=44): first emitted span bytes [0..7] for debug ---
    ; Format: 00 11 22 33  44 55 66 77   (each is a hex8 of one byte)
    mov al, [blit_list + 0]
    xor ah, ah
    mov word [dh_x], 4
    mov word [dh_y], 44
    call draw_hex8
    mov al, [blit_list + 1]
    xor ah, ah
    mov word [dh_x], 16
    mov word [dh_y], 44
    call draw_hex8
    mov al, [blit_list + 2]
    xor ah, ah
    mov word [dh_x], 28
    mov word [dh_y], 44
    call draw_hex8
    mov al, [blit_list + 3]
    xor ah, ah
    mov word [dh_x], 40
    mov word [dh_y], 44
    call draw_hex8
    mov al, [blit_list + 4]
    xor ah, ah
    mov word [dh_x], 56
    mov word [dh_y], 44
    call draw_hex8
    mov al, [blit_list + 5]
    xor ah, ah
    mov word [dh_x], 68
    mov word [dh_y], 44
    call draw_hex8
    mov al, [blit_list + 6]
    xor ah, ah
    mov word [dh_x], 80
    mov word [dh_y], 44
    call draw_hex8
    mov al, [blit_list + 7]
    xor ah, ah
    mov word [dh_x], 92
    mov word [dh_y], 44
    call draw_hex8

    ; --- row 6 (y=54): first emitted span bytes [8..13] for debug ---
    mov al, [blit_list + 8]
    xor ah, ah
    mov word [dh_x], 4
    mov word [dh_y], 54
    call draw_hex8
    mov al, [blit_list + 9]
    xor ah, ah
    mov word [dh_x], 16
    mov word [dh_y], 54
    call draw_hex8
    mov al, [blit_list + 10]
    xor ah, ah
    mov word [dh_x], 28
    mov word [dh_y], 54
    call draw_hex8
    mov al, [blit_list + 11]
    xor ah, ah
    mov word [dh_x], 40
    mov word [dh_y], 54
    call draw_hex8
    mov al, [blit_list + 12]
    xor ah, ah
    mov word [dh_x], 56
    mov word [dh_y], 54
    call draw_hex8
    mov al, [blit_list + 13]
    xor ah, ah
    mov word [dh_x], 68
    mov word [dh_y], 54
    call draw_hex8

    ; --- row 7 (y=64): span count and the 30th span's bytes ---
    ; span_count = (blit_ptr - blit_list) / 13
    mov ax, [blit_ptr]
    sub ax, blit_list
    xor dx, dx
    mov bx, CMD_SZ
    div bx                      ; AX = span_count
    mov word [dh_x], 4
    mov word [dh_y], 64
    call draw_hex16
    ; show byte 3 (xL), byte 4 (sy), byte 9 (width), byte 11 (colour)
    ; of the 30th span (offset 30 * CMD_SZ = 30 * 13 = 390)
    mov al, [blit_list + 30*CMD_SZ + 3]
    xor ah, ah
    mov word [dh_x], 40
    mov word [dh_y], 64
    call draw_hex8
    mov al, [blit_list + 30*CMD_SZ + 4]
    xor ah, ah
    mov word [dh_x], 56
    mov word [dh_y], 64
    call draw_hex8
    mov al, [blit_list + 30*CMD_SZ + 9]
    xor ah, ah
    mov word [dh_x], 72
    mov word [dh_y], 64
    call draw_hex8
    mov al, [blit_list + 30*CMD_SZ + 11]
    xor ah, ah
    mov word [dh_x], 88
    mov word [dh_y], 64
    call draw_hex8

    ; --- version banner: bottom-right, "4G-V1" via a small marker ---
    ; A 2x2 white block at (252, 196) confirms "step 4G code is running",
    ; distinct from previous 4F builds that had no such block.
    mov es, [draw_seg]
    mov di, 196*256 + 252
    mov byte [es:di], 255
    mov byte [es:di+1], 255
    mov byte [es:di+2], 255
    mov byte [es:di+256], 255
    mov byte [es:di+257], 255
    mov byte [es:di+258], 255

    ; --- wait for vblank, then atomically swap pages ---
    hlt

    ; Flip: write the NEW scroll3 value, then make the old front the new back.
    ; scroll3_val starts at 0 (display = page A); we toggle to 1 then back to 0.
    ; draw_seg starts at 0x1000 (we just finished drawing into page B); after
    ; flip the display reads page B, so we will draw to page A next time.
    xor byte [scroll3_val], 1
    mov al, [scroll3_val]
    out SCROLL3, al

    ; Now swap draw_seg: 0x1000 <-> 0
    mov ax, [draw_seg]
    xor ax, 0x1000
    mov [draw_seg], ax

    jmp main_loop


; =====================================================================
; line: draw line from (lx0,ly0) to (lx1,ly1) with color lcol
;       using Bresenham. Plots into segment 0 (framebuffer).
; =====================================================================
line:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    ; dx = abs(lx1 - lx0); lsx = sign
    mov ax, [lx1]
    sub ax, [lx0]
    mov word [lsx], 1
    jns .dxp
    neg ax
    mov word [lsx], -1
.dxp:
    mov [ldx], ax

    ; dy = -abs(ly1 - ly0); lsy = sign
    mov ax, [ly1]
    sub ax, [ly0]
    mov word [lsy], 1
    jns .dyp
    neg ax
    mov word [lsy], -1
.dyp:
    neg ax
    mov [ldy], ax

    ; err = dx + dy
    mov ax, [ldx]
    add ax, [ldy]
    mov [lerr], ax

    mov es, [draw_seg]      ; draw into current back page

.lp:
    ; plot if in bounds
    mov ax, [lx0]
    cmp ax, 0
    jl .skip
    cmp ax, 255
    jg .skip
    mov bx, [ly0]
    cmp bx, 0
    jl .skip
    cmp bx, 199
    jg .skip
    ; di = ly0*256 + lx0
    mov ah, bl
    mov al, [lx0]
    mov di, ax
    mov al, [lcol]
    mov [es:di], al
.skip:

    ; if (lx0 == lx1 && ly0 == ly1) done
    mov ax, [lx0]
    cmp ax, [lx1]
    jne .nd
    mov ax, [ly0]
    cmp ax, [ly1]
    je .done
.nd:

    ; e2 = 2 * err
    mov ax, [lerr]
    shl ax, 1
    mov [le2], ax

    ; if e2 >= dy: err += dy; lx0 += lsx
    cmp ax, [ldy]
    jl .ny
    mov ax, [ldy]
    add [lerr], ax
    mov ax, [lsx]
    add [lx0], ax
.ny:
    ; if e2 <= dx: err += dx; ly0 += lsy
    mov ax, [le2]
    cmp ax, [ldx]
    jg .ne
    mov ax, [ldx]
    add [lerr], ax
    mov ax, [lsy]
    add [ly0], ax
.ne:
    jmp .lp

.done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret


; =====================================================================
; fill_quad: paint a convex quad with palette index in AL.
; Reads face_verts (4 word pairs x,y). Scanline algorithm: for each y
; in [ymin..ymax], find left/right x crossings of the 4 edges, draw
; horizontal line. Clips to screen.
; =====================================================================
fill_quad:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov ah, 0
    mov [_fq_color], ax

    ; --- find ymin, ymax across 4 vertices ---
    mov ax, [face_verts + 2]
    mov [_fq_ymin], ax
    mov [_fq_ymax], ax

    mov ax, [face_verts + 6]
    cmp ax, [_fq_ymin]
    jge .y1a
    mov [_fq_ymin], ax
.y1a:
    cmp ax, [_fq_ymax]
    jle .y1b
    mov [_fq_ymax], ax
.y1b:

    mov ax, [face_verts + 10]
    cmp ax, [_fq_ymin]
    jge .y2a
    mov [_fq_ymin], ax
.y2a:
    cmp ax, [_fq_ymax]
    jle .y2b
    mov [_fq_ymax], ax
.y2b:

    mov ax, [face_verts + 14]
    cmp ax, [_fq_ymin]
    jge .y3a
    mov [_fq_ymin], ax
.y3a:
    cmp ax, [_fq_ymax]
    jle .y3b
    mov [_fq_ymax], ax
.y3b:

    ; clip ymin/ymax to [0, 199]
    cmp word [_fq_ymin], 0
    jge .ymin_ok
    mov word [_fq_ymin], 0
.ymin_ok:
    cmp word [_fq_ymax], 199
    jle .ymax_ok
    mov word [_fq_ymax], 199
.ymax_ok:

    mov ax, [_fq_ymin]
    mov [_fq_sy], ax

.scan:
    mov ax, [_fq_sy]
    cmp ax, [_fq_ymax]
    jg .fq_done

    mov word [_fq_xL], 32767
    mov word [_fq_xR], -32768

    ; --- check each of 4 edges (macro emits unique labels) ---
    CHECK_EDGE 0, 1
    CHECK_EDGE 1, 2
    CHECK_EDGE 2, 3
    CHECK_EDGE 3, 0

    ; --- clip xL/xR to [0, 255] ---
    cmp word [_fq_xL], 0
    jge .xl_ok
    mov word [_fq_xL], 0
.xl_ok:
    cmp word [_fq_xR], 255
    jle .xr_ok
    mov word [_fq_xR], 255
.xr_ok:

    mov bx, [_fq_xL]
    mov dx, [_fq_xR]
    cmp bx, dx
    jg .skip_scan

    ; --- emit a 13-byte blitter FILL command to the chained list ---
    ; P88 format (see header for full layout). CMD at byte 12.
    ; BX = xL, DX = xR, sy in [_fq_sy], color in [_fq_color], page in [draw_seg]
    mov di, [blit_ptr]
    ; bytes 0-2: SRC = 0 (unused for fill)
    mov word [di + 0], 0
    mov byte [di + 2], 0
    ; byte 3: DST low = xL
    mov [di + 3], bl
    ; byte 4: DST mid = sy (always < 256)
    mov al, [_fq_sy]
    mov [di + 4], al
    ; byte 5: DST_FLAGS = page nibble (0 page A, 1 page B)
    cmp word [draw_seg], 0
    je .page_a_byte
    mov byte [di + 5], 1
    jmp .page_done_byte
.page_a_byte:
    mov byte [di + 5], 0
.page_done_byte:
    ; byte 6: MODE = 0x20 (8-bit mode, no ILCNT)
    mov byte [di + 6], 0x20
    ; byte 7: CPLG = 0xC0
    mov byte [di + 7], 0xC0
    ; byte 8: OUTER_CNT = 1 (single scanline)
    mov byte [di + 8], 1
    ; byte 9: INNER_CNT = span width = xR - xL + 1
    mov cx, dx
    sub cx, bx
    inc cx
    mov [di + 9], cl
    ; byte 10: STEP = 0
    mov byte [di + 10], 0
    ; byte 11: PAT = colour
    mov al, [_fq_color]
    mov [di + 11], al
    ; byte 12: CMD = 1 (continue; last span patched to 0 in main loop)
    mov byte [di + 12], 1
    add word [blit_ptr], CMD_SZ
.skip_scan:

    inc word [_fq_sy]
    jmp .scan

.fq_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret


; =====================================================================
; draw_hex16: render AX as 4 hex digits at (dh_x, dh_y)
; =====================================================================
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


; =====================================================================
; draw_hex8: render AX as 2 hex digits at (dh_x, dh_y)
; =====================================================================
draw_hex8:
    push ax
    push bx
    push cx
    push dx
    mov [dh_val], ax
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
    mov es, [draw_seg]      ; draw into current back page
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


blit_wait:
.bw:
    in al, BLSTAT
    test al, al
    jnz .bw
    ret

vblank_isr:
    push ax
    push ds
    mov ax, 0x9000              ; switch to data segment so we can write the counter
    mov ds, ax
    inc word [vblank_count]
    out ACK, al                 ; value of AL doesn't matter - the write is what acks
    pop ds
    pop ax
    iret


; =====================================================================
; dsp_ld: load CX words from CS:SI into ES:DI as bytes, with verify.
;   Standard AOTMC pattern: write low byte, write high byte, read back
;   low byte twice, read back high byte, compare; on mismatch, hang.
; Used to load DSP PRAM at startup.
; =====================================================================
dsp_ld:
    lodsw                       ; AX = next source word
    mov byte [es:di], al
    inc di
    mov byte [es:di], ah
    dec di
    mov dl, byte [es:di]
    mov dl, byte [es:di]        ; double-read (AOTMC pattern)
    inc di
    mov dh, byte [es:di]
    inc di
    cmp ax, dx
    je .ok
.fail:
    inc ax
    out BORDL, al               ; visible failure: flash border
    jmp .fail
.ok:
    loop dsp_ld
    ret


; =====================================================================
; transform_kernel: 256 words of DSP PRAM.
;   - 8 vertex transforms (27 instructions each = 216 words)
;   - MOV PC,(self) at word 216 (the DSP-side loop tail)
;   - NOP at word 217 (branch delay slot)
;   - NOPs filling 218..255 (never reached)
; =====================================================================
transform_kernel:
    VTRANSFORM 0
    VTRANSFORM 1
    VTRANSFORM 2
    VTRANSFORM 3
    VTRANSFORM 4
    VTRANSFORM 5
    VTRANSFORM 6
    VTRANSFORM 7
    dw 0xE9B9                   ; word 216: MOV PC,(0x1B9) <- DRAM[57] = 216
    dw 0xF000                   ; word 217: NOP (delay slot)
    times (256 - 218) dw 0xF000 ; words 218..255: filler NOPs
