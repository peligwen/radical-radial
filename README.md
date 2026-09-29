# Radical Radial

A mouse-first radial action menu for World of Warcraft: Forever.

Hold a thumb button, a ring of actions opens around the cursor, flick toward the one you want, release. Scroll while it is open to switch action bars. Open it over an enemy or a friend and it becomes your offensive or support ring, aimed at them.

**Status:** 0.6.0. Bar rings with hold and tap modes, multiple triggers, context rings aimed at the unit under the cursor, a cancel radius and a settings window, all confirmed in game on the Forever beta through 0.4.2. 0.5.0 added the first cut of custom rings (M4): named rings of spells, items, macros and mounts that use no bar slots, a drag-and-drop editor, fill-from-bar with an offensive/helpful filter, and import/export strings; the editor's drops, moves, swaps, clears and fill-from-bar are confirmed in game. 0.5.1 makes rings and wheel lists per character (with copy-from-character), moves the tier boundary a little past the inner icons, and stops the spellbook from closing the settings window; the boundary and the window are confirmed in game, the per-character storage is not yet tested on a second character. 0.6.0 adds ring layouts (a single tier of 8, 12 flat, 8 + 8 and others, per trigger for bars and per custom ring), nested rings (a slice that opens another ring in place), a macro that opens a trigger's ring from an action bar, and click to fire; all of 0.6.0 passes the offline harness and none of it has been tried in game yet. The full design, including what Blizzard's secure sandbox allows in combat and the milestone plan, is in [DESIGN.md](DESIGN.md).

Repository layout: `RadicalRadial/` is the addon itself, the folder that goes into `Interface/AddOns`. Everything else (design doc, offline harness in `tools/`) stays out of the game.

## Trying it

The ring shows one action bar as a 4 + 8 ring around the cursor, works in combat, and cycles bars with the wheel. Slices are LibActionButton-1.0 buttons, so icons, cooldowns, charges, counts and usable/range tints are painted the way Bartender4 paints them.

1. Copy the `RadicalRadial` folder to `World of Warcraft/_classic_beta_/Interface/AddOns/` (Forever beta) or `_retail_/Interface/AddOns/` (Retail, same API).
2. In game, run `/rr status`. It should say `secure snippets: OK` and name the LibActionButton revision.
3. Hold **BUTTON4** (mouse thumb button). A ring of Bar 1 opens at the cursor. Flick toward a slice and release to use it. Release in the centre, or well past the ring (the ring dims out there), or press Escape to cancel. Scroll while holding to switch to Bar 2 and back.
4. `/rr` opens the settings window (also `/rr config`, Options → AddOns → Radical Radial, or the addon compartment button on the minimap). Click the binding button and press a key or thumb button to rebind, tick the bars the wheel cycles through (in the order you tick them), pick hold or tap, and set the enemy and friend rings. Changes apply at once, or when combat ends.
5. `/rr debug` prints every press, release, page change and cancel, from both the ordinary and the secure side, so you can see what the client actually delivers.
6. Custom rings: in `/rr`, the **Custom rings** tab. New ring, then drag spells from the spellbook, items from your bags, macros from the macro window or mounts from the journal onto the slots (or press a bar's number under "Fill from bar" to copy that bar's actions, optionally only the offensive or the helpful ones). Tick the ring on a trigger's Bars row (or its enemy or friend row) and the wheel reaches it like a bar. Custom rings never use action bar slots.
7. Layouts: the **Bar layout** row on a trigger's page picks how that trigger shows bars (4 + 8 by default, or 12 flat, a single tier of 8, 6 or 4, 6 + 6, 8 + 8); a custom ring has its own Layout row in the editor. A bar has twelve slots, so a smaller layout shows the first ones and 8 + 8 leaves four empty. With a single tier there is no tier boundary: everything from the centre out selects by direction alone.
8. Nested rings: right-click an empty slot in the editor and pick another ring. Releasing (or clicking) on that slice opens the other ring where the cursor is, waiting; press and release on one of its slices to use it. Press the centre to go back to the ring it came from (press it again to close), scroll to leave it and page the wheel, or Escape.
9. From an action bar: press **Create macro** on a trigger's page (or `/rr macro create`). A macro called `Radial 1` containing `/click RadicalRadialMacro1` lands on the cursor; drop it on any bar. Pressing it (its key, or a click on it) opens the trigger's ring at the cursor, waiting; pressing it again fires the slice in the cursor's direction, and so does a left click on the ring itself (a right click cancels). Everything else (bars, enemy and friend rings, capture, layout) is the trigger's. The macro can also be written by hand, with conditionals if you like (`/click [combat] RadicalRadialMacro1; RadicalRadialMacro2`).
10. Click to fire: the **Click to fire** box on a trigger's page lets any waiting ring (tap mode after the first tap, a nested ring, the macro) take the mouse, so a left click fires and a right click cancels. It is always on for a ring the macro opened; leave it off for a hold-and-release thumb button, which never waits.

