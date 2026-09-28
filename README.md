# Radical Radial

A mouse-first radial action menu for World of Warcraft: Forever.

Hold a thumb button, a ring of actions opens around the cursor, flick toward the one you want, release. Scroll while it is open to switch action bars. Open it over an enemy or a friend and it becomes your offensive or support ring, aimed at them.

**Status:** 0.4.2. Bar rings with hold and tap modes, multiple triggers, context rings aimed at the unit under the cursor, and a settings window; all confirmed in game on the Forever beta, including the wheel, the range tint and target capture. 0.4.2 adds the cancel radius: past it nothing is selected, so a release or a tap out there cancels. The full design, including what Blizzard's secure sandbox allows in combat and the milestone plan, is in [DESIGN.md](DESIGN.md).

Repository layout: `RadicalRadial/` is the addon itself, the folder that goes into `Interface/AddOns`. Everything else (design doc, offline harness in `tools/`) stays out of the game.

## Trying it

The ring shows one action bar as a 4 + 8 ring around the cursor, works in combat, and cycles bars with the wheel. Slices are LibActionButton-1.0 buttons, so icons, cooldowns, charges, counts and usable/range tints are painted the way Bartender4 paints them.

1. Copy the `RadicalRadial` folder to `World of Warcraft/_classic_beta_/Interface/AddOns/` (Forever beta) or `_retail_/Interface/AddOns/` (Retail, same API).
2. In game, run `/rr status`. It should say `secure snippets: OK` and name the LibActionButton revision.
3. Hold **BUTTON4** (mouse thumb button). A ring of Bar 1 opens at the cursor. Flick toward a slice and release to use it. Release in the centre, or well past the ring (the ring dims out there), or press Escape to cancel. Scroll while holding to switch to Bar 2 and back.
4. `/rr` opens the settings window (also `/rr config`, Options → AddOns → Radical Radial, or the addon compartment button on the minimap). Click the binding button and press a key or thumb button to rebind, tick the bars the wheel cycles through (in the order you tick them), pick hold or tap, and set the enemy and friend rings. Changes apply at once, or when combat ends.
5. `/rr debug` prints every press, release, page change and cancel, from both the ordinary and the secure side, so you can see what the client actually delivers.

Two modes, per trigger:

- **hold** (default): press opens, release fires the slice in the cursor's direction, a release in the centre or past the cancel radius cancels.
- **tap**: a release in the centre leaves the ring open; move, then press and release anywhere between the centre and the cancel radius to fire. A press in the centre or past the cancel radius cancels, and the ring closes by itself a few seconds after the cursor leaves it (`/rr autohide`). Hold-and-release still works from the first press.

The cancel radius (`/rr outer`, or the slider in the window) is a multiple of the ring radius, 1.6 by default: the icons end at about 1.2, so there is a band past them that still selects, and beyond it the ring dims and nothing is selected.

Context rings, per trigger: `/rr harm 3` shows Bar 3 instead of the normal bars when the trigger is pressed over an enemy, `/rr help 4` does the same over a friend. The press itself makes that unit your focus (or target, or nothing: `/rr capture focus|target|none`) and the ring's actions go to it, so a heal flicked from the friend ring lands on the friend under the cursor, not on your target.

Everything in the window is also a slash command (prefix with a trigger number, 2 to 4, to address another trigger, e.g. `/rr 2 bind BUTTON5`):

```
/rr                 open or close the settings window (also /rr config)
/rr help            list these commands
/rr bind KEY        trigger binding, e.g. BUTTON4, SHIFT-BUTTON5, F (none to clear)
/rr bars 1 2 3      bars the wheel cycles through, in order (1-8)
/rr harm 3          bars shown instead when pressed over an enemy (none to clear)
/rr help 4          bars shown instead when pressed over a friend (none to clear)
/rr capture focus   what the press captures the unit under the cursor as: focus, target or none
/rr mode hold|tap   interaction mode
/rr autohide 3      tap mode: seconds after the cursor leaves the ring before it closes (0 = never)
/rr 2 remove        remove trigger 2 (trigger 1 stays; unbind it with /rr bind none)
/rr triggers        list triggers
/rr scale 1.2       ring scale (0.5 to 2)
/rr outer 1.6       cancel radius as a multiple of the ring radius (1.2 to 3)
/rr preview         show or hide the ring at screen centre, out of combat
/rr debug           toggle diagnostics in chat
/rr status          client, triggers, snippet self-test and bar paging state
/rr reset           restore defaults
```

Triggers can also be bound in Blizzard's keybinding UI under AddOns, "Open radial (trigger 1)" to "(trigger 4)".

### In-game checklist

Each row retires one of the design risks in DESIGN.md section 12. Results so far are from Forever beta build 1.60.1.70009.

