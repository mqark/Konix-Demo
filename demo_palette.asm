; ===========================================================================
; KONIX MULTISYSTEM - 256 COLOUR PALETTE DEMO
; March 2026
;
; Displays all 256 palette entries as a 16x16 colour grid,
; with a three-line proportional title above it.
;
; ---------------------------------------------------------------------------
; HARDWARE REFERENCE (deduced from AOTMC89.ASM binary analysis)
; ---------------------------------------------------------------------------
;
; SCREEN
;   Resolution:     256 pixels wide x 200 scanlines tall
;   Pixel format:   1 byte per pixel, palette index
;   STARTL = 60    First active scanline
;   ENDL   = 259   Last active scanline (259-60+1 = 200 lines)
;   SCROLL1= 0x0100  Display starts reading VRAM at row=1, col=0.
;                    Row 0 of VRAM exists but is never shown.
;                    All blitter destination coordinates are offset
;                    by +1 in Y to compensate (via ascreen = 0x0100).
;
; PALETTE
;   Location:  Physical 0x40000  (segment 0x4000)
;   Entries:   256 x 2 bytes = 512 bytes
;   Format:    16-bit word, bits [11:8]=R, [7:4]=G, [3:0]=B  (4 bits each)
;              Word = 0x0RGB.  Entry 0 = background / transparent.
;
; FRAMEBUFFER
;   Location:  Physical 0x00000  (blitter page 0)
;              NOTE: This is VRAM, separate from CPU RAM.
;              The hardware address decoder routes blitter page 0
;              to VRAM, not to the 8088 interrupt vector table.
;   Layout:    256 bytes per row, rows 0..N
;              Row 0 is invisible due to SCROLL1 = 0x0100.
;
; BLITTER PAGE BYTE
;   The page byte in a blitter program = physical_segment / 0x1000
;   Screen (VRAM)     = page 0   (0x0000 * 0x10 / 0x1000 = 0)
;   Data segment      = page 9   (0x9000 * 0x10 / 0x1000 = 9)
;   Bit 4 of page byte = SOURCE ENABLE flag.  Must be set for the
;   source operand.  e.g. data seg as source = 0x09 | 0x10 = 0x19.
;
; BLITTER PROGRAMS
;   A blitter program is a 13-byte record in the data segment:
;     [0] src_x    [1] src_y    [2] src_page
;     [3] dst_x    [4] dst_y    [5] dst_page
;     [6] bset     [7] LFU      [8] outer   [9] inner  [10] step
;     [11] pattern [12] next_cmd
;
;   bset byte:
;     0x62 = FULLSCAN mode.  Bit 1 is the 9th (high) bit of the inner
;            count.  Combined with inner=0x00 gives inner=0x100=256,
;            filling a complete 256-byte scanline.  Use for clear_screen.
;            *** CRITICAL: 0x60 gives inner=0x000=0, a broken no-op. ***
;     0x20 = RECT mode.  Inner count comes from the inner register alone
;            (8-bit, 1..255).  Use for fill_rect with bstep = -width.
;
;   LFU byte (Logical Function Unit):
;     0xC0 = dest <- source  (straight copy / pattern fill)
;     0xC1 = dest <- source, skip write when source == colour 0
;            (hardware transparency; colour 0 is the transparent key)
;
;   bum_run command byte:
;     0x11 = DSTUP | SRCEN  : 2D destination, pattern as source -> rect fill
;     0x39 = DSTUP | SRCUP | SRCEN : 2D dest + 2D source -> sprite/glyph blit
;
; SPRITE SHEET ADDRESSING
;   The sprite sheet (SPRITES.BIN) lives in the data segment (9000h).
;   It is 256 bytes wide and treated as a virtual bitmap by the blitter.
;   srcex:srcey are X:Y coordinates within that 256-byte-wide bitmap.
;   For the coordinates to map cleanly to sheet pixels without X-axis
;   contamination, the sprite data MUST start on a 256-byte boundary
;   within its segment.  'sprites' is aligned accordingly (see below).
;   The blitter locates sheet pixel (sx, sy) at:
;     segment offset = sy*256 + sx + (offset sprites)
;   Because (offset sprites) low byte = 0x00 (alignment guarantee),
;   adding it as a 16-bit word to srcex:srcey only shifts srcey by
;   (offset sprites >> 8) rows, leaving srcex (X) undisturbed.
;
; FONT (from AOTMC sinfo table, verified against SPRITES.BIN)
;   The font is proportional, not fixed-width.
;   Characters live at sprite sheet row Y=52 for most glyphs.
;   Widths range from 2px (digit '1', 'I') to 8px ('&').
;   Heights are 5px for all alphanumeric chars except 'J' and 'Q' (6px).
;   This demo supports ASCII 0x20 (space) through 0x5A ('Z').
;
; ---------------------------------------------------------------------------


        include include\KMS.INC
        opt d+


