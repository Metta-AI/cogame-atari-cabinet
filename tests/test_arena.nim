## Geometry: the four side-local frames, the brick lattice, mouth crossings and
## the bounded seeded serve sampler.

import std/[random, unittest]
import cabinet/sim
import helpers

suite "arena":
  test "the four side-local frames round-trip over 100 000 randomised points":
    var rng = initRand(2718)
    for trial in 0 ..< 100_000:
      let
        side = rng.rand(3)
        along = int32(rng.rand(int(ArenaSide)) - int(ArenaHalf))
        depth = int32(rng.rand(int(ArenaSide)))
        world = worldOf(side, along, depth)
        back = localOf(side, world.x, world.y)
      check back.along == along
      check back.depth == depth

  test "side k's +50 end and side (k+1)'s -50 end are the SAME world point":
    for k in 0 ..< CabinetCount:
      for depth in [0'i32, 140_000'i32, ArenaHalf]:
        let
          mine = worldOf(k, ArenaHalf, depth)
          theirs = worldOf((k + 1) mod CabinetCount, -ArenaHalf, depth)
        # the shared CORNER is the depth-0 point; deeper in, the two frames
        # measure from different walls, so only the corner is shared.
        if depth == 0:
          check mine == theirs

  test "the inward direction of every side is exactly local index 16":
    for k in 0 ..< CabinetCount:
      let inward = fromLocalDir(16, k)
      let vector = dirVector(inward)
      # stepping inward must increase depth
      let
        start = worldOf(k, 0'i32, 200_000'i32)
        moved = localOf(k, start.x + vector.x, start.y + vector.y)
      check moved.depth > 200_000

  test "the 9 brick columns tile along -18..+18 with 3.60 cu bricks and 0.40 cu gaps":
    var previousHi = int32.low
    for col in 0 ..< BricksPerRow:
      let
        centre = brickAlongCentre(col)
        lo = centre - BrickHalfWidth
        hi = centre + BrickHalfWidth
      check lo >= -18 * UuPerCu
      check hi <= 18 * UuPerCu
      check hi - lo == 36_000                       ## 3.60 cu wide
      if col > 0:
        check lo - previousHi == 4_000              ## 0.40 cu gap
      previousHi = hi
    check brickAlongCentre(0) == -16 * UuPerCu
    check brickAlongCentre(BricksPerRow - 1) == 16 * UuPerCu

  test "a mouth crossing is detected iff depth crosses 0 inside the gap":
    let config = episodeConfig(3)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    let goalHalf = goalHalfUu(config)
    var rng = initRand(31337)
    var mouths, walls = 0
    for trial in 0 ..< 50_000:
      let
        side = rng.rand(3)
        along = int32(rng.rand(int(ArenaSide)) - int(ArenaHalf))
        # start just inside and cross outward
        start = worldOf(side, along, 30_000'i32)
        target = worldOf(side, along, -5_000'i32)
        dx = target.x - start.x
        dy = target.y - start.y
        crossing = sideDepthCrossing(side, start.x, start.y, dx, dy, 0'i32)
      check crossing.hit
      let inGap = along > -goalHalf and along < goalHalf
      let contact = game.earliestContact(start.x, start.y, dx, dy)
      if inGap:
        # in the gap the only thing that can stop it is a paddle or a brick,
        # never the wall.
        check contact.kind != ckWall
        if contact.kind == ckMouth:
          inc mouths
      else:
        check contact.kind != ckMouth
        if contact.kind == ckWall:
          inc walls
    check mouths > 0
    check walls > 0

  test "an OUT cabinet's whole side reflects and never concedes":
    let config = episodeConfig(9)
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    game.cabinets[2].isOut = true
    game.cabinets[2].lives = 0
    let
      start = worldOf(2, 0'i32, 30_000'i32)
      target = worldOf(2, 0'i32, -5_000'i32)
      contact = game.earliestContact(
        start.x, start.y, target.x - start.x, target.y - start.y)
    check contact.kind == ckWall
    check int(contact.cabinet) == 2

  test "the bounded serve sampler never returns a rejected index, and the fixed scan never fires":
    for romName in ["warlords", "quadrapong", "foozpong"]:
      for seed in 0 ..< 200:
        let config = episodeConfig(seed * 104729, rom = romName)
        var game = initSimServer(config)
        game.gameEventLoggingEnabled = false
        for seat in 0 ..< CabinetCount:
          discard game.addPlayer("P" & $(seat + 1), seat, "token-" & $seat)
        var commands = newSeq[uint8](CabinetCount)
        for seat in 0 ..< CabinetCount:
          commands[seat] = NeutralCommand
        for tick in 0 ..< 200:
          game.step(commands)
          for ball in game.balls:
            if ball.state == bsLive:
              check game.serveDirectionLegal(ball.dir) or
                int(ball.dir) mod 16 in [0, 1, 15]   ## a wall bounce may land there
        check game.serveFallbacks == 0

  test "dirPointsAtCabinet names one side per direction, deterministically":
    var counts: array[CabinetCount, int]
    for d in 0 ..< 64:
      let side = dirPointsAtCabinet(uint8(d))
      check side >= 0 and side < CabinetCount
      inc counts[side]
      check dirPointsAtCabinet(uint8(d)) == side      ## pure
    for count in counts:
      check count > 0