Two modes, per trigger:

- **hold** (default): press opens, release fires the slice in the cursor's direction, a release in the centre or past the cancel radius cancels.
- **tap**: a release in the centre leaves the ring open; move, then press and release anywhere between the centre and the cancel radius to fire. A press in the centre or past the cancel radius cancels, and the ring closes by itself a few seconds after the cursor leaves it (`/rr autohide`). Hold-and-release still works from the first press.

The cancel radius (`/rr outer`, or the slider in the window) is a multiple of the ring radius, 1.6 by default: the icons end at about 1.2, so there is a band past them that still selects, and beyond it the ring dims and nothing is selected.

A ring is *waiting* whenever it is open with no button held: after the first tap in tap mode, after a nested ring opened, or after the macro opened it. A waiting ring closes by itself `/rr autohide` seconds after the cursor leaves it (3 by default, 0 never), and takes the mouse when the trigger has click to fire on or the macro opened it.

Context rings, per trigger: `/rr harm 3` shows Bar 3 instead of the normal bars when the trigger is pressed over an enemy, `/rr help 4` does the same over a friend. The press itself makes that unit your focus (or target, or nothing: `/rr capture focus|target|none`) and the ring's actions go to it, so a heal flicked from the friend ring lands on the friend under the cursor, not on your target.

Custom rings go anywhere a bar goes: `/rr bars 1 2 Utility` puts the ring called Utility third on the wheel, `/rr harm Offense` shows it over enemies. A ring holds up to sixteen slices (the inner tier first, then the outer, clockwise from the top; its layout says how many are shown), each a spell, an item, a macro or another ring; a slice in a context ring acts on the captured unit like a bar slot does. `/rr ring fill Offense 1 harm` copies the offensive actions of Bar 1 into it. `/rr ring export Offense` prints a string to share; `/rr ring import RR2:...` adds the ring (or replaces the one with the same name; 0.5.x `RR1:` strings still import).