; ===========================================================================
; DATA SEGMENT  (physical 0x90000, blitter page 9)
; ===========================================================================

data    segment at 9000h

; ---------------------------------------------------------------------------
; TEMP GLYPH BUFFER  (must be first - sits at offset 0, 256-byte aligned)
; ---------------------------------------------------------------------------
; 8 rows x 256 bytes = 2048 bytes.
; Blitter reads from srcep=19h, srcey=0, srcex=0 -> offset 0 in this segment.
; copy_and_remap writes remapped glyph pixels here before each blit.
temp_glyph:
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0  ; row 0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0  ; row 0 (256 bytes total)
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0  ; row 1
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0  ; row 1 (256 bytes total)
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0  ; rows 2-7 (6 x 256 = 1536 bytes)
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

        ; Keep palette data inside the data segment so it is addressable
        ; via DS when set_pal copies it into palette RAM.
        include ..\assets\palettes\PAL_DEMO.INC


; ---------------------------------------------------------------------------
; BLITTER PROGRAM: SOLID RECTANGLE FILL
; ---------------------------------------------------------------------------
; Fills a W x H rectangle at (blox, bloy) with pattern byte bcol.
;
; fill_rect sets:
;   bset  = 0x20 (RECT mode, inner count from bwid register)
;   LFU   = 0xC0 (dest <- pattern)
;   bstep = 256 - bwid   (advance to next row after each filled line)
;   cmd   = 0x11         (DSTUP | SRCEN = 2D destination, pattern fill)
;
; clear_screen overrides bset=0x62 (FULLSCAN) and bstep=0 for a
; linear full-width fill.  fill_rect always resets bset to 0x20.

block   DB  0,0,0           ; [0-2]  source: not used for pattern fill
blox    db  0               ; [3]    destination X (column, 0..255)
bloy    db  0               ; [4]    destination Y (row, 0..199 + scroll adj.)
sseg    db  0               ; [5]    destination page (0 = screen VRAM)
bset    DB  020h            ; [6]    mode byte (overridden per call)
        DB  0C0h            ; [7]    LFU: dest <- pattern
bhig    DB  0               ; [8]    outer loop: height in scanlines
bwid    DB  0               ; [9]    inner loop: width in pixels (RECT mode)
bstep   DB  0               ; [10]   step: 256 - width (wraps to next row)
bcol    DB  0               ; [11]   pattern: palette index of fill colour
        DB  0               ; [12]   next command: STOP


; ---------------------------------------------------------------------------
; BLITTER PROGRAM: SPRITE / GLYPH BLIT WITH TRANSPARENCY
; ---------------------------------------------------------------------------
; Copies a W x H rectangle from the sprite sheet to the screen.
; Pixels with colour index 0 in the source are not written (transparent).
;
; draw_char sets:
;   srcex:srcey  = sheet X:Y of the glyph
;   dstx:dsty    = screen X:Y (adjusted for SCROLL1)
;   swid:shig    = glyph width and height
;   sstp         = 256 - swid  (source row step)
;   cmd  = 0x39  (DSTUP | SRCUP | SRCEN = 2D-to-2D copy)
;
; srcep = 0x19:
;   bits [3:0] = 9  (data segment, 0x9000 / 0x1000 = 9)
;   bit  4     = 1  (SOURCE ENABLE - must be set for source operands)

