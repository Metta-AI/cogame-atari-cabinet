## The roster: join, auth, reward accounts and the results document.
##
## SEATS, not cabinets. Seat `s` drives cabinet `perm[s]`, so every per-seat
## array in the results is in SEAT order while every alias names a station on
## the board.

import std/[json, strutils]
import sim_types, sim_state

proc playerSlotLimit*(config: GameConfig): int =
  if config.closedRoster: min(MaxPlayers, config.slots.len) else: MaxPlayers

proc canAddPlayer*(sim: SimServer): bool =
  sim.players.len < sim.config.playerSlotLimit()

proc slotConfig*(config: GameConfig, slotIndex: int): PlayerSlotConfig =
  if slotIndex >= 0 and slotIndex < config.slots.len:
    config.slots[slotIndex]
  else:
    PlayerSlotConfig()

proc slotOccupied*(sim: SimServer, slotIndex: int): bool =
  for player in sim.players:
    if player.joinOrder == slotIndex:
      return true
  false

proc slotRestricted(config: GameConfig, slotIndex: int): bool =
  let slot = config.slotConfig(slotIndex)
  slot.name.len > 0 or slot.token.len > 0

proc slotAuthMatches(
  config: GameConfig, slotIndex: int, address, token: string
): bool =
  let slot = config.slotConfig(slotIndex)
  if slot.name.len > 0 and address != slot.name:
    return false
  if slot.token.len > 0 and token != slot.token:
    return false
  true

proc hasConfiguredToken(config: GameConfig, token: string): bool =
  for slot in config.slots:
    if slot.token.len > 0 and slot.token == token:
      return true
  false

proc hasConfiguredTokens(config: GameConfig): bool =
  for slot in config.slots:
    if slot.token.len > 0:
      return true
  false

proc validatePlayerSlot(
  config: GameConfig, slotIndex: int, address, token: string
) =
  let slot = config.slotConfig(slotIndex)
  if slot.name.len > 0 and address != slot.name:
    raise newException(CabinetError,
      "Player name does not match configured slot " & $slotIndex & ".")
  if slot.token.len > 0 and token != slot.token:
    raise newException(CabinetError,
      "Player token does not match configured slot " & $slotIndex & ".")

proc matchingConfiguredSlot(sim: SimServer, address, token: string): int =
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    let
      couldMatchName = slot.name.len > 0 and slot.name == address
      couldMatchToken = slot.token.len > 0 and slot.token == token
    if (couldMatchName or couldMatchToken) and
        sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc nextAutoSlot(sim: SimServer, address, token: string): int =
  let limit = sim.config.playerSlotLimit()
  for i in sim.nextJoinOrder ..< limit:
    if sim.slotOccupied(i):
      continue
    if not sim.config.slotRestricted(i) or
        sim.config.slotAuthMatches(i, address, token):
      return i
  for i in 0 ..< min(sim.nextJoinOrder, limit):
    if sim.slotOccupied(i):
      continue
    if not sim.config.slotRestricted(i) or
        sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc resolvePlayerSlot*(
  sim: SimServer, address, token: string, requestedSlot: int
): int =
  ## The slot a player should use, or a raise the caller turns into a 403.
  if requestedSlot >= MaxPlayers:
    raise newException(CabinetError,
      "Player slot must be between 0 and " & $(MaxPlayers - 1) & ".")
  if token.len > 0 and sim.config.hasConfiguredTokens() and
      not sim.config.hasConfiguredToken(token):
    raise newException(CabinetError, "Player token is not configured.")
  if requestedSlot >= 0:
    if requestedSlot >= sim.config.playerSlotLimit():
      raise newException(
        CabinetError, "Player slot is outside configured roster.")
    if sim.slotOccupied(requestedSlot):
      raise newException(CabinetError,
        "Player slot " & $requestedSlot & " is already occupied.")
    sim.config.validatePlayerSlot(requestedSlot, address, token)
    return requestedSlot
  result = sim.matchingConfiguredSlot(address, token)
  if result >= 0:
    return result
  result = sim.nextAutoSlot(address, token)
  if result < 0:
    raise newException(CabinetError, "No available player slot.")

proc nextPlayerSlot*(sim: SimServer): int =
  sim.players.len

proc playerAddressOccupied*(sim: SimServer, address: string): bool =
  for player in sim.players:
    if player.address == address:
      return true
  false

proc advanceJoinOrder(sim: var SimServer) =
  while sim.nextJoinOrder < MaxPlayers and sim.slotOccupied(sim.nextJoinOrder):
    inc sim.nextJoinOrder

proc rewardAccountIndex*(sim: SimServer, address: string): int =
  for i, account in sim.rewardAccounts:
    if account.address == address:
      return i
  -1

proc ensureRewardAccount(sim: var SimServer, address: string): int =
  result = sim.rewardAccountIndex(address)
  if result >= 0:
    return
  sim.rewardAccounts.add RewardAccount(address: address, slot: -1)
  result = sim.rewardAccounts.high

proc removePlayerAt*(sim: var SimServer, playerIndex: int) =
  ## A seat that drops keeps its cabinet for the whole episode (its stance
  ## source degrades to `bulwark` and revives on reconnect), so this only ever
  ## runs on the /global kick path and on the replay's recorded leaves.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  sim.players.delete(playerIndex)

