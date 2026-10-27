## Private inference receipts and authoritative macro decisions, outside replay state.
import std/[json, options, os, strutils, tables]
import bitworld/decision_trajectory
import curly
export decision_trajectory, options

proc beginCapture*(game, family: string): DecisionTrajectory =
  if getEnv(CogameSaveTrajectoryUriEnv).len == 0: return nil
  if getEnv(CogameSaveTrajectoryUriEnv) == getEnv("COGAME_SAVE_REPLAY_URI"):
    raise newException(ValueError, "private trajectory must be separate from public replay")
  newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"), family, game,
    getEnv("COWORLD_GAME_VERSION"), getEnv("COWORLD_SOURCE_REVISION"))

proc requestEvidence*(id, policy, system, user, body: string): DecisionAttempt =
  result = newDecisionAttempt(id, policy, aoModel)
  result.prompt = %*[{"role": "system", "content": system},
    {"role": "user", "content": user}]
  result.request = parseJson(body)
  if result.request{"model"}.getStr().len > 0:
    result.model = some(result.request["model"].getStr())
  result.decoder = %*{"max_tokens": result.request{"max_tokens"}}

proc receivedEvidence*(evidence: var DecisionAttempt, response: Response) =
  evidence.rawResponse = %response.body
  var headers = initTable[string, string]()
  for (name, value) in response.headers:
    headers[name.toLowerAscii()] = value
  evidence.responseHeaders = some(headers)
  for pair in [("x-softmax-llm-call-id", "call"), ("request-id", "request"),
      ("x-coworld-checkpoint-sha256", "model"),
      ("x-coworld-tokenizer-sha256", "tokenizer"),
      ("x-coworld-chat-template-sha256", "template")]:
    let value = headers.getOrDefault(pair[0])
    if value.len == 0: continue
    case pair[1]
    of "call": evidence.platformCallId = some(value)
    of "request": evidence.providerRequestId = some(value)
    of "model": evidence.modelIdentity = some(value)
    of "tokenizer": evidence.tokenizerIdentity = some(value)
    of "template": evidence.chatTemplateSha256 = some(value)
    else: discard
  try:
    let payload = parseJson(response.body)
    if payload{"model"}.getStr().len > 0: evidence.model = some(payload["model"].getStr())
    if payload{"stop_reason"}.getStr().len > 0: evidence.stopReason = some(payload["stop_reason"].getStr())
    if not payload{"usage", "input_tokens"}.isNil and payload{"usage", "input_tokens"}.kind == JInt:
      evidence.inputTokens = some(payload["usage"]["input_tokens"].getInt())
    if not payload{"usage", "output_tokens"}.isNil and payload{"usage", "output_tokens"}.kind == JInt:
      evidence.outputTokens = some(payload["usage"]["output_tokens"].getInt())
  except CatchableError: discard

proc finishCapture*(trajectory: DecisionTrajectory, outcome: JsonNode) =
  if trajectory.isNil: return
  let status = case outcome{"reason"}.getStr()
    of "complete": esCompleted
    of "fault": esFailed
    else: esTruncated
  trajectory.finish(status, outcome, outcome{"scores"})
  let destination = getEnv(CogameSaveTrajectoryUriEnv)
  if destination.startsWith("http://") or destination.startsWith("https://"):
    let pool = newCurlPool(1)
    let headers = @[("Content-Type", "application/x-ndjson")]
    let methodName = getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT").toUpperAscii()
    let response = case methodName
      of "PUT": pool.put(destination, headers, trajectory.eventsJsonl(), timeout = 5)
      of "POST": pool.post(destination, headers, trajectory.eventsJsonl(), timeout = 5)
      else: raise newException(ValueError, "private trajectory upload requires PUT or POST")
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "private trajectory upload failed with HTTP " & $response.code)
  else:
    trajectory.writeEventsToUri(destination)