dsprite
srcex   db  0               ; [0]  source X within sprite sheet
srcey   db  0               ; [1]  source Y within sprite sheet
srcep   db  19h             ; [2]  source page: page 9 (9000h/1000h=9), bit4=source enable
dstx    db  0               ; [3]  destination X on screen
dsty    db  0               ; [4]  destination Y on screen
dstp    db  0               ; [5]  destination page: 0 (screen VRAM)
        db  020h            ; [6]  mode: 256-colour pixel mode
        db  0C1h            ; [7]  LFU: copy with colour-0 transparency
shig    db  8               ; [8]  outer loop: glyph height
swid    db  8               ; [9]  inner loop: glyph width
sstp    db  0F8h            ; [10] source step: 256 - 8
        db  0               ; [11] pattern: colour 0 (transparent key)
        db  0               ; [12] next command: STOP


; ---------------------------------------------------------------------------
; SCREEN ORIGIN
; ---------------------------------------------------------------------------
; SCROLL1 = 0x0100 makes VRAM row 0 invisible.
; ascreen = 0x0100 is added to every blitter destination coordinate word,
; incrementing the Y component by 1 so all draws land on visible rows.
; ascb = 0 is the destination page byte (screen VRAM = page 0).

ascreen dw  0100h           ; Y=1, X=0 screen origin offset (matches SCROLL1)
ascb    db  0               ; screen VRAM page = 0


; ---------------------------------------------------------------------------
; FILL_RECT PARAMETERS
; ---------------------------------------------------------------------------
rect_x  db  0               ; left edge (0..255)
rect_y  db  0               ; top edge (0..199, relative to visible screen)
rect_w  db  0               ; width in pixels
rect_h  db  0               ; height in scanlines
rect_c  db  0               ; fill colour palette index (0..255)


; ---------------------------------------------------------------------------
; TEXT CURSOR
; ---------------------------------------------------------------------------
text_x  db  0               ; current X position; advances after each glyph
text_y  db  0               ; current Y position; unchanged during a string


; ---------------------------------------------------------------------------
; TITLE STRINGS  (ASCII 0x20..0x5A only: space, 0-9, A-Z)
; ---------------------------------------------------------------------------
title1_text db 'KONIX MULTISYSTEM',0
title2_text db '256 COLOUR DEMO',0
title3_text db 'MARCH 2026',0


; ---------------------------------------------------------------------------
; PROPORTIONAL FONT TABLE
; ---------------------------------------------------------------------------
; 3 bytes per entry: [sheet_x, sheet_y, char_width]
; Entry (n) covers ASCII (n + 0x20).
; Covers 0x20 (space) through 0x5A ('Z') inclusive = 59 entries = 177 bytes.
;
; Coordinates are relative to the start of SPRITES.BIN.
; Heights are 5px for all entries needed by this demo (no J or Q in strings).
;
; Source: AOTMC89 sinfo table, entries s4 (space) through s62 (Z).

