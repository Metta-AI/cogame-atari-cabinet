## The board: top-down sprite composition for the CRT arena.
##
## Replaces the starter's `global.nim` wholesale — fog of war, vision cones,
## the first-person raycast, item sprites and the killfeed art are DELETED, not
## disabled: the cabinet is a CRT and the physics is public (design §Out of
## scope). What is kept is the starter's WIRE: bitworld's Sprite v1 protocol
## (layer + viewport + sprite definitions + object placements), the reserved
## chrome sprite whose LABEL carries the broadcast JSON, the per-viewer
## "only send what changed" discipline, and the WS-frame chunker.
##
## The art is REAL and baked once at startup with pixie from what the repo
## ships: `data/darkbg.aseprite` and `data/arena_floor.png` for the phosphor
## plate, `client/art/walls/wall_h.jpg` / `wall_v.jpg` for the four tinted
## walls, `data/font.ttf` for every label. No placeholders, no downloads.

import std/[math, os, sets, strutils, tables]
import pixie
import bitworld/[aseprite, spriteprotocol]
import sim

const
  BroadcastChromeSpriteId* = 4090
    ## The reserved never-drawn 1x1 sprite whose LABEL carries the broadcast
    ## chrome JSON on the binary channel — the ONLY channel that survives a
    ## hosted replay. broadcast_core.js routes it to onText and never
    ## registers it as a drawable.
  BoardLayer* = 0
  RenderScale* {.intdefine.} = 1
    ## Board pixels per logical map pixel. The arena is FIXED at 1000 x 1000
    ## logical pixels (1 px = 1 000 µu = 0.10 cu), which is already fine
    ## enough for a 1.2 cu ball, so this game renders at 1x rather than the
    ## starter's supersampled 2x.
  MaxSupersampledMapPixels* {.intdefine.} = 8_000_000
  WasmViewerBudgetBytes* = 1_600_000_000
  ShotFxTicks* = 6
  TrailFalloff* = 1.6

  BandCount = 10
  BandSpriteBase = 30
  BandObjectBase = 40          ## broadcast_core.js caches ids 40..99 at
                               ## z = -32768 as the static board base.
  StaticBandZ = -32768
  MouthSpriteBase = 120
  MouthObjectBase = 130
  BrickSpriteBase = 140        ## 4 cabinets x 2 states
  BrickObjectBase = 200        ## 4 x MaxBrickRows x BricksPerRow
  PaddleSpriteBase = 340       ## 4 cabinets x {near, far}
  PaddleObjectBase = 400
  BallSpriteBase = 420         ## 1 head + BallTrailLength fades
  BallObjectBase = 500
  RaySpriteBase = 460
  RayObjectBase = 700
  RayDashes = 14
  FxSpriteBase = 470
  FxObjectBase = 1000
  TextSpriteBase* = 2000       ## rotating pool for baked strings
  TextSpritePool* = 64
    ## Exported so the text gates can tell a BAKED STRING from a wall: the
    ## board draws every label as a sprite, so `tools/ci/worst_case_frame.nim`
    ## and the renderer fixture find the drawn text by this id range rather
    ## than by guessing at labels.
  ChipObjectBase = 1100
  BubbleObjectBase = 1200
  ScoreObjectBase = 1300
  MaxBubbles* = 3
  BubbleBandLoCu* = 92
  BubbleBandHiCu* = 99
    ## Speech bubbles live in a RESERVED band across the top of the board and
    ## are never positioned relative to a paddle: a caption laid out relative
    ## to a moving object is exactly how text ends up drawn at a negative
    ## coordinate and clipped to a sliver, which a canvas accepts silently
    ## (cogchemists, 2026-08-24). `viewer_smoke.mjs --strict-text-bounds`
    ## gates it.

