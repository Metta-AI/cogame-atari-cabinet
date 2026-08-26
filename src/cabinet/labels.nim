## HUD label composition: the short strings the board draws next to a cabinet.
##
## In-game every cabinet is RED / BLUE / GREEN / YELLOW and NOTHING else. A
## real policy name never reaches this module — the two name spaces are
## enforced here by construction and asserted in tests/test_locality.nim.

import std/strutils
import sim, stances

proc cabinetLabel*(sim: SimServer, cabinet: int): string =
  ## The board label for one cabinet: its colour alias and its lives.
  if cabinet < 0 or cabinet >= CabinetCount:
    return ""
  if sim.cabinets[cabinet].isOut:
    return aliasOfCabinet(cabinet) & " OUT"
  aliasOfCabinet(cabinet) & " " & $int(sim.cabinets[cabinet].lives)

proc stanceChip*(stance: string, aimAt: string): string =
  ## `GUARD` / `AIM->BLUE` / `CAMP` / `CATCH` / `CHASE`.
  if stance.len == 0:
    return ""
  result = stance.toUpperAscii()
  if aimAt.len > 0 and aimAt != "none" and
      stance in ["aim", "chase", "catch"]:
    result.add("->" & aimAt.toUpperAscii())

proc scoreLabel*(sim: SimServer, cabinet: int): string =
  ## Three decimals, as the results document emits it.
  formatFloat(sim.scoreOf(cabinet), ffDecimal, 3)

proc feedLine*(sim: SimServer, view: StanceView): string =
  ## The plain-language match-feed line for one stance record — this is where
  ## a spectator sees the LLM playing.
  let alias = aliasOfCabinet(view.cabinet)
  case view.stance
  of "aim":
    alias & " lines up on " & view.aimAt
  of "catch":
    alias & " grips the ball for " & view.aimAt
  of "chase":
    alias & " chases everything at " & view.aimAt
  of "camp":
    alias & " camps the middle"
  else:
    alias & " guards its mouth"
