# Writing a cabinet stance

A policy for THE CABINET is a **prompt**. Every 5 seconds the game server hands
your prompt, plus your cabinet's view of the board, to Claude and asks for one
JSON object. A deterministic autopilot then runs that object 24 times a second:
it predicts where each ball will reach your paddle line, gets the bar there,
and picks the contact offset that aims your return where you told it to.

**You choose what to defend and whom to shoot. You never drive the motor.**

## The five stances

| stance | what the autopilot does |
|---|---|
| `guard` | Intercept `target_ball` (or, if it will not reach you, the ball that reaches you soonest) and return it straight back off the middle of the bar. Safest. |
| `aim` | The same interception, but choose the contact offset that sends the ball at `aim_at`'s mouth — the **smallest** deflection that reaches it, because a shallower angle is a smaller demand on the bar. It never misses on purpose. |
| `camp` | Sit at `post` and only move when a ball's predicted arrival is close to you; how close is set by `aggression`. Cheap, safe, and it concedes anything wide. |
| `chase` | Go for whichever ball arrives soonest **anywhere on the board**, at full bar speed, with the most aggressive aim available (the very tip of the bar). Maximum damage — and how you end up out of position for the second ball. |
| `catch` | As `guard`, but GRIP the ball on contact and hold it up to 2 s, then release it aimed at `aim_at`. Only the `warlords` ROM allows this; elsewhere it behaves as `guard`. While you hold a ball you cannot defend the other one. |

## The fields

```json
{"note":"<=160 chars, your reasoning",
 "stance":"guard"|"aim"|"camp"|"catch"|"chase",
 "target_ball":"B1"|"B2"|"any",
 "aim_at":"RED"|"BLUE"|"GREEN"|"YELLOW"|"none",
 "post":-43.0..43.0,
 "lead_ticks":0..48,
 "aggression":0.0..1.0,
 "say":"<=48 chars"}
```

* **`post`** is in along-units on your own side: `0` is the centre of your
  mouth, `+43` is the far end toward the next cabinet counter-clockwise.
* **`lead_ticks`** is HOW FAR AHEAD THE AUTOPILOT COMMITS THE BAR. Inside that
  window it drives to the interception point; outside it, it merely shadows the
  ball's current along-projection. `lead_ticks 0` therefore arrives **late**;
  8–20 is the useful band.
* **`aggression`** widens `camp`'s move-anyway window and lengthens how long
  `catch` holds before releasing.
* **`say`** is shown to SPECTATORS only. No cabinet ever sees it, and there is
  no inter-seat channel of any kind.

## What scores

```
lives you still have at the end   20.00 each (normalised by startingLives — the big one)
winning                           15.00
each rival life you take          2.00   (credited to whoever touched the ball last)
each rival brick your ball breaks 0.50   (never your own wall)
each ball your paddle deflects    0.25
```

Nothing is ever subtracted, so the floor is `0.000`. **Lives dominate.** A
cabinet that trades a life for two knockouts has lost 20 to gain 4.

## Practical advice

1. **Defend first, aim second.** A missed aim costs 20 points; a boring return
   costs nothing. Only aim when the ball is far enough out that the bar has
   time to be in the right place.
2. **Shoot the wounded.** A rival on one life is two points and one fewer gun
   pointed at you for the rest of the game.
3. **Two balls beat one bar.** When both balls are converging on you, stop
   aiming: `camp` between the two predicted arrivals and take what you can.
4. **Watch your own wall.** In `warlords` your castle is nine bricks of free
   protection; once a column is breached that lane is open for the rest of the
   episode.
5. **Answer with JSON and nothing else.** The reply must begin with `{`. The
   parser is tolerant — fences, prose, numeric strings, `"the red cabinet"`,
   `"ball 2"` and the obvious synonyms are all accepted — but a reply with no
   usable field costs you the turn: one retry, then the `bulwark` fallback.

## The scripted baselines

Both fillers emit the **same** object on the same cadence, so they are directly
comparable to an LLM's:

* **`bulwark`** — the certification player and the per-turn fallback. Defends
  whatever is inbound; aims at the weakest alive rival when there is time;
  catches in `warlords` when only one ball is live; camps the middle otherwise;
  and drops every aim on its last life.
* **`spinner`** — never defends on purpose and never camps: `chase`,
  `lead_ticks 0`, full aggression, at a rotating rival. It hits hard and gets
  caught out of position.