font_info:
;       w    h    x    y                char   ascii
		db   4,  5,   0,  52,0,0,0,0	;sp  20h
		db   2,  5,   4,  52,0,0,0,0	;!  21h
		db   4,  2,   6,  52,0,0,0,0	;"  22h
		db   6,  5,  10,  52,0,0,0,0	;#  23h
		db   5,  5,  16,  52,0,0,0,0	;$  24h
		db   4,  5,  21,  52,0,0,0,0	;%  25h
		db   8,  5,  25,  52,0,0,0,0	;&  26h
		db   2,  2,  33,  52,0,0,0,0	;'  27h
		db   3,  5,  35,  52,0,0,0,0	;(  28h
		db   3,  5,  38,  52,0,0,0,0	;)  29h
		db   6,  5,  41,  52,0,0,0,0	;*  2Ah
		db   6,  5,  47,  52,0,0,0,0	;+  2Bh
		db   3,  6,  53,  52,0,0,0,0	;,  2Ch
		db   5,  3,  56,  52,0,0,0,0	;-  2Dh
		db   2,  5,  61,  52,0,0,0,0	;.  2Eh
		db   4,  5,  63,  52,0,0,0,0	;/  2Fh
		db   4,  5,  67,  52,0,0,0,0	;0  30h
		db   2,  5,  71,  52,0,0,0,0	;1  31h
		db   4,  5,  73,  52,0,0,0,0	;2  32h
		db   4,  5,  77,  52,0,0,0,0	;3  33h
		db   5,  5,  81,  52,0,0,0,0	;4  34h
		db   4,  5,  86,  52,0,0,0,0	;5  35h
		db   4,  5,  90,  52,0,0,0,0	;6  36h
		db   4,  5,  94,  52,0,0,0,0	;7  37h
		db   4,  5,  98,  52,0,0,0,0	;8  38h
		db   4,  5, 102,  52,0,0,0,0	;9  39h
		db   2,  4, 106,  52,0,0,0,0	;:  3Ah
		db   3,  6, 108,  52,0,0,0,0	;;  3Bh
		db   4,  5, 111,  52,0,0,0,0	;<  3Ch
		db   4,  4, 115,  52,0,0,0,0	;=  3Dh
		db   4,  5, 119,  52,0,0,0,0	;>  3Eh
		db   4,  5, 123,  52,0,0,0,0	;?  3Fh
		db   6,  5, 127,  52,0,0,0,0	;@  40h
		db   4,  5, 134,  52,0,0,0,0	;A  41h
		db   5,  5, 138,  52,0,0,0,0	;B  42h
		db   4,  5, 143,  52,0,0,0,0	;C  43h
		db   4,  5, 147,  52,0,0,0,0	;D  44h
		db   4,  5, 151,  52,0,0,0,0	;E  45h
		db   4,  5, 155,  52,0,0,0,0	;F  46h
		db   4,  5, 159,  52,0,0,0,0	;G  47h
		db   4,  5, 163,  52,0,0,0,0	;H  48h
		db   2,  5, 167,  52,0,0,0,0	;I  49h
		db   3,  6, 169,  52,0,0,0,0	;J  4Ah
		db   5,  5, 172,  52,0,0,0,0	;K  4Bh
		db   4,  5, 177,  52,0,0,0,0	;L  4Ch
		db   6,  5, 181,  52,0,0,0,0	;M  4Dh
		db   4,  5, 187,  52,0,0,0,0	;N  4Eh
		db   4,  5, 191,  52,0,0,0,0	;O  4Fh
		db   4,  5, 195,  52,0,0,0,0	;P  50h
		db   4,  6, 199,  52,0,0,0,0	;Q  51h
		db   4,  5, 204,  52,0,0,0,0	;R  52h
		db   4,  5, 208,  52,0,0,0,0	;S  53h
		db   4,  5, 212,  52,0,0,0,0	;T  54h
		db   4,  5, 216,  52,0,0,0,0	;U  55h
		db   4,  5, 220,  52,0,0,0,0	;V  56h
		db   6,  5, 224,  52,0,0,0,0	;W  57h
		db   6,  5, 230,  52,0,0,0,0	;X  58h
		db   4,  5, 236,  52,0,0,0,0	;Y  59h
		db   4,  5, 240,  52,0,0,0,0	;Z  5Ah


; ---------------------------------------------------------------------------
; SPRITE SHEET
; ---------------------------------------------------------------------------
; The blitter treats the data segment as a 256-byte-wide virtual screen.
; srcex:srcey are X:Y pixel coordinates within it.
; draw_char loads raw sheet X:Y from font_info, then does:
;   add word ptr srcex, offset sprites
; which adds the sprite sheet's segment offset as a word, simultaneously
; shifting X by the low byte and Y by the high byte. This is exactly how
; the game (AOTMC89) addresses all sprites.

sprites:                    ; full sheet including 4-byte header (00 00 00 C8)
        incbin "SPRITES.BIN"


data    ends


; ===========================================================================
; CODE SEGMENT  (physical 0x80000)
; ===========================================================================

code_seg segment at 8000h
        assume cs:code_seg
        assume ds:data

start:
        jmp do_demo