type
  GlobalViewerState* = object
    ## Per-viewer wire state: which sprite ids this socket has already been
    ## given, where every object was last placed, and the one-shot inputs the
    ## websocket thread collected since the last frame.
    sentSprites*: HashSet[int]
    sentObjects*: Table[int, array[5, int]]
    layersSent*: bool
    momentumSent*: bool
    replayCommands*: seq[char]
    replaySeekTick*: int
    mouseX*, mouseY*, mouseLayer*: int
    mouseDown*: bool
    clickPending*: bool
    povSelectPending*: int
    selectedJoinOrder*: int

  PlayerViewerState* = ref object
    ## A seat's own stream state. Seats send NO inputs (the server computes
    ## every command byte), so this only tracks the sprite/object wire.
    sentSprites*: HashSet[int]
    sentObjects*: Table[int, array[5, int]]
    layersSent*: bool

proc initGlobalViewerState*(): GlobalViewerState =
  result.sentSprites = initHashSet[int]()
  result.sentObjects = initTable[int, array[5, int]]()
  result.replaySeekTick = -1
  result.povSelectPending = -2
  result.selectedJoinOrder = -1

proc initPlayerViewerState*(): PlayerViewerState =
  result = PlayerViewerState(
    sentSprites: initHashSet[int](),
    sentObjects: initTable[int, array[5, int]]())

proc boardRenderScaleFor*(mapWidth, mapHeight: int): int =
  ## Kept as a named function so the capacity preflight below reads the same
  ## as the starter's. A board this size always renders at RenderScale.
  if mapWidth * mapHeight * RenderScale * RenderScale > MaxSupersampledMapPixels:
    1
  else:
    RenderScale

proc predictedViewerRenderBytes*(mapWidth, mapHeight: int): int64 =
  ## The load-time capacity preflight the wasm viewer runs BEFORE baking, so
  ## an oversized board gets a clean diagnostic instead of an OOM abort.
  let scale = boardRenderScaleFor(mapWidth, mapHeight)
  int64(mapWidth) * int64(mapHeight) * 4'i64 *
    (4'i64 * int64(scale * scale) + 6'i64)

# ---------------------------------------------------------------------------
#  Palette
# ---------------------------------------------------------------------------

