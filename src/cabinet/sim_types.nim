## THE CABINET — constants and types.
##
## Forked from `Metta-AI/coworld-ctf` (paintbot): the wall-clock-paced 24 Hz
## loop, the one-byte-per-seat-per-tick recorded action log, the replay codec
## wrapper and the `COGAME_*` runtime contract are all that repo's. The arena
## rules are this coworld's own (docs/plans/2026-08-26-atari-cabinet-design.md).
##
## DETERMINISM CONTRACT. Nim's `int` is 64-bit natively and 32-bit under
## `--cpu:wasm32`, and the SAME `sim.nim` is compiled both ways (native amd64
## in the game container, wasm32 in the replay viewer) with per-tick
## `gameHash` chains that must match bit-for-bit. So:
##
## * every stored sim field is explicitly `int32`, `int64`, `uint8`, `bool` or
##   an enum — no bare `int` in a hashed field;
## * every product or quotient of two sim quantities is computed in `int64`
##   and narrowed back with an explicit truncating `div`;
## * there is NO floating point in sim.nim / arena.nim / rom.nim / trig.nim /
##   sim_types.nim / sim_config.nim / sim_state.nim (grep-enforced,
##   tests/test_determinism.nim);
## * trigonometry is the committed `DirQ64` table in trig.nim — no `sqrt`, no
##   `sin`, no `arctan2` anywhere in the sim;
## * randomness is one seeded stream whose draw COUNT is hashed.

import std/[strutils]