; ---------------------------------------------------------------------------
; MACRO: bum_run  <command>
; ---------------------------------------------------------------------------
; Fire a blitter program.  Must be called with AX = offset of the blitter
; program record in the data segment (e.g. AX = offset block).
;
; BLPROG0 (port 30h, word OUT): program address within data segment.
; BLPROG2 (port 32h, word OUT): {page_byte, command_byte}
;   page_byte = 09h  (data segment = 9000h, page 9000h/1000h = 9)
;   command_byte:
;     11h = DSTUP | SRCEN            rect / solid fill
;     39h = DSTUP | SRCUP | SRCEN   sprite / glyph blit (2D src + 2D dst)
;
; Concurrency note: the blitter runs independently of the CPU.  This demo
; does not poll for blitter completion between calls because the CPU
; overhead of setting up each subsequent operation provides adequate
; separation for a static, one-shot draw sequence.  If you add rapid
; per-frame redraws, poll BLCON (port 34h) before modifying shared
; blitter program data to avoid corrupting an in-flight operation.

bum_run MACRO command
        out  BLPROG0, ax            ; program address -> blitter
        mov  al, 09h                ; page: data segment = page 9
        mov  ah, command            ; command byte
        out  BLPROG2, ax            ; {page, cmd} -> fire blitter
        ENDM


; ---------------------------------------------------------------------------
; SUBROUTINE: set_pal
; ---------------------------------------------------------------------------
; Copy 256 palette entries from game_pal (in data segment) into
; palette RAM at segment 0x4000 (physical 0x40000).
;
; game_pal comes from PAL256_RGBCUBE.INC.  The include file has a
; 1-byte type/format prefix before the 512-byte colour table, so SI
; is incremented once before the copy loop.
;
; Each entry is a 16-bit word: 0x0RGB  (4 bits per channel, 0-15).
; Entry 0 defines the background/transparent colour.

set_pal:
        mov  ax, 4000h
        mov  es, ax                 ; ES = palette RAM segment
        xor  di, di                 ; write from entry 0
        mov  si, offset game_pal
        inc  si                     ; skip the 1-byte format prefix
        mov  cx, 0100h
pal_loop:
        lodsw                       ; load 2-byte colour entry from DS:SI
        stosw                       ; store to ES:DI (palette RAM)
        loop pal_loop
        ret


; ---------------------------------------------------------------------------
; SUBROUTINE: fill_rect
; ---------------------------------------------------------------------------
; Blitter solid-colour rectangle fill.
;
; Caller sets before calling:
;   rect_x  left edge, pixels    (0..255)
;   rect_y  top edge,  scanlines (0..199, visible area)
;   rect_w  width,     pixels    (1..255)
;   rect_h  height,    scanlines (1..200)
;   rect_c  fill colour index    (0..255)
;
; Uses blitter program 'block'.  Overwrites: blox, bloy, sseg,
; bset, bhig, bwid, bstep, bcol.
;
; bset = 0x20 (RECT mode):   inner count = bwid  (8-bit register)
; bstep = 256 - bwid:        after bwid pixels, step to the next row.
;   The step wraps in 8 bits: (0 - bwid) = 256 - bwid.
;   bwid + bstep = 256 = one full scanline, so the write head lands
;   exactly at column 0 of the next row after each inner loop.
;
; All Y coordinates are offset +1 to skip invisible VRAM row 0.
; This is done by adding ascreen (= 0x0100) to the blox:bloy word,
; which carries +1 into the high byte (bloy) without affecting blox.

