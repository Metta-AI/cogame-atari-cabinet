## The shipped board's TEXT, at full cap, asserted in Nim.
##
## The board bakes every string into a sprite with pixie (`global.textSprite`)
## and ships it over the sprite protocol, so a caption with nowhere to go is
## not a `fillText` at a negative coordinate — it is a sprite placed off the
## board, or on top of another sprite, drawn silently either way. The browser
## gate (`tools/ci/renderer_fixture.html`, run by `ci.yml`'s wasm-viewer job)
## renders the same frame through the real `client/broadcast_core.js`; this
## file asserts the geometry directly from the packet bytes, so a regression in
## `global.nim`'s bubble/chip placement is red in the `test` job too — with no
## browser, no bundle and no Docker.

import std/[strutils, unicode, unittest]
import cabinet/[sim, global]
import ../tools/ci/worst_case_frame

suite "board text":
  let frame = worstCaseFrame()
  let placements = textPlacements(frame.packet)

  test "the worst case really is the worst case":
    # A quietly shortened remark leaves every assertion below passing while
    # testing nothing (prompts/30-review-loop.md item 15).
    var bubbles = 0
    for placement in placements:
      let marker = placement.text.find(": ")
      if marker > 0:
        inc bubbles
        check placement.text[marker + 2 .. ^1].runeLen == MaxSayRunes
    check bubbles == MaxBubbles
    for seat in 0 ..< CabinetCount:
      check frame.sim.haveStance[seat]
      check frame.sim.stances[seat].note.runeLen == MaxNoteRunes
      check frame.sim.stances[seat].say.runeLen == MaxSayRunes

  test "every baked string is inside the board":
    check placements.len >= MaxBubbles + CabinetCount + 1
    for placement in placements:
      check placement.x >= 0
      check placement.y >= 0
      check placement.x + placement.width <= MapWidth
      check placement.y + placement.height <= MapHeight

  test "no two baked strings overlap":
    # Both inside the board and both unreadable: the failure mode a bounds
    # check alone cannot see.
    for i in 0 ..< placements.len:
      for j in i + 1 ..< placements.len:
        let a = placements[i]
        let b = placements[j]
        check not (a.x < b.x + b.width and b.x < a.x + a.width and
          a.y < b.y + b.height and b.y < a.y + a.height)

  test "the chrome JSON carries every seat's full-cap note":
    let chrome = chromeJson(frame.packet)
    check chrome.len > 0
    for seat in 0 ..< CabinetCount:
      check frame.sim.stances[seat].note in chrome
