; Raycaster for the NConsole: walk a maze in first person. A prototype.
;
; Up and down walk, left and right turn; with A held, left and right step
; sideways; B runs.
;
; How it works:
; - The maze is 32 x 32 cells of ASCII art in ROM: '.' is empty, anything
;   else a wall. The player's position is 8.8 fixed point in cells, the
;   angle 0-255 for a full turn (0 east, growing toward the south).
; - Each picture casts 40 rays, one angle step (1.4 degrees) apart, and
;   steps each from cell edge to cell edge (DDA) until it meets a wall.
;   The multiplies the start of a ray needs are done with quarter squares;
;   the wall's height comes from a table by distance, one per ray angle,
;   which also undoes the fisheye.
; - The video chip has no pixels to set, only tiles, so the walls are made
;   of tiles: each tile holds two rays side by side, each 4 pixels wide,
;   with 0-8 pixels of wall in 2-pixel steps, light or dark by the side of
;   the wall. 81 tiles above the horizon, 81 below.
; - Pictures are drawn into one of two halves of the background map while
;   the other is shown, and SCROLLY flips between them: no tearing. The
;   top three rows, fixed with FIXROWS, are the status bar.
; - A picture takes more than a frame; the player moves once for each
;   frame that went by, so speed doesn't depend on the frame rate.
;
; The tables and tiles come from tools/make_raycast_tables.gd.

.title "Raycaster"
.prgbanks 2                 ; bank 0 the wall heights, bank 1 the rest

; --- hardware ---
VCTRL   = $3000
BGCOLOR = $3001
SCROLLY = $3003
FIXROWS = $3004
PAD1    = $3010
FRAME   = $3020
VRAM    = $2000

BTN_UP    = $01
BTN_DOWN  = $02
BTN_LEFT  = $04
BTN_RIGHT = $08
BTN_A     = $10
BTN_B     = $20

; --- the view ---
RAYS      = 40
HALF_FOV  = 20              ; the rays go from the angle - 20 to + 19
FONT      = 130             ; the tile of a character: FONT + its code
FLOOR_TILES = 81            ; the tiles below the horizon follow those above
SPACE     = FONT + ' '
HUD_ROWS  = 3
EMPTY     = '.'
TURN      = 2               ; angle steps a frame
MARGIN    = 64              ; the closest the player comes to a wall, 1/256 cells
MAX_FRAMES = 6              ; frames a picture is counted as, at most

; --- variables ---
.section ram
px_l:    .res 1             ; the player: position (8.8 cells) and angle
px_h:    .res 1
py_l:    .res 1
py_h:    .res 1
pa:      .res 1
pad:     .res 1
; one ray
ray:     .res 1             ; 0-39
ra:      .res 1             ; its angle
stepx:   .res 1             ; +1 or -1 ($ff), added to mp
stepy:   .res 2             ; +32 or -32, added to mp
ddxl:    .res 1             ; cells along the ray per cell in x, 8.8
ddxh:    .res 1
ddyl:    .res 1             ; and in y
ddyh:    .res 1
sxl:     .res 1             ; how far along the ray the next x edge is
sxh:     .res 1
syl:     .res 1             ; and the next y edge
syh:     .res 1
dl:      .res 1             ; how far the wall is
dh:      .res 1
side:    .res 1             ; 0 x side (light), 32 y side (dark)
mp:      .res 2             ; the cell the ray is in
hp:      .res 2             ; the page of htab for this ray
; multiplying
ma:      .res 1
mb:      .res 1
pl:      .res 1
ph:      .res 1
; moving
mang:    .res 1
dx:      .res 1
dy:      .res 1
dext:    .res 1
nl:      .res 1
nh:      .res 1
cx:      .res 1
cy:      .res 1
wp:      .res 2
; pictures
back:    .res 1             ; the half of the map being drawn: 0 or 1
now:     .res 1
last:    .res 1             ; FRAME at the last picture
frames:  .res 1             ; frames since then
k:       .res 1
tmp:     .res 1
rows:    .res 24            ; where each row of the back half is: up0-5, dn0-5
left:    .res 6 * 20        ; the left ray's part of each tile, row by row

UP0 = rows
DN0 = rows + 12

; --- the code ---
.section rom
.org $c000