fill_rect:
        ; Pack rect_x (low byte) and rect_y (high byte) into blox:bloy
        mov  al, rect_x
        mov  ah, rect_y
        mov  word ptr blox, ax      ; blox = rect_x, bloy = rect_y

        ; Apply SCROLL1 offset: add 1 to bloy so row 0 is always skipped
        mov  ax, ascreen            ; ascreen = 0x0100 (Y+1, X+0)
        add  word ptr blox, ax      ; bloy += 1

        ; Destination page: screen VRAM
        mov  al, ascb               ; ascb = 0
        mov  sseg, al

        ; Rectangle dimensions
        mov  al, rect_h
        mov  bhig, al               ; outer loop = height

        mov  al, rect_w
        mov  bwid, al               ; inner loop = width

        ; Fill colour
        mov  al, rect_c
        mov  bcol, al

        ; RECT mode: inner count is bwid (NOT the high-bit variant)
        ; Explicitly set here in case clear_screen ran before us and left 0x62.
        mov  bset, 020h

        ; step = 256 - width  (8-bit: 0 - bwid wraps correctly)
        mov  al, 0
        sub  al, bwid               ; AL = 256 - bwid
        mov  bstep, al

        mov  ax, offset block
        bum_run 11h                 ; DSTUP | SRCEN: 2D fill
        ret


; ---------------------------------------------------------------------------
; SUBROUTINE: clear_screen
; ---------------------------------------------------------------------------
; Clear all 200 visible scanlines to colour index 0 (black).
;
; Uses FULLSCAN mode (bset = 0x62):
;   Bit 1 of bset is the 9th (high) bit of the inner loop count.
;   bwid = 0x00, plus bit 1 of bset = 1, gives inner = 0x100 = 256.
;   bstep = 0: no per-row step; the blitter advances linearly.
;   Result: 200 complete 256-byte scanlines written at hardware speed.
;
; *** DO NOT USE bset = 0x60 HERE ***
;   0x60 has bit 1 = 0, giving inner = 0x000 = 0.
;   The blitter would execute a zero-width inner loop: nothing drawn.
;   The correct value is 0x62.

clear_screen:
        ; Clear using two 128-wide rect fills side by side
        ; Left half: x=0, width=128
        mov  rect_x, 0
        mov  rect_y, 0
        mov  rect_w, 80h            ; 128 pixels wide
        mov  rect_h, 0C8h           ; 200 scanlines
        mov  rect_c, 0
        call fill_rect
        call blit_wait

        ; Right half: x=128, width=128
        mov  rect_x, 80h
        mov  rect_y, 0
        mov  rect_w, 80h
        mov  rect_h, 0C8h
        mov  rect_c, 0
        call fill_rect
        call blit_wait
        ret


; ---------------------------------------------------------------------------
; SUBROUTINE: draw_palette_grid
; ---------------------------------------------------------------------------
; Render a 16-column x 16-row grid of all 256 palette colours.
;
; Layout:
;   Cell size:   16px wide x 10px tall
;   Grid origin: X=0, Y=36 (above the 200-line visible area midpoint)
;   Grid extent: X=0..255 (16*16=256px), Y=36..195 (16*10=160 scanlines)
;
; Colour index = row * 16 + column, traversed in raster order 0..255.
; BX is used as the colour counter (0..255) to avoid a data variable.

draw_palette_grid:
        xor  bx, bx

grid_loop:
        mov  al, bl
        mov  rect_c, al

        ; Cell size: 16px wide, 11px tall
        mov  rect_w, 10h
        mov  rect_h, 0Bh

        ; Column X = (index & 0x0F) * 16
        mov  al, bl
        and  al, 0Fh
        shl  al, 1
        shl  al, 1
        shl  al, 1
        shl  al, 1
        mov  rect_x, al

        ; Row Y = 24 + row * 11
        ; row*11 = row*8 + row*2 + row*1
        mov  al, bl
        shr  al, 1
        shr  al, 1
        shr  al, 1
        shr  al, 1                  ; AL = row (0..15)
        mov  ah, al                 ; save row
        shl  al, 1
        shl  al, 1
        shl  al, 1                  ; AL = row*8
        shl  ah, 1                  ; AH = row*2
        add  al, ah                 ; AL = row*10
        mov  ah, bl
        shr  ah, 1
        shr  ah, 1
        shr  ah, 1
        shr  ah, 1                  ; AH = row again
        add  al, ah                 ; AL = row*11
        add  al, 18h                ; + 24 (banner height)
        mov  rect_y, al

        call fill_rect

        inc  bx
        cmp  bx, 0100h
        jl   grid_loop
        ret


