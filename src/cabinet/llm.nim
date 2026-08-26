## Claude-backed cabinet stances. A policy is just a prompt: the game server
## composes the seat's board view plus that seat's PLAYER_PROMPT and asks
## Claude what its cabinet does for the next 5 seconds.
##
## Inherited from the starter (`src/ctf/llm.nim`) behaviour for behaviour — the
## credential ladder, the single-haiku model list, the `throttled` fast-fail,
## the fence-tolerant JSON extraction and the rune-boundary truncation are all
## scar tissue from real hosted failures.
##
## THE CABINET IS A SIMULTANEOUS-DECISION GAME, so every alive seat's call goes
## out as ONE PARALLEL BATCH per turn (`curly.makeRequests`). Seats are never
## queried sequentially: that is what keeps 24 turns inside the wall-clock
## budget.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait — which is what lets
## offline certification finish in seconds.

import std/[json, os, strutils]
import bitworld/runtime
import curly
import sim_types, stances

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn and cleared by the turn loop: a retry inside
      ## the same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a call that will be
      ## refused again.

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "cabinet llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## EXACTLY ONE candidate — haiku. No sonnet inference profile is a candidate:
  ## every one of them times out on every sidecar call (cogame-raid round 2,
  ## 2026-08-23), and one haiku throttle then cascades into a whole episode of
  ## scripted fallbacks because the retry burns the turn. With no second
  ## candidate a throttle fails fast (see `throttled`) and the seat plays the
  ## scripted fallback for that turn only.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "cabinet llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens))
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "cabinet llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "cabinet llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" in decide.nim: "LLM provider is unavailable".
    echo "cabinet llm: no credentials — the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model for the next
  ## batch instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair a
    ## broken one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(LlmError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
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