Rings belong to the character that made them, and so do the wheel lists (which bars and rings each trigger shows); the triggers themselves, their keys and modes, the scale and the cancel radius are shared by all your characters. A character you log in with for the first time starts with the lists the last character used, minus rings it does not have. To reuse a ring elsewhere, log in on the other character and use "Copy from another character" in the Custom rings tab (or `/rr ring copy Peligwen Utility`; `/rr rings` lists every character's rings). Rings made with 0.5.0 land on the first character that logs in with 0.5.1.

Everything in the window is also a slash command (prefix with a trigger number, 2 to 4, to address another trigger, e.g. `/rr 2 bind BUTTON5`):

```
/rr                 open or close the settings window (also /rr config)
/rr help            list these commands
/rr bind KEY        trigger binding, e.g. BUTTON4, SHIFT-BUTTON5, F (none to clear)
/rr bars 1 2 3      bars (1-8) and custom rings (by name) the wheel cycles through, in order
/rr harm 3          bars or rings shown instead when pressed over an enemy (none to clear)
/rr help 4          bars or rings shown instead when pressed over a friend (none to clear)
/rr capture focus   what the press captures the unit under the cursor as: focus, target or none
/rr mode hold|tap   interaction mode
/rr autohide 3      seconds after the cursor leaves a waiting ring (tap, nested ring, macro) before it closes (0 = never)
/rr layout 4+8      layout for bars on this trigger: 4+8, 12, 8, 6, 4, 6+6 or 8+8 (inner + outer slices)
/rr click on|off    a waiting ring takes the mouse: left click fires, right click cancels
/rr macro [create]  the macro that opens this trigger's ring from an action bar; create makes it and puts it on the cursor
/rr 2 remove        remove trigger 2 (trigger 1 stays; unbind it with /rr bind none)
/rr triggers        list triggers
/rr rings           list custom rings and their slices
/rr ring add NAME   new custom ring; also remove NAME, rename NAME NEWNAME, layout NAME 4+8
/rr ring set NAME SLOT spell ID | item ID | macro MACRONAME | ring RINGNAME   (slots 1-16; ring nests that ring)
/rr ring clear NAME SLOT
/rr ring fill NAME BAR [harm|help]   copy a bar's actions, optionally only the offensive or helpful ones
/rr ring export NAME | import STRING
/rr ring copy CHARACTER NAME   copy a ring from another character (its name, or Name-Realm)
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
| Hold BUTTON4 and move the cursor well past the ring (about twice its radius), release | The ring dims out there with no slice highlighted; the release cancels and nothing fires. With `/rr outer 3` the same release fires the slice in that direction | | confirmed (0.4.2) |
| `/rr mode tap`: tap, move past the cancel radius, tap again | The ring closes on the press, nothing fires | | confirmed (0.5.1) |
| Hold BUTTON4 and move the cursor just past an inner icon's outer edge, then on toward the outer icons | The inner slice stays highlighted for a little way past its icon (until about a third of the way across the gap); the outer slice takes over before its icon starts | | confirmed (0.5.1; up to 0.5.0 the tier switched at the icon's edge) |
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
| `/rr`, Custom rings tab, New ring; drag a spell from the spellbook onto slot 5, an item from a bag onto slot 1, a macro from the macro window onto slot 7, a mount from the journal onto slot 6 | Each slot shows the icon and its tooltip on hover; a pet action or flyout is refused with a chat line; the cursor is empty after each drop | | confirmed for spells, items and macros (0.5.0); mounts and the refused pet action not reported. Opening the spellbook closed the window (fixed in 0.5.1, next row) |
| With the window open, open the spellbook (P), then the bags and the macro window; press Escape with the window open, out of combat and in combat | The window stays open while the panels open; Escape closes it either way and does nothing else (no game menu); while it is open every other key still reaches the game. With `/rr debug`, a line saying the window was "put back" means the client closed it and the insurance hook re-opened it: report that | | confirmed (0.5.1) |
| Click slot 5, then click slot 9; drag slot 1 onto slot 9; right-click slot 9 | The spell moves to slot 9; the drag swaps the item with the spell (the spell ends up on the cursor, drop it anywhere); right-click clears the slot and the cursor stays as it was | | confirmed (0.5.0) |
| Tick the ring on trigger 1's Bars row; hold BUTTON4, scroll to it, release on the spell | The label shows the ring's name, the icons are the ring's, the spell casts; `/rr debug` prints `release: slice N -> spell ID` | | open (0.5.0) |
| Same in combat, and with the ring on the enemy row: press over an enemy, release on a spell | The spell casts on the focus; no `ADDON_ACTION_BLOCKED`; changing a slot in combat says it waits for combat to end | 7 | open (0.5.0) |
| Release on a macro slice, then press BUTTON4 over an enemy with an enemy ring set | The macro runs; the next press still captures the enemy (the opener's leftover `macro` attribute is cleared before the capture click) | 3 | open (0.5.0) |
| "Fill from bar", offensive only, Bar 1 (with a mount and a macro on the bar) | Only the slots the client calls harmful are copied; the mount arrives as its spell, the macro by name, a flyout is skipped | | confirmed (0.5.0) |
| Export, then import the string on another character (or after editing the name in it) | The ring comes back slot for slot; importing a string whose name matches replaces that ring | | open (0.5.0) |
| Log in on a second character after making rings and ticking one on the wheel with the first | `/rr status` names the character; the Custom rings tab is empty and says rings belong to the character; the trigger's Bars row shows the same bars as on the first character without the ring; `/rr rings` lists the first character's rings; "Copy from another character" offers them and copying one adds it here, selected; back on the first character its rings and wheel are unchanged | | open (0.5.1) |
| On the second character, Reset to defaults | The shared settings and this character's rings go; the first character still has its rings and wheel afterwards | | open (0.5.1) |
| A spell slice while its unit is out of range; a spell on cooldown | Red tint (from `C_Spell.IsSpellInRange` against the focus when the ring was opened over an enemy, else the target) and the cooldown swipe, with no Lua error in combat | 4 | open (0.5.0) |
| The window on a small screen (UI scale 1 at 1080p) | The whole window fits (it is 740 units tall; the screen is 768 at UI scale 1), the trigger page's Remove button is above the footer | | open (0.6.0 added a Bar layout row, a Click to fire box and a macro line to the page) |
| `/rr layout 8`, hold BUTTON4 | Eight icons on one ring, no inner tier; a release just outside the centre already selects the nearest of the eight; `/rr layout 12` shows twelve at 30 degrees; `/rr layout 8+8` shows two tiers of eight with Bar 1's slots 1-8 inside and 9-12 plus four empty slots outside; the slices move as the wheel switches to a custom ring with another layout, in combat too | 1 | open (0.6.0) |
| Editor: set a ring's Layout to 12, drop a spell on slot 12, put the ring on the wheel | The editor shows twelve slots on one ring; the live ring shows the spell at 11 o'clock and a release there casts it | | open (0.6.0) |
| Editor: right-click an empty slot of ring A and pick ring B; hold BUTTON4, scroll to A, release on that slice; press and release on a slice of B | The slot shows a bag icon with B's name; the release opens B centred where the cursor was, fires nothing, and B's label reads `B « A`; the press-and-release casts the slice; with `/rr debug` the release line says it opened the nested ring | 1 | open (0.6.0) |
| Same, then press BUTTON4 in the centre of B; press it there again | The first press brings A back at the cursor (its release does nothing), the second closes the ring; scrolling in B instead goes back to A and then pages | | open (0.6.0) |
| Same, then leave the cursor outside B for 3 s | B closes by itself (hold mode now arms auto-hide for a nested ring) | 5 | open (0.6.0) |
| `/rr macro create`, drop the macro on a bar, press its key with the cursor over the world | The ring opens at the cursor and stays; scrolling pages it; pressing the key again fires the slice in the cursor's direction; a left click on the ring fires it too, a right click closes it; `/rr debug` reports `macro opener 1 click: LeftButton up` and `macro: trigger 1 opened` | 1, 7 | open (0.6.0) |
| Same in combat, and with an enemy ring set and the macro's key pressed over an enemy | The action fires with no `ADDON_ACTION_BLOCKED`; the enemy becomes the focus on the opening press and the fired slice hits it | 1, 3, 7 | open (0.6.0) |
| Click the macro on the bar with the mouse instead of its key | The ring opens around the bar button; a left click on one of its slices fires it | 1 | open (0.6.0) |
| `/rr mode tap`, `/rr click on`: tap BUTTON4, move to a slice, left-click; tap again, then press BUTTON4 on a slice | The left click fires and closes the ring; the thumb button on the waiting ring fires it too (the ring takes the mouse, so the click lands on it rather than the binding); with `/rr click off` a left click on the waiting ring goes through to the world | 1 | open (0.6.0) |

If `/rr status` reports `secure snippets: FAILED`, the client build has the pre-70009 snippet bug and nothing else can work until Blizzard fixes it.

## Development

`python3 tools/check.py` (needs `pip install lupa`) runs the offline harness: it loads the addon's files in TOC order against a fake WoW API, runs the secure snippets in an emulated restricted environment, and walks through press, wheel, release and cancel scenarios. LibActionButton is replaced by a small fake that keeps the library's contract and runs its real `UpdateState` snippet.

Frame attributes are stored under lower-case names, as the client stores them, so a snippet attribute that collides with a state flag fails in the harness the way it failed in game (0.3.0 stored the `Open` snippet and the `open` flag in the same attribute, and every press died with `Invalid snippet body`).

The settings window is driven the same way: scenarios click its buttons and boxes through their scripts, feed keys to its capture and check that the saved variables, the secure frames and the window agree afterwards. The fake API lists widget methods by name rather than accepting anything, so a method the client does not have fails here first.

The fake click handler keeps Blizzard's rule that a click is dropped when the button's `unit` names a unit that does not exist, which is what silently skipped target captures in 0.4.0, and runs a named `macro` before it looks at `macrotext`; the wheel is routed the way the client routes it (to the ring while the cursor is over it, to the bindings elsewhere); and the range tint is driven through the fake `C_ActionBar.EnableActionRangeCheck` and `ACTION_RANGE_CHECK_UPDATE`.

Custom rings are exercised end to end: the fake LibActionButton enforces the library's state kinds (and turns item ids into `item:ID` as r160 does), the fake cursor answers `GetCursorInfo` the way the client does (a spell's id is the fourth value, a mount's id needs the journal), and scenarios drive the editor's drops, pick-ups, swaps, fill-from-bar and the import/export box.

Per-character storage is covered by switching the fake player's name between loads: a scenario makes rings and lists on one character, logs in as another, copies a ring back through the command and through the editor's menu (a fake `MenuUtil` records the menu tree), resets, and checks that the first character's data is untouched. The fake panel manager empties `UISpecialFrames` when a panel opens, as the client did for the spellbook, so the window's Escape handling is tested against that: keys pass through, a kept key stops propagating until the fake timer runs, the window joins the list only in combat, and the `ShowUIPanel` hook puts the window back only for a same-tick close by an ordinary panel.

Layouts are checked against the page snippet's output: after every open and wheel notch the harness compares each slice's scale, anchor offset and shown state with `ns.SlicePolar`, and releases at known angles through the 8, 12 and 8 + 8 layouts. Nested rings are driven through the release, the tap, the wheel, Escape, the editor's right-click menu and the saved variables (dangling and self references dropped on load). The macro opener is clicked the way the client's `/click` command clicks it (one up click, or a down click when the macro says so), and the clicker the way a mouse does, with the fake `SecureActionButton_OnClick` gating on `useOnKeyDown` as Blizzard's does; a fake `CreateMacro`/`EditMacro` pair covers `/rr macro create`, including a full macro list and combat. A failing scenario now prints the scenario line it failed on (`HARNESS_VERBOSE=1` adds the full traceback and every chat line).

Vendored libraries (unmodified): LibStub, CallbackHandler-1.0 r8, LibActionButton-1.0 r160 (BSD, Hendrik "nevcairiel" Leppkes).