; ---------------------------------------------------------------------------
; SUBROUTINE: draw_char
; ---------------------------------------------------------------------------
; Blit one proportional glyph from the sprite sheet to the screen.
;
; Input:   AL = ASCII character (0x20 space .. 0x5A 'Z')
; Effect:  glyph drawn at (text_x, text_y);
;          text_x advances by char_width + 1 (1 pixel inter-glyph gap)
;
; Characters outside the 0x20..0x5A range are skipped silently.
;
; FONT TABLE LOOKUP
;   font_info offset = (ascii_code - 0x20) * 3
;   entry[0] = sheet_x   (X coordinate in SPRITES.BIN)
;   entry[1] = sheet_y   (Y coordinate in SPRITES.BIN)
;   entry[2] = char_width (pixels)
;   char_height = 5 (constant for all demo-string characters)
;
; SPRITE SHEET ADDRESSING
;   srcex is initialised with the raw sheet X from the table.
;   srcey is initialised with the raw sheet Y.
;   Then (offset sprites) is added as a 16-bit word to srcex:srcey.
;   Because 'sprites' is 256-byte aligned, its low byte = 0x00, so
;   this add only increments srcey (Y) by (offset sprites >> 8) rows,
;   locating the glyph at the correct position within segment 9000h.
;
; Modifies: AX, BX; preserves CX, DX, SI, DI.

; ---------------------------------------------------------------------------
; SUBROUTINE: copy_and_remap
; ---------------------------------------------------------------------------
; Copies glyph pixels from sprite sheet into temp_glyph buffer,
; remapping colour 0x68 -> 0xF0 on the fly.
; Call after srcex/srcey/swid/shig are set up with the full sheet address.
; On return: srcex=0, srcey=0 (blitter reads from temp_glyph).

copy_and_remap:
        push si
        push di

        mov  si, word ptr srcex
        xor  di, di
        mov  ch, shig

copy_row:
        mov  cl, swid
copy_col:
        mov  al, [si]
        cmp  al, 68h
        jne  copy_store
        mov  al, 0F0h
copy_store:
        mov  [di], al
        inc  si
        inc  di
        dec  cl
        jnz  copy_col

        xor  ah, ah
        mov  al, swid
        neg  al
        add  si, ax
        add  di, ax
        dec  ch
        jnz  copy_row

        mov  srcex, 0
        mov  srcey, 0

        pop  di
        pop  si
        ret


draw_char:
		; Bounds check
		cmp	al,020h
		jb	draw_char_done
		cmp	al,05Ah
		ja	draw_char_done

		; Set up destination from text_x/text_y
		mov	bl,text_x
		mov	cl,text_y
		mov	dstx,bl
		mov	dsty,cl

		; Convert ASCII to font_info table offset (* 8 via rol)
		sub	al,020h
		xor	ah,ah
		rol	ax,1
		rol	ax,1
		rol	ax,1
		mov	bx,offset font_info
		add	bx,ax

		; Read width, height, srcex, srcey
		xor	ah,ah
		mov	al,[bx]
		mov	swid,al
		mov	cl,1[bx]
		mov	shig,cl
		mov	cl,2[bx]
		mov	srcex,cl
		mov	cx,3[bx]
		mov	srcey,cl

		; sstp = 256 - width
		mov	cl,255
		sub	cl,al
		inc	cl
		mov	sstp,cl

		; Add sprite sheet offset to get absolute source address
		mov	ax,offset sprites+4
		add	word ptr srcex,ax

		; Copy pixels to temp_glyph with 0x68->0xF0 remapping
		push si
		push bx
		call copy_and_remap
		pop  bx
		pop  si

		; Blit from temp_glyph (srcex=0, srcey=0) to screen
		mov	ax,ascreen
		add	word ptr dstx,ax
		mov	al,ascb
		mov	dstp,al
		mov	ax,offset dsprite
		bum_run	39h

		; Advance text cursor
		mov	al,[bx]
		inc	al
		add	text_x,al

draw_char_done:
        ret


; ---------------------------------------------------------------------------
; SUBROUTINE: draw_string
; ---------------------------------------------------------------------------
; Draw a null-terminated ASCII string at the current (text_x, text_y).
; DS:SI must point to the string before calling.
; text_x advances as each character is drawn; text_y is unchanged.

