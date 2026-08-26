## Writes the worst-case text frame out for tools/ci/renderer_fixture.html.
import std/[json, os]
import worst_case_frame

proc main() =
  let outDir = if paramCount() >= 1: paramStr(1) else: "dist/render-fixture"
  createDir(outDir)
  let frame = worstCaseFrame()
  writeFile(outDir / "board_packet.bin", cast[string](frame.packet))
  var strings = newJArray()
  for placement in textPlacements(frame.packet):
    strings.add(%*{
      "text": placement.text, "x": placement.x, "y": placement.y,
      "w": placement.width, "h": placement.height,
      "sprite": placement.spriteId, "object": placement.objectId})
  writeFile(outDir / "fixture_meta.json", $(%*{
    "boardW": MapWidth, "boardH": MapHeight,
    "maxSayRunes": MaxSayRunes, "maxNoteRunes": MaxNoteRunes,
    "textSpriteBase": TextSpriteBase, "textSpritePool": TextSpritePool,
    "chromeSpriteId": BroadcastChromeSpriteId,
    "strings": strings}))
  echo "render fixture: ", frame.packet.len, " packet bytes, ",
    strings.len, " baked strings -> ", outDir

main()