const CabinetTint*: array[CabinetCount, array[3, uint8]] = [
  [224'u8, 82'u8, 58'u8],
  [63'u8, 124'u8, 196'u8],
  [69'u8, 168'u8, 94'u8],
  [221'u8, 197'u8, 49'u8]
]  ## red, blue, green, yellow — the same hues chrome_common.js uses.

proc gameDir*(): string =
  ## Where `data/` lives. The container runs from /workspace/cabinet and the
  ## emscripten bundle preloads `data@data`, so the relative path serves both;
  ## a test run from the repo root also finds it.
  if dirExists("data"): return "."
  if dirExists(".." / "data"): return ".."
  getCurrentDir()

# ---------------------------------------------------------------------------
#  Baking
# ---------------------------------------------------------------------------

var
  typefaceCache: Typeface
  textCache: Table[string, tuple[width, height: int, pixels: seq[uint8]]]
  bandCache: seq[seq[uint8]]
  bakedBands = false

proc boardTypeface(): Typeface =
  if typefaceCache.isNil:
    typefaceCache = readTypeface(gameDir() / FontPath)
  typefaceCache

proc straightRgba(image: Image): seq[uint8] =
  ## Straight-alpha RGBA bytes for Sprite v1 (pixie stores premultiplied).
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let c = image.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc textSprite*(
  text: string, r, g, b: uint8, pixelHeight: int
): tuple[width, height: int, pixels: seq[uint8]] =
  ## One baked label: the board face with a soft dark drop shadow so thin
  ## strokes stay legible over the phosphor plate. Cached by (text, colour,
  ## size) — labels are re-emitted every frame and must not re-rasterize.
  let key = text & "\x1f" & $r & "," & $g & "," & $b & "," & $pixelHeight
  if textCache.hasKey(key):
    return textCache[key]
  let font = newFont(boardTypeface())
  font.size = float32(pixelHeight)
  font.lineHeight = float32(pixelHeight) * 1.2
  let
    bounds = font.layoutBounds(text)
    width = max(1, int(ceil(bounds.x)) + 4)
    height = max(1, int(ceil(font.lineHeight)) + 2)
  var image = newImage(width, height)
  font.paint = newPaint(SolidPaint)
  font.paint.color = color(0, 0, 0, 0.75)
  image.fillText(font, text, translate(vec2(2.5, 1.5)))
  font.paint = newPaint(SolidPaint)
  font.paint.color = color(
    float32(r) / 255, float32(g) / 255, float32(b) / 255, 1)
  image.fillText(font, text, translate(vec2(2, 1)))
  if textCache.len > 2048:
    textCache.clear()
  result = (width, height, straightRgba(image))
  textCache[key] = result

proc bakeBoardPlate(): Image =
  ## The CRT: a dark phosphor plate from `data/darkbg.aseprite` tiled under
  ## `data/arena_floor.png`, a bright scanline overlay, a corner vignette, and
  ## the four walls from the shipped wall JPEGs tinted per cabinet with a
  ## glowing lip at each mouth.
  let
    side = MapWidth
    dir = gameDir()
  result = newImage(side, side)
  result.fill(rgba(6, 8, 10, 255))
  # phosphor plate
  try:
    let dark = readAsepriteImage(dir / DarkBgPath)
    var y = 0
    while y < side:
      var x = 0
      while x < side:
        result.draw(dark, translate(vec2(float32(x), float32(y))), NormalBlend)
        x += dark.width
      y += dark.height
  except CatchableError:
    discard
  try:
    let floorTex = readImage(dir / ArenaFloorPath)
    let faded = newImage(floorTex.width, floorTex.height)
    faded.draw(floorTex)
    var y = 0
    while y < side:
      var x = 0
      while x < side:
        faded.draw(newImage(1, 1))
        result.draw(faded, translate(vec2(float32(x), float32(y))), NormalBlend)
        x += faded.width
      y += faded.height
  except CatchableError:
    discard
  # knock the whole plate down so it reads as unlit phosphor
  let wash = newImage(side, side)
  wash.fill(rgba(4, 6, 9, 170))
  result.draw(wash, translate(vec2(0, 0)), NormalBlend)
  # scanlines
  let scan = newImage(side, 1)
  scan.fill(rgba(0, 0, 0, 60))
  var line = 0
  while line < side:
    result.draw(scan, translate(vec2(0, float32(line))), NormalBlend)
    line += 3
  # walls, tinted per cabinet, with the mouth left dark
  proc wallImage(horizontal: bool): Image =
    try:
      readImage(dir / (if horizontal: WallHorizontalPath else: WallVerticalPath))
    except CatchableError:
      let fallback = newImage(64, 64)
      fallback.fill(rgba(70, 62, 52, 255))
      fallback
  let
    wallH = wallImage(true)
    wallV = wallImage(false)
    thickness = 24
  for k in 0 ..< CabinetCount:
    let tint = CabinetTint[k]
    let horizontal = sideIsHorizontal(k)
    var strip = newImage(
      if horizontal: side else: thickness,
      if horizontal: thickness else: side)
    let source = if horizontal: wallH else: wallV
    var y = 0
    while y < strip.height:
      var x = 0
      while x < strip.width:
        strip.draw(source, translate(vec2(float32(x), float32(y))), NormalBlend)
        x += source.width
      y += source.height
    let tintLayer = newImage(strip.width, strip.height)
    tintLayer.fill(rgba(tint[0], tint[1], tint[2], 110))
    strip.draw(tintLayer, translate(vec2(0, 0)), NormalBlend)
    let at =
      case k
      of 0: vec2(0, float32(side - thickness))
      of 1: vec2(float32(side - thickness), 0)
      of 2: vec2(0, 0)
      else: vec2(0, 0)
    result.draw(strip, translate(at), NormalBlend)
  # a corner vignette
  let vignette = newImage(side, side)
  for y in 0 ..< side:
    for x in 0 ..< side:
      let
        dx = float(x - side div 2) / float(side div 2)
        dy = float(y - side div 2) / float(side div 2)
        d = min(1.0, sqrt(dx * dx + dy * dy))
        a = uint8(min(180.0, d * d * 190.0))
      vignette.data[y * side + x] = rgba(0, 0, 0, a).rgbx()
  result.draw(vignette, translate(vec2(0, 0)), NormalBlend)

proc bakeBands() =
  ## The static plate, split into `BandCount` horizontal bands so
  ## broadcast_core.js's static-band cache (object ids 40..99 at
  ## z = -32768) blits them once instead of per frame.
  if bakedBands:
    return
  bakedBands = true
  let plate = bakeBoardPlate()
  let bandHeight = MapHeight div BandCount
  bandCache = @[]
  for band in 0 ..< BandCount:
    let strip = newImage(MapWidth, bandHeight)
    strip.draw(plate, translate(vec2(0, -float32(band * bandHeight))))
    bandCache.add(straightRgba(strip))

proc warmBoardRenderCaches*(sim: SimServer) =
  ## Bake every board cache BEFORE the listener opens: a viewer's first-message
  ## clock starts at its successful connect, so nothing may be accepted until
  ## every frame the loop will ever build can be assembled instantly.
  bakeBands()
  discard textSprite("WARM", 255, 255, 255, 18)

proc invalidateBoardMapCaches*() =
  bakedBands = false
  bandCache = @[]
  textCache.clear()

# ---------------------------------------------------------------------------
#  Small procedural sprites (tinted rectangles, rings and squares)
# ---------------------------------------------------------------------------

proc solidSprite(
  width, height: int, r, g, b, a: uint8, edge = 0'u8
): seq[uint8] =
  result = newSeq[uint8](width * height * 4)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let
        o = (y * width + x) * 4
        border = x < 2 or y < 2 or x >= width - 2 or y >= height - 2
      result[o] = if border and edge > 0: edge else: r
      result[o + 1] = if border and edge > 0: edge else: g
      result[o + 2] = if border and edge > 0: edge else: b
      result[o + 3] = a

proc hatchSprite(width, height: int, r, g, b: uint8): seq[uint8] =
  ## The welded plate over a dead cabinet's mouth: an X-hatch, so "out" reads
  ## as a decision rather than a missing wall.
  result = newSeq[uint8](width * height * 4)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let o = (y * width + x) * 4
      let on = ((x + y) mod 12 < 3) or ((x - y + height) mod 12 < 3)
      result[o] = r
      result[o + 1] = g
      result[o + 2] = b
      result[o + 3] = if on: 235'u8 else: 90'u8

# ---------------------------------------------------------------------------
#  Wire helpers
# ---------------------------------------------------------------------------

proc uuToPx(value: int32): int =
  int(value div BoardUuPerPixel)

proc boardPoint(x, y: int32): tuple[px, py: int] =
  ## World µu -> board pixels. The board keeps the sim's y-DOWN screen
  ## convention, so nothing has to flip.
  (uuToPx(x), uuToPx(y))

template emitSprite(
  packet: var seq[uint8], sent: var HashSet[int], id: int,
  width, height: int, pixels: seq[uint8], label = ""
) =
  if id notin sent:
    sent.incl(id)
    packet.addSprite(id, width, height, pixels, label)

template emitObject(
  packet: var seq[uint8], placed: var Table[int, array[5, int]],
  id, x, y, z, layer, spriteId: int
) =
  let key = [x, y, z, layer, spriteId]
  if not placed.hasKey(id) or placed[id] != key:
    placed[id] = key
    packet.addObject(id, x, y, z, layer, spriteId)

template dropObject(
  packet: var seq[uint8], placed: var Table[int, array[5, int]], id: int
) =
  if placed.hasKey(id):
    placed.del(id)
    packet.addDeleteObject(id)

proc chunkSpritePacket*(packet: seq[uint8], maxBytes: int): seq[seq[uint8]] =
  ## Splits one packet at MESSAGE boundaries so no websocket frame exceeds the
  ## hosted replay's 1 MiB cap. The client accumulates sprite/object state
  ## across binary messages, so N chunks are equivalent to one packet.
  if packet.len <= maxBytes:
    return @[packet]
  var
    offset = 0
    chunk: seq[uint8]
  while offset < packet.len:
    let start = offset
    let kind = packet[offset]
    inc offset
    case kind
    of 0x01:
      let compressed = packet.readU32(offset + 6)
      offset += 10 + compressed
      let labelLen = packet.readU16(offset)
      offset += 2 + labelLen
    of 0x02: offset += 11
    of 0x03: offset += 2
    of 0x04: discard
    of 0x05: offset += 5
    of 0x06: offset += 3
    else:
      # Unknown message: its length is unknowable, so ship the remainder whole.
      offset = packet.len
    if chunk.len > 0 and chunk.len + (offset - start) > maxBytes:
      result.add(chunk)
      chunk = @[]
    for i in start ..< offset:
      chunk.add(packet[i])
  if chunk.len > 0:
    result.add(chunk)

# ---------------------------------------------------------------------------
#  The board packet
# ---------------------------------------------------------------------------

proc addBoard(
  sim: SimServer,
  packet: var seq[uint8],
  sent: var HashSet[int],
  placed: var Table[int, array[5, int]],
  layersSent: var bool
) =
  bakeBands()
  if not layersSent:
    layersSent = true
    packet.addLayer(BoardLayer, SpriteLayerMap, SpriteLayerZoomableFlag)
  packet.addViewport(BoardLayer, MapWidth, MapHeight)

  # --- the static plate ----------------------------------------------------
  let bandHeight = MapHeight div BandCount
  for band in 0 ..< BandCount:
    emitSprite(packet, sent, BandSpriteBase + band, MapWidth, bandHeight,
      bandCache[band], "board band " & $band)
    emitObject(packet, placed, BandObjectBase + band, 0, band * bandHeight,
      StaticBandZ, BoardLayer, BandSpriteBase + band)

  # --- mouths (a dark gap with a glowing lip; welded shut when out) --------
  let
    goalHalf = goalHalfUu(sim.config)
    goalPx = max(4, uuToPx(goalHalf) * 2)
    lipThickness = 26
  for k in 0 ..< CabinetCount:
    let tint = CabinetTint[k]
    let horizontal = sideIsHorizontal(k)
    let
      width = if horizontal: goalPx else: lipThickness
      height = if horizontal: lipThickness else: goalPx
    emitSprite(packet, sent, MouthSpriteBase + k, width, height,
      solidSprite(width, height, 10, 12, 16, 235,
        edge = uint8(max(tint[0], max(tint[1], tint[2])))),
      "mouth " & aliasOfCabinet(k))
    emitSprite(packet, sent, MouthSpriteBase + 4 + k, width, height,
      hatchSprite(width, height, tint[0], tint[1], tint[2]),
      "welded " & aliasOfCabinet(k))
    let centre = worldOf(k, 0'i32, 0'i32)
    let at = boardPoint(centre.x, centre.y)
    var px = at.px - width div 2
    var py = at.py - height div 2
    # keep the lip inside the board
    if k == 0: py = MapHeight - lipThickness
    if k == 2: py = 0
    if k == 1: px = MapWidth - lipThickness
    if k == 3: px = 0
    emitObject(packet, placed, MouthObjectBase + k, px, py, -30_000,
      BoardLayer, MouthSpriteBase + (if sim.cabinets[k].isOut: 4 else: 0) + k)

  # --- bricks --------------------------------------------------------------
  for k in 0 ..< CabinetCount:
    let tint = CabinetTint[k]
    let horizontal = sideIsHorizontal(k)
    let
      brickW = if horizontal: uuToPx(BrickHalfWidth * 2) else: 25
      brickH = if horizontal: 25 else: uuToPx(BrickHalfWidth * 2)
    emitSprite(packet, sent, BrickSpriteBase + k, brickW, brickH,
      solidSprite(brickW, brickH, tint[0], tint[1], tint[2], 255, edge = 250),
      "brick " & aliasOfCabinet(k))
    for row in 0 ..< MaxBrickRows:
      for col in 0 ..< BricksPerRow:
        let id = BrickObjectBase + (k * MaxBrickRows + row) * BricksPerRow + col
        if row >= sim.config.brickRows or not sim.cabinets[k].bricks[row][col]:
          dropObject(packet, placed, id)
          continue
        let box = brickBox(k, row, col)
        let at = boardPoint(box.x0, box.y0)
        emitObject(packet, placed, id, at.px, at.py, -20_000, BoardLayer,
          BrickSpriteBase + k)

  # --- paddles (a thick tinted bar with a bright leading edge) -------------
  for k in 0 ..< CabinetCount:
    let tint = CabinetTint[k]
    let horizontal = sideIsHorizontal(k)
    for far in 0 .. 1:
      let id = PaddleObjectBase + k * 2 + far
      if sim.cabinets[k].isOut or (far == 1 and not sim.config.farPaddle):
        dropObject(packet, placed, id)
        continue
      let box = sim.paddleBox(k, far == 1)
      let
        width = max(3, uuToPx(box.x1 - box.x0))
        height = max(3, uuToPx(box.y1 - box.y0))
        spriteId = PaddleSpriteBase + k * 2 + far
      emitSprite(packet, sent, spriteId, width, height,
        solidSprite(width, height, tint[0], tint[1], tint[2], 255, edge = 255),
        "paddle " & aliasOfCabinet(k) & (if far == 1: " far" else: ""))
      let at = boardPoint(box.x0, box.y0)
      emitObject(packet, placed, id, at.px, at.py, -10_000, BoardLayer,
        spriteId)
      discard horizontal

  # --- balls and their trails ---------------------------------------------
  let ballPx = max(4, uuToPx(BallHalf * 2))
  emitSprite(packet, sent, BallSpriteBase, ballPx, ballPx,
    solidSprite(ballPx, ballPx, 255, 250, 235, 255), "ball")
  for stage in 0 ..< BallTrailLength:
    let alpha = uint8(max(20, 200 - stage * 30))
    emitSprite(packet, sent, BallSpriteBase + 1 + stage, ballPx, ballPx,
      solidSprite(ballPx, ballPx, 255, 210, 160, alpha), "trail " & $stage)
  for index in 0 ..< MaxBalls:
    let head = BallObjectBase + index * (BallTrailLength + 1)
    if index >= sim.balls.len or sim.balls[index].state == bsServing:
      for offset in 0 .. BallTrailLength:
        dropObject(packet, placed, head + offset)
      continue
    let ball = sim.balls[index]
    let at = boardPoint(ball.x - BallHalf, ball.y - BallHalf)
    emitObject(packet, placed, head, at.px, at.py, 4_000, BoardLayer,
      BallSpriteBase)
    for stage in 0 ..< BallTrailLength:
      let id = head + 1 + stage
      if stage >= int(ball.trailLen):
        dropObject(packet, placed, id)
        continue
      let point = boardPoint(
        ball.trailX[stage] - BallHalf, ball.trailY[stage] - BallHalf)
      emitObject(packet, placed, id, point.px, point.py, 3_000 - stage,
        BoardLayer, BallSpriteBase + 1 + stage)

  # --- aim rays: where the LLM becomes visible ----------------------------
  let dashPx = 7
  for k in 0 ..< CabinetCount:
    let tint = CabinetTint[k]
    emitSprite(packet, sent, RaySpriteBase + k, dashPx, dashPx,
      solidSprite(dashPx, dashPx, tint[0], tint[1], tint[2], 190),
      "ray " & aliasOfCabinet(k))
  for seat in 0 ..< CabinetCount:
    let view = sim.stances[seat]
    let cabinet = view.cabinet
    let drawRay = sim.haveStance[seat] and cabinet >= 0 and
      cabinet < CabinetCount and not sim.cabinets[cabinet].isOut and
      view.aimAt.len > 0 and view.aimAt != "none" and
      view.stance in ["aim", "chase", "catch"]
    let target = if drawRay: cabinetOfAlias(view.aimAt) else: -1
    for dash in 0 ..< RayDashes:
      let id = RayObjectBase + seat * RayDashes + dash
      if target < 0 or sim.cabinets[target].isOut:
        dropObject(packet, placed, id)
        continue
      let
        fromPoint = worldOf(
          cabinet, sim.cabinets[cabinet].alongCentre, PaddleDepth)
        toPoint = worldOf(target, 0'i32, 0'i32)
        t = (dash * 2 + 1)
        span = RayDashes * 2
        x = int32(int64(fromPoint.x) +
          (int64(toPoint.x - fromPoint.x) * int64(t)) div int64(span))
        y = int32(int64(fromPoint.y) +
          (int64(toPoint.y - fromPoint.y) * int64(t)) div int64(span))
        at = boardPoint(x, y)
      emitObject(packet, placed, id, at.px - dashPx div 2,
        at.py - dashPx div 2, 5_000, BoardLayer, RaySpriteBase + cabinet)

  # --- concede flash: a magenta frame, never a full-board repaint ---------
  let concedeFresh = sim.phase == Playing and sim.lastConcede > 0 and
    sim.tickCount - sim.lastConcede < ShotFxTicks
  for edge in 0 ..< 4:
    let id = FxObjectBase + edge
    if not concedeFresh:
      dropObject(packet, placed, id)
      continue
    let
      horizontal = edge < 2
      width = if horizontal: MapWidth else: 14
      height = if horizontal: 14 else: MapHeight
      spriteId = FxSpriteBase + (if horizontal: 0 else: 1)
    emitSprite(packet, sent, spriteId, width, height,
      solidSprite(width, height, 240, 90, 220, 200), "concede flash")
    let
      px = if edge == 3: MapWidth - 14 else: 0
      py = if edge == 1: MapHeight - 14 else: 0
    emitObject(packet, placed, id, px, py, 9_000, BoardLayer, spriteId)

  # --- stance chips beside each bar, and the reserved bubble band ---------
  var textSlot = 0
  # Text sprites rotate through a bounded pool: a label re-baked under a NEW
  # id every frame would grow the client's sprite map without bound. A
  # template, not a closure — `sent` and `packet` are var parameters.
  template bakeText(text: string, r, g, b: uint8, size: int): int =
    block:
      let id = TextSpriteBase + (textSlot mod TextSpritePool)
      inc textSlot
      let baked = textSprite(text, r, g, b, size)
      sent.excl(id)
      packet.addSprite(id, baked.width, baked.height, baked.pixels, text)
      id
  for seat in 0 ..< CabinetCount:
    let view = sim.stances[seat]
    let cabinet = view.cabinet
    let id = ChipObjectBase + seat
    if not sim.haveStance[seat] or cabinet < 0 or cabinet >= CabinetCount or
        sim.cabinets[cabinet].isOut or sim.phase != Playing:
      dropObject(packet, placed, id)
      continue
    let tint = CabinetTint[cabinet]
    var chip = view.stance.toUpperAscii()
    if view.aimAt.len > 0 and view.aimAt != "none":
      chip = chip & "->" & view.aimAt
    let spriteId = bakeText(chip, tint[0], tint[1], tint[2], 20)
    let anchor = worldOf(
      cabinet, sim.cabinets[cabinet].alongCentre, PaddleDepth + 40_000'i32)
    let at = boardPoint(anchor.x, anchor.y)
    emitObject(packet, placed, id, max(2, min(MapWidth - 120, at.px - 40)),
      max(2, min(MapHeight - 30, at.py)), 8_000, BoardLayer, spriteId)
  # bubbles: the three most recent non-empty `say` lines, in the reserved band
  var bubbles: seq[tuple[seat: int, text: string]]
  for seat in 0 ..< CabinetCount:
    if sim.haveStance[seat] and sim.stances[seat].say.len > 0 and
        sim.tickCount <= sim.stances[seat].sayUntil:
      bubbles.add((seat, sim.stances[seat].say))
  for slot in 0 ..< MaxBubbles:
    let id = BubbleObjectBase + slot
    if slot >= bubbles.len:
      dropObject(packet, placed, id)
      continue
    let cabinet = max(0, sim.stances[bubbles[slot].seat].cabinet)
    let tint = CabinetTint[cabinet]
    let label = aliasOfCabinet(cabinet) & ": " & bubbles[slot].text
    let spriteId = bakeText(label, tint[0], tint[1], tint[2], 22)
    # The band is sized from MaxSayRunes measured in the board face, and the
    # bubble is clamped INSIDE the board on both axes: never a negative
    # coordinate, never relative to a paddle.
    let baked = textSprite(label, tint[0], tint[1], tint[2], 22)
    # The band is quoted in CABINET coordinates (y UP) and the board draws in
    # screen coordinates (y DOWN), so it converts here rather than in the
    # layout: Y in [92, 99] cu is the TOP of the screen.
    let py = ((100 - BubbleBandHiCu) * MapHeight) div 100 + slot * 24
    emitObject(packet, placed, id, max(2, (MapWidth - baked.width) div 2),
      max(2, min(MapHeight - baked.height - 2, py)), 8_500, BoardLayer,
      spriteId)
  # the ROM caption, bottom-left, always on
  block:
    let spriteId = bakeText(
      sim.config.rom.toUpperAscii(), 232, 200, 120, 22)
    let baked = textSprite(sim.config.rom.toUpperAscii(), 232, 200, 120, 22)
    emitObject(packet, placed, ScoreObjectBase, 8,
      MapHeight - baked.height - 8, 8_000, BoardLayer, spriteId)

proc buildSpriteProtocolPlayerUpdates*(
  sim: SimServer,
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState
): seq[uint8] =
  ## One seat's per-tick frame. The board is PERFECT INFORMATION — the whole
  ## arena, all four mouths, every paddle, every brick, every ball — and it
  ## carries only colour aliases: `showPlayerLabels` is forced false on the
  ## player stream, so no real name is ever on a seat's board
  ## (tests/test_locality.nim).
  nextState = initPlayerViewerState()
  if state != nil:
    nextState.sentSprites = state.sentSprites
    nextState.sentObjects = state.sentObjects
    nextState.layersSent = state.layersSent
  discard playerIndex
  sim.addBoard(
    result, nextState.sentSprites, nextState.sentObjects, nextState.layersSent)

proc buildBoardPacket*(
  sim: SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState
): seq[uint8] =
  ## The spectator board, without the chrome sprite (replay_runtime appends
  ## that, so live and replay share one board builder).
  nextState = state
  nextState.replayCommands = @[]
  nextState.replaySeekTick = -1
  nextState.clickPending = false
  nextState.povSelectPending = -2
  sim.addBoard(
    result, nextState.sentSprites, nextState.sentObjects, nextState.layersSent)

proc applyGlobalViewerMessage*(
  state: var GlobalViewerState, message: string
) =
  ## The viewer's own input channel: transport commands and seeks arrive as
  ## Sprite v1 chat (0x81); a mouse move/button is recorded for the click
  ## path. Anything else is ignored.
  if message.len == 0:
    return
  let kind = uint8(message[0])
  if kind == SpriteClientChat:
    if message.len < 3:
      return
    let length = message.readU16(1)
    if 3 + length > message.len:
      return
    let text = message[3 ..< 3 + length]
    if text.startsWith("s:"):
      try:
        state.replaySeekTick = parseInt(text[2 .. ^1].strip())
      except CatchableError:
        discard
    elif text.startsWith("v:"):
      try:
        state.povSelectPending = parseInt(text[2 .. ^1].strip())
      except CatchableError:
        discard
    else:
      for ch in text:
        state.replayCommands.add(ch)
  elif kind == SpriteClientMouseMove and message.len >= 6:
    state.mouseX = message.readI16(1)
    state.mouseY = message.readI16(3)
    state.mouseLayer = int(message.readU8(5))
  elif kind == SpriteClientMouseButton and message.len >= 3:
    state.mouseDown = message.readU8(2) != 0
    if not state.mouseDown:
      state.clickPending = true

proc applyPlayerViewerMessage*(
  state: PlayerViewerState, message: string, chatText: var string
) =
  ## A seat's channel. INPUT MASKS ARE DISCARDED: the server computes every
  ## command byte, so a mask arriving on a player socket would be a second,
  ## conflicting record per tick. Only the registration chat is read.
  discard state
  if message.len == 0:
    return
  if uint8(message[0]) == SpriteClientChat and message.len >= 3:
    let length = message.readU16(1)
    if 3 + length <= message.len:
      chatText = message[3 ..< 3 + length]