draw_string:
        lodsb                       ; AL = next byte from DS:SI
        or   al, al
        jz   draw_string_done
        call draw_char
        jmp  draw_string
draw_string_done:
        ret


; ---------------------------------------------------------------------------
; SUBROUTINE: draw_title
; ---------------------------------------------------------------------------
; Draw the three-line demo title centred on the 256-pixel-wide screen,
; using the rows above the palette grid (Y = 2, 12, 22).
;
; X positions are pre-computed from the proportional font widths:
;   "KONIX MULTISYSTEM"  ~92px  -> centre at X = (256-92)/2 = 82
;   "256 COLOUR DEMO"    ~76px  -> centre at X = (256-76)/2 = 90
;   "MARCH 2026"         ~51px  -> centre at X = (256-51)/2 = 102
;
; Adjust these if the assembler-computed layout differs slightly.

draw_title:
        ; "KONIX MULTISYSTEM" width=87px, centred at X=84 (54h), Y=3
        mov  text_x, 54h
        mov  text_y, 3
        mov  si, offset title1_text
        call draw_string

        ; "256 COLOUR DEMO" width=76px, centred at X=90 (5Ah), Y=10
        mov  text_x, 5Ah
        mov  text_y, 0Ah
        mov  si, offset title2_text
        call draw_string

        ; "MARCH 2026" width=51px, centred at X=102 (66h), Y=17
        mov  text_x, 66h
        mov  text_y, 11h
        mov  si, offset title3_text
        call draw_string
        ret


; ===========================================================================
; MAIN ENTRY POINT
; ===========================================================================

do_demo:

        ; ---- Segment registers ----
        mov  ax, 9000h
        mov  ds, ax                 ; DS = data segment (blitter programs, tables)

        ; Stack: place it in the data segment, top of a 256-byte scratch area.
        ; SS:SP = 9000h:00FFh  ->  grows down safely without hitting code or data.
        mov  ax, 9000h
        mov  ss, ax
        mov  sp, 0FFh               ; top of scratch area, well clear of blitter data

        ; ---- Video controller ----
        mov  ax, 0000h
        out  BORDL, ax              ; border colour: black

        ; 256-colour chunky pixel mode
        mov  al, 01h
        out  MODE, al

        ; Plane mask = 0, index register = 0
        mov  al, 00h
        out  PMASK, al
        out  INDEX, al

        mov  ax, 0100h
        out  SCROLL1, ax
        out  SCROLL3, al

        ; ---- Load palette and clear screen BEFORE enabling display ----
        call set_pal
        call clear_screen

        ; Enable display window now that VRAM is clean
        mov  ax, 3Ch                ; first active scanline = 60
        out  STARTL, ax
        mov  ax, 0103h              ; last active scanline = 259
        out  ENDL, ax

        ; ---- Draw the scene ----
        call draw_palette_grid
        call blit_wait

        ; Draw black banner over top 24 scanlines (two 128-wide rects)
        mov  rect_x, 0
        mov  rect_y, 0
        mov  rect_w, 80h            ; 128
        mov  rect_h, 18h            ; 24
        mov  rect_c, 0
        call fill_rect
        call blit_wait

        mov  rect_x, 80h
        mov  rect_y, 0
        mov  rect_w, 80h
        mov  rect_h, 18h
        mov  rect_c, 0
        call fill_rect
        call blit_wait

        ; Draw centred title text over banner
        call draw_title

        ; ---- Spin (no game loop yet) ----
forever:
        jmp  forever


; ---------------------------------------------------------------------------
; SUBROUTINE: blit_wait
; ---------------------------------------------------------------------------
; Software delay loop to allow the blitter to finish before the next
; operation. BLCON reads return 0 in the emulator so we can't poll;
; instead burn a fixed number of cycles with NOP+LOOP.

blit_wait:
        mov  cx, 0FFFFh
blit_wait_loop:
        mov  al, al
        loop blit_wait_loop
        ret


code_seg ends
        end  start