map:                        ; 32 x 32, at the start of the bank: rows don't cross pages
	.byte "################################"
	.byte "#..............#...............#"
	.byte "#..............#...............#"
	.byte "#...####.......#.......#####...#"
	.byte "#...#..........................#"
	.byte "#...#......#########...........#"
	.byte "#..........#.......#.....#.....#"
	.byte "#######....#.......#.....#.....#"
	.byte "#..........#...........###.....#"
	.byte "#..........#.......#...........#"
	.byte "#....#.....#########...........#"
	.byte "#....#.........................#"
	.byte "#....#.........#######...#######"
	.byte "#....#.........#.....#.........#"
	.byte "#..............#.....#.........#"
	.byte "######...#######.....#.........#"
	.byte "#.......................#####..#"
	.byte "#..........................#...#"
	.byte "#...###########.............#..#"
	.byte "#...#.........#...........#....#"
	.byte "#...#.........#.......#........#"
	.byte "#...#....#....#................#"
	.byte "#........#........#.....########"
	.byte "#...#....#....#...#............#"
	.byte "#...#.........#...#............#"
	.byte "#...###########...#....####....#"
	.byte "#.................#....#..#....#"
	.byte "#.................#....#..#....#"
	.byte "#######..##########....#..#....#"
	.byte "#..............................#"
	.byte "#..............................#"
	.byte "################################"

reset:
	ld a, #$01              ; the background only
	st a, VCTRL
	ld a, #0                ; black behind the status bar's letters
	st a, BGCOLOR
	st a, SCROLLY
	ld a, #HUD_ROWS
	st a, FIXROWS
	call hud_init
	ld a, #$80              ; in the first room, looking east
	st a, px_l
	st a, py_l
	ld a, #3
	st a, px_h
	ld a, #2
	st a, py_h
	ld a, #0
	st a, pa
	ld a, #1                ; half 0 is shown, draw into half 1
	st a, back
	ld a, FRAME
	st a, last

main:
	ld a, FRAME
	st a, now
	sub last
	jnz @go
	wait                    ; drawn within the frame: wait for the next
	jmp main
@go:
	cmp #MAX_FRAMES
	jc @count
	ld a, #MAX_FRAMES
@count:
	st a, frames
	st a, k
	ld a, now
	st a, last
@moves:
	call move
	dec k
	jnz @moves
	call render
	call hud_fps
	jmp main

; --- moving ---

; One frame of the controller.
move:
	ld a, PAD1
	st a, pad
	and #BTN_A
	jnz @strafe
	ld a, pad
	and #BTN_LEFT
	jz @not_left
	ld a, pa
	sub #TURN
	st a, pa
@not_left:
	ld a, pad
	and #BTN_RIGHT
	jz @walk
	ld a, pa
	add #TURN
	st a, pa
	jr @walk
@strafe:
	ld a, pad
	and #BTN_LEFT
	jz @not_sl
	ld a, pa
	sub #64
	call step
@not_sl:
	ld a, pad
	and #BTN_RIGHT
	jz @walk
	ld a, pa
	add #64
	call step
@walk:
	ld a, pad
	and #BTN_UP
	jz @not_up
	ld a, pa
	call step
@not_up:
	ld a, pad
	and #BTN_DOWN
	jz @done
	ld a, pa
	add #128
	call step
@done:
	ret

; A step toward angle A, two with B held.
step:
	st a, mang
	call step_once
	ld a, pad
	and #BTN_B
	jz @done
	call step_once
@done:
	ret

step_once:
	ld x, mang
	ld a, mv,x
	st a, dx
	ld a, mang
	sub #64
	mov x, a
	ld a, mv,x
	st a, dy
	call try_x
	call try_y
	ret

; Moves dx along x unless that comes within MARGIN of a wall.
try_x:
	ld a, dx
	jz @no
	and #$80                ; sign-extend
	jz @plus
	ld a, #$ff
@plus:
	st a, dext
	ld a, px_l
	add dx
	st a, nl
	ld a, px_h
	adc dext
	st a, nh
	ld a, dext              ; the cell just ahead
	jnz @minus
	ld a, nl
	add #MARGIN
	ld a, nh
	adc #0
	jr @probe
@minus:
	ld a, nl
	sub #MARGIN
	ld a, nh
	sbc #0
@probe:
	st a, cx
	ld a, py_l              ; at both edges of the player
	sub #MARGIN
	ld a, py_h
	sbc #0
	st a, cy
	call wall_at
	jnz @no
	ld a, py_l
	add #MARGIN
	ld a, py_h
	adc #0
	st a, cy
	call wall_at
	jnz @no
	ld a, nl
	st a, px_l
	ld a, nh
	st a, px_h
@no:
	ret

; The same for dy along y.
try_y:
	ld a, dy
	jz @no
	and #$80
	jz @plus
	ld a, #$ff
@plus:
	st a, dext
	ld a, py_l
	add dy
	st a, nl
	ld a, py_h
	adc dext
	st a, nh
	ld a, dext
	jnz @minus
	ld a, nl
	add #MARGIN
	ld a, nh
	adc #0
	jr @probe
@minus:
	ld a, nl
	sub #MARGIN
	ld a, nh
	sbc #0
