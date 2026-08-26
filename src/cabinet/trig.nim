## The committed direction table: the whole of this game's trigonometry.
##
## Entry `d` is the view bearing `5.625 deg * d` counter-clockwise from east,
## expressed in SIM (y-DOWN) components and scaled Q12 (4096 = 1.0), so the
## sim never negates anything at a call site. Generated once by
## tools/gen_trig_table.nim and checked in; tests/test_determinism.nim
## re-derives every entry from math.cos / math.sin.
##
## Because 64 is divisible by 4 every reflection and every side rotation is
## EXACT index arithmetic, so the sim needs no square root and no
## trigonometry whatsoever:
##
##   off a VERTICAL surface   (x negated): d' = (32 - d) mod 64
##   off a HORIZONTAL surface (y negated): d' = (64 - d) mod 64
##   into side k's local frame:            dl = (d - 16*k) mod 64
##   back out of it:                       d  = (dl + 16*k) mod 64
##
## NO FLOATING POINT IN THIS FILE (grep-enforced, tests/test_determinism.nim).

const
  DirCount* = 64
  DirQ12One* = 4096'i32
  DirDegreesPerIndexMilli* = 5_625
    ## 5.625 degrees per index, in thousandths, so the doc value stays integer.

  DirQ64*: array[DirCount, tuple[x, y: int32]] = [
  (x:   4096'i32, y:      0'i32), (x:   4076'i32, y:   -401'i32), (x:   4017'i32, y:   -799'i32), (x:   3920'i32, y:  -1189'i32),
  (x:   3784'i32, y:  -1567'i32), (x:   3612'i32, y:  -1931'i32), (x:   3406'i32, y:  -2276'i32), (x:   3166'i32, y:  -2598'i32),
  (x:   2896'i32, y:  -2896'i32), (x:   2598'i32, y:  -3166'i32), (x:   2276'i32, y:  -3406'i32), (x:   1931'i32, y:  -3612'i32),
  (x:   1567'i32, y:  -3784'i32), (x:   1189'i32, y:  -3920'i32), (x:    799'i32, y:  -4017'i32), (x:    401'i32, y:  -4076'i32),
  (x:      0'i32, y:  -4096'i32), (x:   -401'i32, y:  -4076'i32), (x:   -799'i32, y:  -4017'i32), (x:  -1189'i32, y:  -3920'i32),
  (x:  -1567'i32, y:  -3784'i32), (x:  -1931'i32, y:  -3612'i32), (x:  -2276'i32, y:  -3406'i32), (x:  -2598'i32, y:  -3166'i32),
  (x:  -2896'i32, y:  -2896'i32), (x:  -3166'i32, y:  -2598'i32), (x:  -3406'i32, y:  -2276'i32), (x:  -3612'i32, y:  -1931'i32),
  (x:  -3784'i32, y:  -1567'i32), (x:  -3920'i32, y:  -1189'i32), (x:  -4017'i32, y:   -799'i32), (x:  -4076'i32, y:   -401'i32),
  (x:  -4096'i32, y:      0'i32), (x:  -4076'i32, y:    401'i32), (x:  -4017'i32, y:    799'i32), (x:  -3920'i32, y:   1189'i32),
  (x:  -3784'i32, y:   1567'i32), (x:  -3612'i32, y:   1931'i32), (x:  -3406'i32, y:   2276'i32), (x:  -3166'i32, y:   2598'i32),
  (x:  -2896'i32, y:   2896'i32), (x:  -2598'i32, y:   3166'i32), (x:  -2276'i32, y:   3406'i32), (x:  -1931'i32, y:   3612'i32),
  (x:  -1567'i32, y:   3784'i32), (x:  -1189'i32, y:   3920'i32), (x:   -799'i32, y:   4017'i32), (x:   -401'i32, y:   4076'i32),
  (x:      0'i32, y:   4096'i32), (x:    401'i32, y:   4076'i32), (x:    799'i32, y:   4017'i32), (x:   1189'i32, y:   3920'i32),
  (x:   1567'i32, y:   3784'i32), (x:   1931'i32, y:   3612'i32), (x:   2276'i32, y:   3406'i32), (x:   2598'i32, y:   3166'i32),
  (x:   2896'i32, y:   2896'i32), (x:   3166'i32, y:   2598'i32), (x:   3406'i32, y:   2276'i32), (x:   3612'i32, y:   1931'i32),
  (x:   3784'i32, y:   1567'i32), (x:   3920'i32, y:   1189'i32), (x:   4017'i32, y:    799'i32), (x:   4076'i32, y:    401'i32)
  ]

proc reflectVertical*(dir: uint8): uint8 =
  ## Off a vertical surface: the x-component is negated.
  uint8((32 - int(dir) + 64) mod 64)

proc reflectHorizontal*(dir: uint8): uint8 =
  ## Off a horizontal surface: the y-component is negated.
  uint8((64 - int(dir)) mod 64)

proc toLocalDir*(dir: uint8, side: int): uint8 =
  ## Into side `k`'s local direction frame.
  uint8(((int(dir) - 16 * side) mod 64 + 64) mod 64)

proc fromLocalDir*(localDir: int, side: int): uint8 =
  ## Back out of side `k`'s local direction frame.
  uint8(((localDir + 16 * side) mod 64 + 64) mod 64)

proc dirVector*(dir: uint8): tuple[x, y: int32] =
  ## The Q12 unit vector of one direction index, in sim (y-down) components.
  DirQ64[int(dir) and 63]
