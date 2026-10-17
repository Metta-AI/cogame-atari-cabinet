## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy
import sim_types, stances

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const PromptBankVersion* = "atari-cabinet-rules-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

const CanonicalSystemPrompt* = """
You are ONE of four arcade cabinets around a square CRT arena, 100 x 100 units.
Coordinates are units from the bottom-left corner; x runs right, y runs up.
Each cabinet owns one side: RED owns the bottom (y=0), BLUE the right (x=100),
GREEN the top (y=100), YELLOW the left (x=0). Your "+along" end touches the
next cabinet counter-clockwise: RED -> BLUE -> GREEN -> YELLOW -> RED.
In the middle of your own side is your MOUTH, a gap in the wall. 14 units in
front of it slides your PADDLE, a bar you move left and right along your own
side only. In the WARLORDS rom a row of 9 BRICKS sits between them.
THE POINT OF THE GAME: every ball that crosses your mouth costs you a LIFE.
Run out of lives and you are OUT - your mouth is welded shut and you are done.
The last cabinet with lives standing WINS.
YOUR PADDLE IS ALSO A GUN. Where the ball leaves it depends on WHERE ON THE BAR
it lands and WHICH WAY the bar was moving: hit it on your +along half and the
ball goes toward +along; sweep the bar as you hit and the angle steepens.
Thirteen outgoing angles. Every deflection makes the ball FASTER.
You score for: lives you still have at the end (this is the big one), winning,
each rival life you take with a ball you touched last, each rival brick your
ball breaks, and each ball your paddle deflects. Nothing is ever subtracted.
YOU CAN SEE THE WHOLE SCREEN - every ball, every paddle, every brick, everyone's
lives. It is a CRT; nothing is hidden. What you CANNOT see is who is playing the
other cabinets or what they are planning. You CANNOT talk to anyone and nobody
sees anything you write.
Every 5 seconds you set your STANCE for the next 5 seconds. A deterministic
autopilot runs it 24 times a second: it predicts where each ball will reach your
paddle line, gets the bar there, and picks the contact offset that aims your
return where you told it to. You choose WHAT to defend and WHOM to shoot.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars, your reasoning",
 "stance":"guard"|"aim"|"camp"|"catch"|"chase",
   // guard : intercept the ball named in "target_ball" (or, if it will not
   //         reach you, the ball that reaches you soonest) and return it
   //         straight back off the middle of the bar. Safest.
   // aim   : same interception, but choose the contact offset that sends the
   //         ball at "aim_at"'s mouth. If that offset cannot be reached in
   //         time the autopilot takes whatever offset it can - it never
   //         misses on purpose.
   // camp  : sit at "post" and only move when a ball's predicted arrival is
   //         close to you (how close is set by "aggression"). Cheap, safe,
   //         and it concedes anything wide.
   // chase : go for whichever ball arrives soonest, at full bar speed, with
   //         the most aggressive aim at "aim_at" available. Maximum damage,
   //         and it is how you end up out of position for the second ball.
   // catch : as "guard", but GRIP the ball on contact and hold it up to 2 s,
   //         then release it aimed at "aim_at". Only the WARLORDS rom allows
   //         this; elsewhere it behaves as "guard". While you hold a ball you
   //         cannot defend the other one.
 "target_ball":"B1"|"B2"|"any",
 "aim_at":"RED"|"BLUE"|"GREEN"|"YELLOW"|"none",   // never yourself
 "post":-43.0..43.0,        // where "camp" idles, in along-units on your side
                            // (0 = the centre of your mouth)
 "lead_ticks":0..48,        // how far ahead the autopilot commits the bar
                            // (24 ticks = 1 second)
 "aggression":0.0..1.0,     // 0 = never leave the post, 1 = chase everything
 "say":"<=48 chars"}        // spectators only; no cabinet ever sees it
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. NEVER echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## board view (built server-side — see decide.nim).
  operatorBlock(operatorPrompt) & viewJson

const Templates = [
  staticRead("prompts/plain.txt"), staticRead("prompts/numbered.txt"),
  staticRead("prompts/questions.txt"), staticRead("prompts/reordered.txt"),
  staticRead("prompts/heldout-briefing.txt"), staticRead("prompts/heldout-reference.txt")
]

proc systemPrompt*(selection: PromptSelection): string =
  if selection.selectedVariant == pvCanonical:
    return CanonicalSystemPrompt
  let
    mechanics = CanonicalSystemPrompt.find("Coordinates are units")
    visibility = CanonicalSystemPrompt.find("YOU CAN SEE THE WHOLE SCREEN")
    cadence = CanonicalSystemPrompt.find("Every 5 seconds you set")
    schema = CanonicalSystemPrompt.find("Reply with a single JSON object")
  doAssert mechanics >= 0 and visibility > mechanics and cadence > visibility and schema > cadence
  Templates[ord(selection.selectedVariant) - 1] % [
    CanonicalSystemPrompt[mechanics ..< visibility], CanonicalSystemPrompt[cadence ..< schema],
    CanonicalSystemPrompt[schema .. ^1]]

proc promptRecord*(selection: PromptSelection, system, user, kind: string,
                   turn, seat: int): JsonNode =
  %*{"schema": "atari-cabinet.prompt-provenance.v1", "kind": kind,
    "turn": turn, "seat": seat,
    "prompt_template": selection.promptMetadata(system, user),
    "messages": [{"role": "system", "content": system},
                 {"role": "user", "content": user}]}