@probe:
	st a, cy
	ld a, px_l
	sub #MARGIN
	ld a, px_h
	sbc #0
	st a, cx
	call wall_at
	jnz @no
	ld a, px_l
	add #MARGIN
	ld a, px_h
	adc #0
	st a, cx
	call wall_at
	jnz @no
	ld a, nl
	st a, py_l
	ld a, nh
	st a, py_h
@no:
	ret

; Z clear if the cell (cx, cy) is a wall.
wall_at:
	ld x, cy
	ld a, maprow_l,x
	add cx
	st a, wp
	ld a, maprow_h,x
	st a, wp+1
	ld y, #0
	ld a, [wp],y
	cmp #EMPTY
	ret

; --- drawing ---

; Casts the 40 rays into the back half of the map, then shows it.
render:
	ld x, #23               ; where the back half's rows are
	ld a, back
	jnz @half1
@half0:
	ld a, rows_half0,x
	st a, rows,x
	dec x
	jnn @half0
	jr @cast
@half1:
	ld a, rows_half1,x
	st a, rows,x
	dec x
	jnn @half1
@cast:
	ld a, #0
	st a, ray
	st a, hp
@ray:
	ld x, ray
	ld a, hpage,x
	st a, hp+1
	ld a, pa
	add ray
	sub #HALF_FOV
	st a, ra
	call cast               ; x: the column's index into the tile tables
	ld a, ray
	shr a
	mov y, a                ; the tile column
	ld a, ray
	and #1
	jnz @right
	ld a, wl0,x             ; a left ray: keep its part of each tile
	st a, left + 0 * 20,y
	ld a, wl1,x
	st a, left + 1 * 20,y
	ld a, wl2,x
	st a, left + 2 * 20,y
	ld a, wl3,x
	st a, left + 3 * 20,y
	ld a, wl4,x
	st a, left + 4 * 20,y
	ld a, wl5,x
	st a, left + 5 * 20,y
	jmp @next
@right:                     ; a right ray: put the tiles in, above and below
	ld a, left + 0 * 20,y
	add wr0,x
	st a, [UP0 + 0],y
	add #FLOOR_TILES
	st a, [DN0 + 0],y
	ld a, left + 1 * 20,y
	add wr1,x
	st a, [UP0 + 2],y
	add #FLOOR_TILES
	st a, [DN0 + 2],y
	ld a, left + 2 * 20,y
	add wr2,x
	st a, [UP0 + 4],y
	add #FLOOR_TILES
	st a, [DN0 + 4],y
	ld a, left + 3 * 20,y
	add wr3,x
	st a, [UP0 + 6],y
	add #FLOOR_TILES
	st a, [DN0 + 6],y
	ld a, left + 4 * 20,y
	add wr4,x
	st a, [UP0 + 8],y
	add #FLOOR_TILES
	st a, [DN0 + 8],y
	ld a, left + 5 * 20,y
	add wr5,x
	st a, [UP0 + 10],y
	add #FLOOR_TILES
	st a, [DN0 + 10],y
@next:
	inc ray
	ld a, ray
	cmp #RAYS
	jz @show
	jmp @ray
@show:                      ; flip: show what was drawn, draw into the other half
	ld a, back
	jz @show0
	ld a, #128
	st a, SCROLLY
	ld a, #0
	st a, back
	ret
@show0:
	ld a, #0
	st a, SCROLLY
	ld a, #1
	st a, back
	ret

; Casts the ray at angle ra from the player. Returns in x the index into
; the tile tables: 32 * side + the wall's half height (htab, from hp).
cast:
	ld x, ra                ; the distances between cell edges, x and y
	ld a, ddl,x
	st a, ddxl
	ld a, ddh,x
	st a, ddxh
	ld a, ra
	sub #64
	mov x, a
	ld a, ddl,x
	st a, ddyl
	ld a, ddh,x
	st a, ddyh
	; the first x edge: the fraction of the cell ahead, times ddx
	ld a, ra
	add #64
	and #$80
	jnz @west
	ld a, #1
	st a, stepx
	ld a, px_l
	xor #$ff                ; 1 - fraction, near enough
	jr @fx
@west:
	ld a, #$ff
	st a, stepx
	ld a, px_l
@fx:
	st a, mb
	ld a, ddxl
	call mul8
	ld a, ph
	st a, sxl
	ld a, ddxh
	call mul8
	ld a, pl
	add sxl
	st a, sxl
	ld a, ph
	adc #0
	st a, sxh
	; the first y edge
	ld a, ra
	and #$80
	jnz @north
	ld a, #32
	st a, stepy
	ld a, #0
	st a, stepy+1
	ld a, py_l
	xor #$ff
	jr @fy
@north:
	ld a, #$e0
	st a, stepy
	ld a, #$ff
	st a, stepy+1
	ld a, py_l