const
  GameName* = "atari-cabinet"

  GameVersion* = "1"
    ## Replay compatibility gate. PREPEND-ONLY changelog, newest first, and
    ## every entry says what the number means:
    ##
    ## GV1 (cabinet rules): four sides, mouths, paddles as guns, three ROM
    ##   presets (warlords / quadrapong / foozpong), the 13-angle deflection
    ##   fan, integer µu physics and the 64-entry DirQ64 table.

  TargetFps* = 24
    ## Kept verbatim from the starter: every speed-coupled layer
    ## (PlaybackSpeeds, the lull scan, the momentum series, tickTime, the
    ## transport bar) is keyed to it.
  ReplayFps* = TargetFps
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]

  # ---- board render geometry -------------------------------------------------
  MapWidth* = 1000
  MapHeight* = 1000
  BoardUuPerPixel* = 1_000'i32
    ## 1 board pixel = 1 000 µu, so the 100.00 cu arena is 1000 x 1000 px.

  # ---- arena geometry (fixed; identical in every ROM and every episode) -----
  UuPerCu* = 10_000'i32
  ArenaSide* = 1_000_000'i32          ## 100.00 cu
  BallHalf* = 12_000'i32              ## the ball is an axis-aligned square
  PaddleDepth* = 140_000'i32
  PaddleThickHalf* = 8_000'i32
  FarPaddleDepth* = 340_000'i32
  PaddleTravelHalf* = 430_000'i32
  PaddleStepSpeed* = 4_000'i32        ## one drive level
  PaddleMaxSpeed* = 16_000'i32        ## level 4
  BrickRowDepthLo* = 80_000'i32
  BrickRowDepthHi* = 105_000'i32
  BrickRow2DepthLo* = 40_000'i32
  BrickRow2DepthHi* = 65_000'i32
  BricksPerRow* = 9
  MaxBrickRows* = 3
  BrickHalfWidth* = 18_000'i32
  BrickColumnStepCu* = 4              ## centres at along -16,-12,…,+16 cu
  BallSpeedStep* = 350'i32
  BallSpeedMax* = 13_000'i32
  ServeDelayTicks* = 24'i32
  HoldTicksMax* = 48'i32
  OutfanAngles* = 13
  MaxBalls* = 3
  CabinetCount* = 4
  MaxPlayers* = CabinetCount
  BallTrailLength* = 6

  MaxTicksDefault* = 2880
  DefaultTurnTicks* = 120
  DefaultTurnBudgetMs* = 16_000
  DefaultAttempt1Ms* = 9_000
  DefaultRetryMs* = 5_000
  DefaultTurnSpacingMs* = 12_000
  DefaultWallClockBudgetSeconds* = 660
  DefaultLobbyJoinTimeoutTicks* = 2880
  DefaultMaxOutputTokens* = 900
  DefaultStartWaitTicks* = 24
  DefaultGameOverTicks* = 48
  MinPlayersDefault* = 4

  # ---- string caps, all measured in RUNES -----------------------------------
  MaxNoteRunes* = 160
  MaxSayRunes* = 48
  MaxTargetBallRunes* = 4
  MaxAimAtRunes* = 8
  MaxPolicyLabelRunes* = 48
  MaxFallbackDetailRunes* = 200
  MaxStanceRecordRunes* = 600
  MaxPromptRunes* = 4000

  # ---- scoring weights (micro-points) ---------------------------------------
  LivesTermMicro* = 60_000_000'i64
  CrownMicro* = 15_000_000'i64
  KnockoutMicro* = 2_000_000'i64
  ChipMicro* = 500_000'i64
  SaveMicro* = 250_000'i64

  # ---- end reasons / rules (closed enums, mirrored in the manifest) ---------
  ReasonComplete* = "complete"
  ReasonDeadline* = "deadline"
  ReasonFault* = "fault"
  EndRuleLastStanding* = "last_standing"
  EndRuleFullTime* = "full_time"
  EndRuleWallClock* = "wall_clock"
  EndRuleSimFault* = "sim_fault"
  EndRuleHostError* = "host_error"

  RomWarlords* = "warlords"
  RomQuadrapong* = "quadrapong"
  RomFoozpong* = "foozpong"
  RomNames* = [RomWarlords, RomQuadrapong, RomFoozpong]

  # ---- websocket routes (the starter's) ------------------------------------
  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"
  RewardWebSocketPath* = "/reward"

  # ---- board art ------------------------------------------------------------
  FontPath* = "data/font.ttf"
  DarkBgPath* = "data/darkbg.aseprite"
  ArenaFloorPath* = "data/arena_floor.png"
  WallHorizontalPath* = "client/art/walls/wall_h.jpg"
  WallVerticalPath* = "client/art/walls/wall_v.jpg"
  HeartPaths* = [
    "data/heart_red.png", "data/heart_blue.png",
    "data/heart_green.png", "data/heart_yellow.png"
  ]

  CabinetAliases* = ["RED", "BLUE", "GREEN", "YELLOW"]
    ## The in-game name of a station on the board. NEVER an entrant: real
    ## policy names live only in the replay config JSON, the roster rows, the
    ## DOM scorebug/endcard and results.names (tests/test_locality.nim).
  CabinetTeamKeys* = ["red", "blue", "green", "yellow"]
    ## chrome_common.js pins TEAM_ORDER = ['red','blue','green','yellow'] and
    ## seats 0/2 left of the clock, 1/3 right — so the four plates come out
    ## RED + GREEN | clock | BLUE + YELLOW with no chrome edit at all.
  CabinetSideNames* = ["SOUTH", "EAST", "NORTH", "WEST"]