| Check | Expected | Risk | Result |
|---|---|---|---|
| With `/rr debug` on, press and release BUTTON4 out of combat | Chat shows `opener click: LeftButton down`, then `up`, and the secure side prints `press: ring opened` and `release: slice N -> slot M` | 1 | confirmed |
| Same, in combat | Same output; the action fires | 1, 7 | confirmed |
| Open the ring after `/rr scale 1.4` | Ring is centred on the cursor; the highlighted slice matches the one the secure side reports on release | 2 | confirmed |
| Same with a non-default UI scale (Options → Graphics → UI Scale, or `/console uiScale 0.8`) | Same | 2 | confirmed |
| Scroll while holding | Label changes Bar 1 → Bar 2, icons swap, camera does not zoom | 5 | confirmed in 0.4.1 (notches were dropped or doubled up to 0.4.0; the ring now takes the wheel itself) |
| Hold BUTTON4 and move the cursor well past the ring (about twice its radius), release | The ring dims out there with no slice highlighted; the release cancels and nothing fires. With `/rr outer 3` the same release fires the slice in that direction | | open (0.4.2) |
| `/rr mode tap`: tap, move past the cancel radius, tap again | The ring closes on the press, nothing fires | | open (0.4.2) |
| Hold BUTTON4 while the cursor is over a Blizzard frame (chat, action bar) | Ring still opens and closes | 1 | confirmed |
| Fight with cooldowns, charges and a target out of range | Swipes and counts show; out-of-range slices tint red; no Lua errors from LibActionButton | 4 | confirmed in 0.4.1 (the tint was missing in 0.4.0: the client no longer answers `IsActionInRange`, so the ring now uses its range-check events) |
| `/rr mode tap`, then in combat: tap BUTTON4 without moving, move to a slice, tap again | Ring stays open after the first tap, the second tap fires the slice; a tap in the centre closes it | 1 | confirmed |
| `/rr autohide 2` in tap mode: tap, then move the cursor well outside the ring | Ring closes about 2 s after the cursor leaves it; the wheel zooms the camera again afterwards | 5 | confirmed |
| `/rr 2 bind BUTTON5` and `/rr 2 bars 3 4`: hold BUTTON5 | Ring shows Bar 3, wheel goes to Bar 4; holding BUTTON5 while BUTTON4's ring is open closes it | 1 | open |
| `/rr harm 3`, then hold BUTTON4 with the cursor over an enemy | The enemy becomes your focus on the press, the ring shows Bar 3 with the label `Bar 3 · enemy @focus`, and the released slice hits the focus even if your target is something else | 3 | confirmed |
| Same in combat, and with `/rr capture target` | Same, with the enemy targeted instead | 3 | confirmed in 0.4.1 (failed in 0.4.0: with no current target the press never ran its macro, because Blizzard's click handler drops a click whose `unit` does not exist and the opener still carried `target` from the last release) |
| `/rr help 4`, hold over a friendly player or NPC | Label `Bar 4 · friend @focus`; a heal released from the ring goes to that unit | 3 | confirmed |
| Hold BUTTON4 over an enemy with no harm ring set (`/rr harm none`) | Normal ring, nothing captured, focus unchanged | 3 | open |
| Druid form / Warrior stance / vehicle, open the Bar 1 ring | Slices show the form's bar, like the real Bar 1. `/rr status` prints the paging state the client reports (`GetBonus=`, `HasBonus=`, …) for comparison | 6 | open |
| `/rr`, click the binding button, press Shift-F; again, press BUTTON5; again, press Escape | The button reads `SHIFT-F`, then `BUTTON5`, and the ring opens on each; Escape leaves it unchanged; chat names any Blizzard binding the key overrides; Escape with no capture running closes the window | | confirmed |
| With the window open, enter combat and tick Bar 3 | Footer turns to "In combat", the box ticks, the ring gains Bar 3 when combat ends; no `ADDON_ACTION_BLOCKED` | 7 | open |

If `/rr status` reports `secure snippets: FAILED`, the client build has the pre-70009 snippet bug and nothing else can work until Blizzard fixes it.

## Development

`python3 tools/check.py` (needs `pip install lupa`) runs the offline harness: it loads the addon's files in TOC order against a fake WoW API, runs the secure snippets in an emulated restricted environment, and walks through press, wheel, release and cancel scenarios. LibActionButton is replaced by a small fake that keeps the library's contract and runs its real `UpdateState` snippet.

Frame attributes are stored under lower-case names, as the client stores them, so a snippet attribute that collides with a state flag fails in the harness the way it failed in game (0.3.0 stored the `Open` snippet and the `open` flag in the same attribute, and every press died with `Invalid snippet body`).

The settings window is driven the same way: scenarios click its buttons and boxes through their scripts, feed keys to its capture and check that the saved variables, the secure frames and the window agree afterwards. The fake API lists widget methods by name rather than accepting anything, so a method the client does not have fails here first.

The fake click handler keeps Blizzard's rule that a click is dropped when the button's `unit` names a unit that does not exist, which is what silently skipped target captures in 0.4.0; the wheel is routed the way the client routes it (to the ring while the cursor is over it, to the bindings elsewhere); and the range tint is driven through the fake `C_ActionBar.EnableActionRangeCheck` and `ACTION_RANGE_CHECK_UPDATE`.

Vendored libraries (unmodified): LibStub, CallbackHandler-1.0 r8, LibActionButton-1.0 r160 (BSD, Hendrik "nevcairiel" Leppkes).