@fy:
	st a, mb
	ld a, ddyl
	call mul8
	ld a, ph
	st a, syl
	ld a, ddyh
	call mul8
	ld a, pl
	add syl
	st a, syl
	ld a, ph
	adc #0
	st a, syh
	; the player's cell
	ld x, py_h
	ld a, maprow_l,x
	add px_h
	st a, mp
	ld a, maprow_h,x
	st a, mp+1
	ld y, #0
	; step to the nearer edge until a wall
@dda:
	ld a, sxh
	cmp syh
	jc @xstep
	jnz @ystep
	ld a, sxl
	cmp syl
	jc @xstep
@ystep:
	ld a, syl
	add ddyl
	st a, syl
	ld a, syh
	adc ddyh
	st a, syh
	ld a, mp
	add stepy
	st a, mp
	ld a, mp+1
	adc stepy+1
	st a, mp+1
	ld a, [mp],y
	cmp #EMPTY
	jz @dda
	ld a, #32               ; a y side: the dark one
	st a, side
	ld a, syl
	sub ddyl
	st a, dl
	ld a, syh
	sbc ddyh
	st a, dh
	jr @hit
@xstep:
	ld a, sxl
	add ddxl
	st a, sxl
	ld a, sxh
	adc ddxh
	st a, sxh
	ld a, mp                ; rows never cross a page: x stays in the low byte
	add stepx
	st a, mp
	ld a, [mp],y
	cmp #EMPTY
	jz @dda
	ld a, #0                ; an x side: the light one
	st a, side
	ld a, sxl
	sub ddxl
	st a, dl
	ld a, sxh
	sbc ddxh
	st a, dh
@hit:                       ; the distance in 1/16 cells, 255 at most
	ld a, dh
	cmp #16
	jc @near
	ld y, #255
	jr @height
@near:
	shl a
	shl a
	shl a
	shl a
	st a, tmp
	ld a, dl
	shr a
	shr a
	shr a
	shr a
	or tmp
	mov y, a
@height:
	ld a, [hp],y
	add side
	mov x, a
	ret

; ph:pl = A * mb, by quarter squares: (a + b)^2 / 4 - (a - b)^2 / 4.
mul8:
	st a, ma
	add mb
	mov x, a
	jc @big
	ld a, qsl0,x
	st a, pl
	ld a, qsh0,x
	st a, ph
	jr @diff
@big:
	ld a, qsl1,x
	st a, pl
	ld a, qsh1,x
	st a, ph
@diff:
	ld a, ma
	sub mb
	jnc @plus
	xor #$ff
	add #1
@plus:
	mov x, a
	ld a, pl
	sub qsl0,x
	st a, pl
	ld a, ph
	sbc qsh0,x
	st a, ph
	ret

; --- the status bar ---

hud_init:
	ld x, #0
	ld a, #SPACE
@clear:
	st a, VRAM,x
	inc x
	cmp x, #HUD_ROWS * 32
	jnz @clear
	ld x, #0
@title:
	ld a, txt_title,x
	jz @done
	add #FONT
	st a, VRAM + 32 + 1,x
	inc x
	jr @title
@done:
	ret

; Pictures a second: 60 over the frames the last one took.
hud_fps:
	ld x, frames
	ld a, fps_tens,x
	st a, VRAM + 32 + 13
	ld a, fps_ones,x
	st a, VRAM + 32 + 14
	ret

txt_title:
	.byte "RAYCASTER      FPS", 0   ; the count goes in the gap
fps_tens:
	.byte SPACE, FONT + '6', FONT + '3', FONT + '2', FONT + '1', FONT + '1', FONT + '1'
fps_ones:
	.byte SPACE, FONT + '0', FONT + '0', FONT + '0', FONT + '5', FONT + '2', FONT + '0'

; Where the rows of each half of the map are: six above the horizon (up
; from it), six below (down from it). The view is screen rows 3-14: map
; rows 3-14 in half 0, 19-30 in half 1 (SCROLLY 128).
rows_half0:
	.word VRAM + 8 * 32, VRAM + 7 * 32, VRAM + 6 * 32, VRAM + 5 * 32, VRAM + 4 * 32, VRAM + 3 * 32
	.word VRAM + 9 * 32, VRAM + 10 * 32, VRAM + 11 * 32, VRAM + 12 * 32, VRAM + 13 * 32, VRAM + 14 * 32
rows_half1:
	.word VRAM + 24 * 32, VRAM + 23 * 32, VRAM + 22 * 32, VRAM + 21 * 32, VRAM + 20 * 32, VRAM + 19 * 32
	.word VRAM + 25 * 32, VRAM + 26 * 32, VRAM + 27 * 32, VRAM + 28 * 32, VRAM + 29 * 32, VRAM + 30 * 32

nothing:
	reti

.include "raycast_tables.asm"

.section rom
.org $fffa
	.word nothing, reset, reset
