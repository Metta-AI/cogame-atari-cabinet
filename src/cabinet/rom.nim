## The ROM preset table — "the rotation".
##
## One engine, three presets. The preset is applied in this EXACT order:
##
##   schema defaults  ->  the named `rom` preset  ->  any explicitly supplied
##                                                   config key
##
## so the certification fixture can override `startingLives` on top of
## `rom: "warlords"`. tests/test_rom.nim pins the order.
##
## NO FLOATING POINT IN THIS FILE.

import std/strutils
import sim_types

type
  RomPreset* = object
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

const RomPresets* = [
  RomPreset(
    rom: RomWarlords, startingLives: 3, ballCount: 2, brickRows: 1,
    catchEnabled: true, farPaddle: false, goalHalfCu: 18, paddleHalfCu: 7,
    farPaddleHalfCu: 5, ballSpeed0Milli: 550),
  RomPreset(
    rom: RomQuadrapong, startingLives: 5, ballCount: 2, brickRows: 0,
    catchEnabled: false, farPaddle: false, goalHalfCu: 22, paddleHalfCu: 6,
    farPaddleHalfCu: 5, ballSpeed0Milli: 650),
  RomPreset(
    rom: RomFoozpong, startingLives: 3, ballCount: 2, brickRows: 0,
    catchEnabled: false, farPaddle: true, goalHalfCu: 18, paddleHalfCu: 6,
    farPaddleHalfCu: 5, ballSpeed0Milli: 600)
]

proc knownRom*(name: string): bool =
  ## True when a ROM name is one of the three shipped presets.
  let key = name.strip().toLowerAscii()
  for preset in RomPresets:
    if preset.rom == key:
      return true
  false

proc presetFor*(name: string): RomPreset =
  ## The named preset. Raises on an unknown ROM: the manifest's config_schema
  ## has an enum for `rom`, so an unknown name means the fixture and the sim
  ## disagree and the episode must fail loudly at startup, not silently play
  ## a different game (tests/test_startup.nim).
  let key = name.strip().toLowerAscii()
  for preset in RomPresets:
    if preset.rom == key:
      return preset
  raise newException(
    CabinetError,
    "unknown rom \"" & name & "\"; expected one of " & RomNames.join(", "))

proc applyPreset*(config: var GameConfig, explicitKeys: openArray[string]) =
  ## Applies the named ROM preset on top of the schema defaults, skipping
  ## every key the incoming config named EXPLICITLY. `explicitKeys` is the
  ## caller's list of keys present in the config JSON, which is what makes the
  ## order `defaults -> preset -> explicit` rather than
  ## `defaults -> explicit -> preset`.
  let preset = presetFor(config.rom)
  config.rom = preset.rom
  var keys: seq[string]
  for key in explicitKeys:
    keys.add(key)
  proc named(key: string): bool =
    for k in keys:
      if k == key:
        return true
    false
  if not named("startingLives"): config.startingLives = preset.startingLives
  if not named("ballCount"): config.ballCount = preset.ballCount
  if not named("brickRows"): config.brickRows = preset.brickRows
  if not named("catchEnabled"): config.catchEnabled = preset.catchEnabled
  if not named("farPaddle"): config.farPaddle = preset.farPaddle
  if not named("goalHalfCu"): config.goalHalfCu = preset.goalHalfCu
  if not named("paddleHalfCu"): config.paddleHalfCu = preset.paddleHalfCu
  if not named("farPaddleHalfCu"):
    config.farPaddleHalfCu = preset.farPaddleHalfCu
  if not named("ballSpeed0Milli"):
    config.ballSpeed0Milli = preset.ballSpeed0Milli