type
  CabinetError* = object of CatchableError
  SimGuardError* = object of CabinetError
    ## A step-7 invariant guard tripped: the episode ends fault/sim_fault with
    ## a partial replay, never a silent non-zero exit.

  GamePhase* = enum
    Lobby
    Playing
    GameOver

  BallState* = enum
    bsServing = "serving"
    bsLive = "live"
    bsHeld = "held"

  RngState* = object
    ## One seeded stream. `next` works in the uint64 domain so a draw is
    ## identical on wasm32 (32-bit `int`) and amd64 (64-bit `int`) — the
    ## starter's documented hazard with `rand(int)`. Rolled here rather than
    ## reusing std/random's `Rand` only because `Rand`'s fields are private
    ## and the flatty keyframe pass has to see them.
    s0*, s1*: uint64

  Ball* = object
    state*: BallState
    x*, y*: int32            ## centre in µu, origin top-left, y DOWN
    dir*: uint8              ## 1/64 turn index into DirQ64
    speed*: int32            ## µu per tick
    lastTouch*: int32        ## cabinet index whose paddle touched it last, -1
    holdTicks*: int32
    serveTimer*: int32
    heldBy*: int32           ## cabinet index gripping it, -1
    trailX*, trailY*: array[BallTrailLength, int32]
      ## presentation only (never hashed): the motion trail the board draws.
    trailLen*: int32

  Cabinet* = object
    lives*: int32
    isOut*: bool
    outTick*: int32
    alongCentre*: int32      ## near paddle centre, along-units in µu
    paddleVel*: int32        ## the APPLIED delta (the deflection fan reads it)
    farAlongCentre*: int32
    farPaddleVel*: int32
    heldBall*: int32
    bricks*: array[MaxBrickRows, array[BricksPerRow, bool]]
    saves*, chips*, knockouts*, concedes*, catches*: int32
    scoreMicro*: int64
    placement*: int32
    nearMisses*: int32       ## PRESENTATION ONLY: never mixed into gameHash
    lastNearMissBall*: int32 ## the ball that grazed the bar, for the feed line

  Player* = object
    ## One SEAT. A seat is not a cabinet: seat `s` drives cabinet `perm[s]`.
    address*: string         ## the REAL policy name (spectator side only)
    token*: string
    joinOrder*: int
    reward*: int

  PlayerSlotConfig* = object
    name*: string
    token*: string
    alias*: string           ## cosmetic; the played alias is perm-dealt at t=0

  RewardAccount* = object
    address*: string
    slot*: int
    reward*: int
    games*: int
    wins*: int

  GameConfig* = object
    seed*: int
    speed*: int
    numAgents*: int
    minPlayers*: int
    maxTicks*: int
    maxGames*: int
    startWaitTicks*: int
    gameOverTicks*: int
    lobbyJoinTimeoutTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    closedRoster*: bool
    slots*: seq[PlayerSlotConfig]
    # the decision layer
    turnTicks*: int
    turnBudgetMs*: int
    attempt1Ms*: int
    retryMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    model*: string
    maxOutputTokens*: int
    # the ROM preset (rom.nim applies it between defaults and explicit keys)
    rom*: string
    startingLives*: int
    ballCount*: int
    brickRows*: int
    catchEnabled*: bool
    farPaddle*: bool
    goalHalfCu*: int
    paddleHalfCu*: int
    farPaddleHalfCu*: int
    ballSpeed0Milli*: int
    ballSpeedStepMilli*: int
    ballSpeedMaxMilli*: int
    holdTicksMax*: int
    serveDelayTicks*: int

  SimEventKind* = enum
    Serve
    Save
    Chip
    Breach
    WallDown
    Catch
    Release
    Concede
    Eliminated
    NearMiss
    StanceSet
    PhaseChange
    LastStanding

  SimEvent* = object
    ## The tier-2 analysis event. Never enters `gameHash`.
    tick*: int
    kind*: SimEventKind
    cabinet*: int
    by*: int
    ball*: int
    amount*: int
    detail*: string
    x*, y*: int

  StanceView* = object
    ## The NON-HASHED presentation copy of a seat's standing stance: what the
    ## scorebug, the aim rays and the feed read. Re-applied at playback from
    ## the replay's `stance` chat records, exactly as the starter re-applies
    ## its directive records.
    turn*: int
    seat*: int
    cabinet*: int
    source*: string
    stance*: string
    targetBall*: string
    aimAt*: string
    postMilliCu*: int          ## thousandths of a cabinet unit
    leadTicks*: int
    aggression255*: int        ## 0..255, as the stance quantises it
    note*: string
    say*: string
    sayUntil*: int

proc aliasOfCabinet*(cabinet: int): string =
  ## The in-game colour alias of one cabinet index.
  if cabinet < 0 or cabinet >= CabinetCount:
    return "NONE"
  CabinetAliases[cabinet]

proc cabinetOfAlias*(alias: string): int =
  ## The cabinet index for a colour alias, or -1.
  let key = alias.strip().toUpperAscii()
  for i, name in CabinetAliases:
    if name == key:
      return i
  -1

proc teamKeyOfCabinet*(cabinet: int): string =
  if cabinet < 0 or cabinet >= CabinetCount:
    return ""
  CabinetTeamKeys[cabinet]

proc sideNameOfCabinet*(cabinet: int): string =
  if cabinet < 0 or cabinet >= CabinetCount:
    return ""
  CabinetSideNames[cabinet]