proc addPlayer*(
  sim: var SimServer,
  address: string,
  requestedSlot = -1,
  token = "",
  trusted = false
): int =
  ## Seats one player. Joins are strictly slot-sequential.
  if not sim.canAddPlayer():
    raise newException(CabinetError, "The roster is full.")
  if sim.playerAddressOccupied(address):
    raise newException(CabinetError, "Player name is already connected.")
  let order =
    if trusted:
      if requestedSlot >= 0: requestedSlot else: sim.nextPlayerSlot()
    else:
      sim.resolvePlayerSlot(address, token, requestedSlot)
  if order < 0 or order >= MaxPlayers:
    raise newException(CabinetError, "Player slot is outside the roster.")
  if not trusted and order != sim.nextPlayerSlot():
    raise newException(CabinetError,
      "Player slot " & $order & " cannot join before slot " &
        $sim.nextPlayerSlot() & ".")
  let accountIndex = sim.ensureRewardAccount(address)
  sim.rewardAccounts[accountIndex].slot = order
  sim.players.add Player(
    address: address, token: token, joinOrder: order,
    reward: sim.rewardAccounts[accountIndex].reward)
  if order < CabinetCount:
    sim.seatNames[order] = address
  sim.advanceJoinOrder()
  sim.players.high

proc seatName*(sim: SimServer, seat: int): string =
  ## The REAL policy name of one seat — spectator side only.
  if seat < 0 or seat >= CabinetCount:
    return ""
  if sim.seatNames[seat].len > 0:
    return sim.seatNames[seat]
  let slot = sim.config.slotConfig(seat)
  if slot.name.len > 0:
    return slot.name
  "Baseline (" & $(seat + 1) & ")"

proc bricksRemaining*(sim: SimServer, cabinet: int): int =
  for row in 0 ..< min(MaxBrickRows, max(0, sim.config.brickRows)):
    for col in 0 ..< BricksPerRow:
      if sim.cabinets[cabinet].bricks[row][col]:
        inc result

proc scoreOf*(sim: SimServer, cabinet: int): float =
  float(sim.cabinets[cabinet].scoreMicro) / 1_000_000.0

proc playerResultsJson*(sim: SimServer): string =
  ## The results document, written to COGAME_RESULTS_URI and embedded once in
  ## the replay's chat stream as the `result` control record (which is what
  ## makes the bytes self-sufficient).
  ##
  ## It must equal the manifest's `results_schema` KEY FOR KEY — that schema is
  ## `additionalProperties: false` and the certifier rejects any unknown
  ## field, so adding or removing a key here means editing
  ## coworld_manifest_template.json in the same commit
  ## (tests/test_manifest.nim).
  let seats = CabinetCount
  var
    names = newJArray()
    aliases = newJArray()
    cabinets = newJArray()
    policyKinds = newJArray()
    scores = newJArray()
    win = newJArray()
    placements = newJArray()
    livesLeft = newJArray()
    concedes = newJArray()
    knockouts = newJArray()
    chips = newJArray()
    saves = newJArray()
    catches = newJArray()
    bricksLeft = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
  for seat in 0 ..< seats:
    let cabinet = sim.cabinetOfSeat(seat)
    let cab = sim.cabinets[cabinet]
    names.add(%sim.seatName(seat))
    aliases.add(%aliasOfCabinet(cabinet))
    cabinets.add(%cabinet)
    policyKinds.add(%(
      if sim.seatPolicyKind[seat].len > 0: sim.seatPolicyKind[seat]
      else: "scripted"))
    scores.add(%sim.scoreOf(cabinet))
    placements.add(%int(cab.placement))
    win.add(%(cab.placement == 1))
    livesLeft.add(%int(cab.lives))
    concedes.add(%int(cab.concedes))
    knockouts.add(%int(cab.knockouts))
    chips.add(%int(cab.chips))
    saves.add(%int(cab.saves))
    catches.add(%int(cab.catches))
    bricksLeft.add(%sim.bricksRemaining(cabinet))
    llmTurns.add(%sim.llmTurns[seat])
    fallbackTurns.add(%sim.fallbackTurns[seat])
  $(%*{
    "names": names,
    "aliases": aliases,
    "cabinets": cabinets,
    "policyKinds": policyKinds,
    "scores": scores,
    "win": win,
    "placements": placements,
    "rom": sim.config.rom,
    "startingLives": sim.config.startingLives,
    "livesLeft": livesLeft,
    "concedes": concedes,
    "knockouts": knockouts,
    "chips": chips,
    "saves": saves,
    "catches": catches,
    "bricksLeft": bricksLeft,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "finalTick": sim.tickCount,
    "reason": (if sim.endReason.len > 0: sim.endReason else: ReasonComplete),
    "endRule": (if sim.endRule.len > 0: sim.endRule else: EndRuleFullTime),
    "seed": sim.config.seed
  })

proc resultsKeys*(): seq[string] =
  ## The 22 result keys, in document order — asserted against the manifest's
  ## `results_schema` by tests/test_manifest.nim.
  @["names", "aliases", "cabinets", "policyKinds", "scores", "win",
    "placements", "rom", "startingLives", "livesLeft", "concedes",
    "knockouts", "chips", "saves", "catches", "bricksLeft", "llmTurns",
    "fallbackTurns", "finalTick", "reason", "endRule", "seed"]

proc buildRewardPacket*(sim: SimServer): string =
  ## The starter's reward-protocol packet, one block per seat.
  for seat in 0 ..< min(CabinetCount, sim.players.len):
    let identity = sim.players[seat].address.strip()
    let cabinet = sim.cabinetOfSeat(seat)
    result.add("reward " & identity & " " &
      $int(sim.cabinets[cabinet].scoreMicro div 1_000_000) & "\n")
    result.add("lives " & identity & " " & $int(sim.cabinets[cabinet].lives) &
      "\n")
    result.add("saves " & identity & " " & $int(sim.cabinets[cabinet].saves) &
      "\n")
