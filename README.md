# Radical Radial

A mouse-first radial action menu for World of Warcraft: Forever.

Hold a thumb button, a ring of actions opens around the cursor, flick toward the one you want, release. Scroll while it is open to switch action bars. Open it over an enemy or a friend and it becomes your offensive or support ring, aimed at them.

**Status:** M0 spike. The full design, including what Blizzard's secure sandbox allows in combat and the milestone plan, is in [DESIGN.md](DESIGN.md).

## Trying the M0 spike

The spike shows the current action bar as a 4 + 8 ring around the cursor, works in combat, and cycles bars with the wheel. It exists to prove the risky parts on a real client, so it prints diagnostics on request.

1. Copy this folder to `World of Warcraft/_classic_beta_/Interface/AddOns/RadicalRadial` (Forever beta) or `_retail_/Interface/AddOns/RadicalRadial` (Retail, same API).
2. In game, run `/rr status`. It should say `secure snippets: OK`.
3. Hold **BUTTON4** (mouse thumb button). A ring of Bar 1 opens at the cursor. Flick toward a slice and release to use it. Release in the centre or press Escape to cancel. Scroll while holding to switch to Bar 2 and back.
4. `/rr debug` prints every press, release, page change and cancel, from both the ordinary and the secure side, so you can see what the client actually delivers.

Commands:

```
/rr bind KEY        trigger binding, e.g. BUTTON4, SHIFT-BUTTON5, F (none to clear)
/rr bars 1 2 3      bars the wheel cycles through, in order (1-8)
/rr scale 1.2       ring scale (0.5 to 2)
/rr preview         show or hide the ring at screen centre, out of combat
/rr debug           toggle diagnostics in chat
/rr status          client, binding, snippet self-test and visual errors
/rr reset           restore defaults
```

The trigger can also be bound in Blizzard's keybinding UI under AddOns, "Open radial (hold)".

### What to check, and which risk it retires

| Check | Expected | Design risk |
|---|---|---|
| With `/rr debug` on, press and release BUTTON4 out of combat | Chat shows `opener click: LeftButton down`, then `up`, and the secure side prints `press: ring opened` and `release: slice N -> slot M` | 1: down and up both arrive from a mouse-button binding |
| Same, in combat | Same output; the action fires | 1 and 7: the wrapped click works under combat lockdown, and snippets run on this build |
| Open the ring with UI scale not 1, or after `/rr scale 1.4` | Ring is centred on the cursor; the highlighted slice matches the one the secure side reports on release | 2: `$cursor` and `GetMousePosition` under scale |
| Scroll while holding | Label changes Bar 1 → Bar 2, icons swap, camera does not zoom | 5: wheel override bindings while the trigger is held |
| Hold BUTTON4 while the cursor is over a Blizzard frame (chat, action bar) | Ring still opens and closes | 1: nothing swallows the thumb button |
| Druid form / Warrior stance, open the Bar 1 ring | Slices show the form's bar, like the real Bar 1 | 6: stance pages on Forever |
| Fight with cooldowns running | Swipes show; `/rr status` reports no visual errors | 4: secret values in the presentation layer |

If `/rr status` reports `secure snippets: FAILED`, the client build has the pre-70009 snippet bug and nothing else can work until Blizzard fixes it.
