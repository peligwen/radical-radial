# Radical Radial

A mouse-first radial action menu for World of Warcraft: Forever.

Hold a thumb button, a ring of actions opens around the cursor, flick toward the one you want, release. Scroll while it is open to switch action bars. Open it over an enemy or a friend and it becomes your offensive or support ring, aimed at them.

**Status:** M1, bar rings. The full design, including what Blizzard's secure sandbox allows in combat and the milestone plan, is in [DESIGN.md](DESIGN.md).

Repository layout: `RadicalRadial/` is the addon itself, the folder that goes into `Interface/AddOns`. Everything else (design doc, offline harness in `tools/`) stays out of the game.

## Trying it

The ring shows one action bar as a 4 + 8 ring around the cursor, works in combat, and cycles bars with the wheel. Slices are LibActionButton-1.0 buttons, so icons, cooldowns, charges, counts and usable/range tints are painted the way Bartender4 paints them.

1. Copy the `RadicalRadial` folder to `World of Warcraft/_classic_beta_/Interface/AddOns/` (Forever beta) or `_retail_/Interface/AddOns/` (Retail, same API).
2. In game, run `/rr status`. It should say `secure snippets: OK` and name the LibActionButton revision.
3. Hold **BUTTON4** (mouse thumb button). A ring of Bar 1 opens at the cursor. Flick toward a slice and release to use it. Release in the centre or press Escape to cancel. Scroll while holding to switch to Bar 2 and back.
4. `/rr debug` prints every press, release, page change and cancel, from both the ordinary and the secure side, so you can see what the client actually delivers.

Commands:

```
/rr bind KEY        trigger binding, e.g. BUTTON4, SHIFT-BUTTON5, F (none to clear)
/rr bars 1 2 3      bars the wheel cycles through, in order (1-8)
/rr scale 1.2       ring scale (0.5 to 2)
/rr preview         show or hide the ring at screen centre, out of combat
/rr debug           toggle diagnostics in chat
/rr status          client, binding, snippet self-test and bar paging state
/rr reset           restore defaults
```

The trigger can also be bound in Blizzard's keybinding UI under AddOns, "Open radial (hold)".

### In-game checklist

Each row retires one of the design risks in DESIGN.md section 12. Results so far are from Forever beta build 1.60.1.70009.

| Check | Expected | Risk | Result |
|---|---|---|---|
| With `/rr debug` on, press and release BUTTON4 out of combat | Chat shows `opener click: LeftButton down`, then `up`, and the secure side prints `press: ring opened` and `release: slice N -> slot M` | 1 | confirmed |
| Same, in combat | Same output; the action fires | 1, 7 | confirmed |
| Open the ring after `/rr scale 1.4` | Ring is centred on the cursor; the highlighted slice matches the one the secure side reports on release | 2 | confirmed |
| Same with a non-default UI scale (Options → Graphics → UI Scale, or `/console uiScale 0.8`) | Same | 2 | open |
| Scroll while holding | Label changes Bar 1 → Bar 2, icons swap, camera does not zoom | 5 | confirmed |
| Hold BUTTON4 while the cursor is over a Blizzard frame (chat, action bar) | Ring still opens and closes | 1 | confirmed |
| Fight with cooldowns, charges and a target out of range | Swipes and counts show; out-of-range slices tint red; no Lua errors from LibActionButton | 4 | open |
| Druid form / Warrior stance / vehicle, open the Bar 1 ring | Slices show the form's bar, like the real Bar 1. `/rr status` prints the paging state the client reports (`GetBonus=`, `HasBonus=`, …) for comparison | 6 | open |

If `/rr status` reports `secure snippets: FAILED`, the client build has the pre-70009 snippet bug and nothing else can work until Blizzard fixes it.

## Development

`python3 tools/check.py` (needs `pip install lupa`) runs the offline harness: it loads the addon's files in TOC order against a fake WoW API, runs the secure snippets in an emulated restricted environment, and walks through press, wheel, release and cancel scenarios. LibActionButton is replaced by a small fake that keeps the library's contract and runs its real `UpdateState` snippet.

Vendored libraries (unmodified): LibStub, CallbackHandler-1.0 r8, LibActionButton-1.0 r160 (BSD, Hendrik "nevcairiel" Leppkes).
