# Radical Radial — design

A mouse-first radial action menu for **World of Warcraft: Forever**.

Hold a mouse button; a ring of actions opens **centered on the cursor**; flick toward the action you want and release. While the ring is up, the scroll wheel swaps which action bar (or custom ring) it shows. Rings can be **context-aware**: open it over an enemy and you get your offensive ring aimed at that enemy; over a friend, your support ring aimed at them. All of it works in combat.

This document turns that pitch into something buildable. Section 3 is the important one: it lists exactly what Blizzard's secure sandbox lets an addon do while in combat, verified against the current Blizzard UI source, because every design decision below follows from those rules.

---

## 1. Target platform: what Forever actually is

Verified September 2026 against the beta (build 1.60.1.69893, then 70009) and Blizzard's 12.1.0 UI source.

| Fact | Consequence for us |
|---|---|
| Forever is the **Retail client**. `WOW_PROJECT_ID == WOW_PROJECT_MAINLINE`, Retail's `C_*` namespaces (`C_ActionBar` alone has 73 functions), Edit Mode, Cooldown Manager. The old Classic globals (`GetSpellInfo`, `UnitAura`, `GetTalentInfo`…) are gone. | Write Retail-style code. The same addon runs on Retail 12.1, so most iteration can happen on live Retail where the beta's bugs don't get in the way. |
| TOC interface number is **16001** (`select(4, GetBuildInfo())` returns 16001). Retail addons that test `>= 100000` to mean "modern client" misfire. | `## Interface: 16001, 120100`. Never branch on the build number; branch on `WOW_PROJECT_ID` or feature-detect. |
| **8 action bars** exist (`MultiBar5Button1`…`MultiBar7Button1` are present), plus stance, possess, override/vehicle, extra and pet bars. Focus targeting exists (`FocusFrame`, `FocusUnit`). | The slot layout in section 6 applies, and focus is available for aiming context rings. |
| **Midnight combat restrictions carried over**: `C_Secrets`, `C_RestrictedActions`, secret values. In combat, unit health, auras and similar are secret; addons cannot compare or do arithmetic on them. Widget setters (`Cooldown:SetCooldown`, `FontString:SetText`, `StatusBar:SetValue`, texture functions) deliberately accept secrets. | Affects only the ring's *visuals* (section 9). The ring's mechanics never read combat data; they use macro-conditional-grade functions that stay allowed. |
| Beta bugs: secure snippets threw "attempt to call a nil value" on every build before 70009, and SavedVariables were not loaded back early in the beta. Both are fixed. | Re-test snippets on every beta build; a regression here breaks every action-bar addon at once. |
| No addon site has a Forever game flavour yet. | Ship as a normal Retail-style package; "Forever" in the name is ours to choose. |

Sources: Blizzard's Forever announcement and the September 17 developer Q&A (Forever uses the modern addon API including combat-data restrictions); the `forever-addon-kit` API baseline captured on the beta; Gethe's mirror of the 12.1.0 UI source.

---

## 2. Prior art: OPie

OPie is the reference radial addon and has proven the whole category works inside the sandbox for 15 years. What it does, in its own terms:

- Rings open while a binding is held; selection is by **mouse direction**, not by hitting the icon; release fires. "Quick" mode = hold and release; "Relaxed" mode = tap to open, left-click a slice.
- Right-click, Escape, or releasing in the center cancels.
- "Use first slice when opened" lets the ring target or focus the unit under the cursor at open time. (This is the trick that makes aimed context rings possible; see section 8.)
- Nested rings: scroll or middle-click to descend.
- Left and right mouse buttons cannot be bound (a Blizzard restriction); middle is discouraged.

Radical Radial's differences: it is **bar-shaped** (rings mirror the action bars you already maintain, with wheel paging between them), it is designed around thumb buttons, and context rings are a first-class concept rather than a slice trick.

---

## 3. The rules: what an addon may do in combat

Casting a spell, using an item, running a macro or targeting is a **protected action**. In combat, protected actions only run from a real click or keypress on a **secure button** (`SecureActionButtonTemplate`) whose attributes say what to do. Secure frames cannot be shown, hidden, moved, re-parented or given new attributes by ordinary addon code in combat ("combat lockdown"). The one escape hatch is the **restricted environment**: small Lua snippets attached to `SecureHandler*Template` frames that Blizzard runs as trusted code, in a sandbox with a fixed function list and "frame handles" instead of real frames.

Everything below was read from `Interface/AddOns/Blizzard_RestrictedAddOnEnvironment/` and `Blizzard_FrameXML/SecureTemplates.lua` in the 12.1.0 (69933) source. The same files ship in Forever (Retail client).

### 3.1 Primitives the design relies on

| Need | Primitive | Notes |
|---|---|---|
| Open the ring centered on the cursor, in combat | `handle:SetPoint("CENTER", "$cursor")` | The restricted `SetPoint` accepts `"$cursor"` as the relative frame and anchors at the current cursor position, scale-corrected; offsets default to 0. The offset is applied against the frame's parent, so ring frames are parented to `UIParent`. Also `"$screen"` and `"$parent"`. |
| Know where the cursor is at release | `handle:GetMousePosition()` → `x, y` as fractions 0–1 of the frame's rect, or `nil` when the cursor is outside it. `handle:IsUnderMouse(recursive)`. | The only cursor access inside snippets. Use a UIParent-sized secure frame to turn fractions into screen coordinates (`handle:GetWidth()`, `GetHeight()`, `GetRect()` are available). |
| Do the geometry | `atan2`, `deg`, `floor`, `abs`, `%`, and the whole `math` table (`math.sqrt`) | All in scope. |
| Show, hide, layer | `Show()`, `Hide()`, `SetAlpha()`, `SetFrameStrata()`, `SetFrameLevel()`, `SetParent()`, `SetScale()` | |
| React to trigger press and release | `SecureHandlerClickTemplate` → `_onclick(self, button, down)`; `RegisterForClicks("AnyDown", "AnyUp")`; `SecureHandlerWrapScript(button, "OnClick", header, preBody, postBody)` | A wrapped `OnClick` pre-snippet runs *before* the secure action button's own click handler and may set that button's attributes, which the handler then reads. |
| Scroll wheel while the ring is open | `SecureHandlerMouseWheelTemplate` → `_onmousewheel(self, delta)` | Frame must have `EnableMouseWheel(true)` (set out of combat). Capturing the wheel also stops camera zoom while the ring is open. |
| Hover to expand a tier, hover to cancel | `SecureHandlerEnterLeaveTemplate` → `_onenter(self)`, `_onleave(self)` | Fires on rectangular frames only, so it works on icon hit-boxes, not wedges. |
| Auto-close when the mouse has left for N seconds | `handle:RegisterAutoHide(ttl)`, `handle:AddToAutoHide(child)` (also callable as globals out of combat) | Blizzard's `SecureHoverDriver`; runs securely, in combat. |
| Take over keys only while the ring is open | `SetBindingClick(true, key, frame, button)`, `SetBinding(...)`, `ClearBindings()` | Override bindings for Escape, and for re-routing the trigger itself. |
| Enemy or friend under the cursor | `UnitExists("mouseover")`, `UnitIsDead(unit)`, `PlayerCanAttack(unit)`, `PlayerCanAssist(unit)`, `SecureCmdOptionParse("[@mouseover,harm,nodead] harm; [@mouseover,help,nodead] help; none")` | Macro-conditional-grade checks; not subject to secret values. |
| Which bar page or stance applies | `GetActionBarPage()`, `GetBonusBarIndex()`, `GetBonusBarOffset()`, `GetVehicleBarIndex()`, `GetOverrideBarIndex()`, `GetTempShapeshiftBarIndex()`, `GetShapeshiftForm()`, `HasAction(slot)`, `GetActionInfo(slot)` (scrubbed: type and id for spell/item/macro/flyout/companion/outfit) | Enough to make a "Bar 1" ring follow Bear Form or a vehicle exactly as Blizzard's main bar does. |
| Classify a slot as offensive or supportive | In snippets: `IsSpellHarmful`, `IsSpellHelpful`, `IsHarmfulItem`, `IsHelpfulItem`. Outside combat: `C_ActionBar.IsHarmfulAction(slot)`, `IsHelpfulAction(slot)`. | Lets us auto-split a bar into harm and help rings. |
| Execute the chosen action | `SecureActionButtonTemplate` attributes: `type="action"` + `action=slot`; or `type="spell"/"item"/"macro"` with `spell`/`item`/`macrotext`; `unit`; `useOnKeyDown` (per-button override of the "cast on key down" CVar); `typerelease`; `harmbutton`/`helpbutton` | `useOnKeyDown` is read on every click, so a snippet may flip it between the down and the up click. |
| Change what a slice does, in combat | `handle:SetAttribute(name, value)` on any secure frame we hold a handle to (`GetFrameRef`, set up out of combat with `SetFrameRef`) | This is how wheel paging works: re-point each slice's `action` attribute. |

### 3.2 What is *not* available in snippets, and how we live without it

- `GetCursorPosition`, `GetScreenWidth/Height`: use `$cursor` anchoring and `GetMousePosition()` on a UIParent-sized secure frame.
- Timers, `OnUpdate`: use `RegisterAutoHide` for delayed closing; anything else that needs time is cosmetic and lives in the presentation layer.
- Textures, text, cooldown swipes: not needed in snippets. Ordinary addon code may change textures, font strings, cooldown swipes and alpha of protected frames in combat; it may not show, hide, move or re-attribute them. That split is the architecture (section 4).
- `UnitIsUnit`, unit names, nameplate lookups: not needed; context detection uses `PlayerCanAttack/Assist` on `mouseover`.

### 3.3 The hardware-event rule and what it kills

A cast needs a click or keypress. Mouse *movement* is not one. So:

- **Hover cannot cast.** A "move over a slice and it fires" mode is impossible for spells, items and macros. Hovering can *select* (highlight) and can *navigate* (expand a sub-ring via `_onenter`); a click or a release must confirm.
- Snippets cannot "click" another button for you. The button the user physically pressed is the button that performs the action. Therefore the trigger button itself is a secure action button, and at release time the snippet copies the chosen slice's attributes onto it.

---

## 4. Architecture: two layers

```
┌────────────────────────────────────────────────────────────────┐
│ Presentation layer  (ordinary Lua; allowed to run in combat)   │
│   icons · cooldown swipes · counts · usable/range tints        │
│   selection highlight and pointer (OnUpdate + GetCursorPosition)│
│   page label · animations · ring editor · options panel        │
└──────────────▲─────────────────────────────────────────────────┘
               │  OnAttributeChanged, OnShow/OnHide, callbacks
┌──────────────┴─────────────────────────────────────────────────┐
│ Control layer  (secure frames + restricted snippets)           │
│   Opener       SecureActionButton + click wrap; the trigger    │
│   Screen       UIParent-sized frame; cursor → screen coords    │
│   Capture      square around the ring; wheel + right-click     │
│   Ring(s)      positioning, show/hide, tiers, context choice   │
│   Slices       SecureActionButtons; attributes are the content │
└────────────────────────────────────────────────────────────────┘
```

All frames are created and wired (`SetFrameRef`, `WrapScript`, `RegisterForClicks`, `EnableMouseWheel`) at load, out of combat. In combat the control layer only flips attributes, anchors and visibility through snippets; the presentation layer only paints.

### 4.1 Hold-and-release, end to end

1. **Trigger down.** The binding `CLICK RadicalRadialOpener:LeftButton` delivers a down-click. The wrap pre-snippet:
   - decides the context (`harm` / `help` / `none`, section 8) and picks the ring for that context and this trigger;
   - `ring:SetPoint("CENTER", "$cursor")`, `ring:Show()`, `capture:Show()`;
   - if the context is `harm` or `help` and the ring wants an aimed unit, sets `useOnKeyDown = true` and `type = "macro"`, `macrotext = "/focus [@mouseover,exists,nodead]"` so the down-click itself captures the unit; otherwise returns `false`, which tells the wrap machinery to skip Blizzard's click handler for this click;
   - installs override bindings: Escape → cancel button.
2. **Mouse moves.** Presentation layer reads `GetCursorPosition()` on `OnUpdate` and lights the slice in that direction. Cosmetic only.
3. **Trigger up.** The pre-snippet:
   - `local sx, sy = screen:GetMousePosition()` → cursor in screen units; `ring:GetRect()` → ring center; `dx, dy`, radius, angle;
   - resolves tier from radius and sector from angle (section 7), or "cancel" in the dead zone;
   - copies the winning slice's attributes onto the opener (`type`, `action`/`spell`/`item`/`macrotext`, `unit`), sets `useOnKeyDown = false`;
   - hides ring and capture, clears override bindings.
   Blizzard's `SecureActionButton_OnClick` then runs on the same click and performs the action. (A wrapped pre-snippet returns `false` to suppress the click, a string to change the button name, or nothing to let it through; that is the whole contract.)

Snippet sketch for the release half:

```lua
-- pre-body of the OnClick wrap on the opener. Arguments: self, button, down.
if down then return end                      -- press half lives elsewhere
local screen  = self:GetFrameRef("screen")
local ring    = self:GetFrameRef("active")
local fx, fy  = screen:GetMousePosition()    -- fractions of the screen frame
local sw, sh  = screen:GetWidth(), screen:GetHeight()
local l, b, w, h = ring:GetRect()
local dx = fx * sw - (l + w / 2)
local dy = fy * sh - (b + h / 2)
local r  = math.sqrt(dx * dx + dy * dy)
local R  = ring:GetAttribute("radius")
local tier, n, first
if     r < 0.15 * R then tier = nil                       -- dead zone: cancel
elseif r < 0.55 * R then tier, n, first = 1, ring:GetAttribute("innerCount"), 1
else                     tier, n, first = 2, ring:GetAttribute("outerCount"), ring:GetAttribute("innerCount") + 1
end
if tier then
  local a = (90 - deg(atan2(dy, dx))) % 360             -- 0 at 12 o'clock, clockwise
  local idx = first + floor((a + 180 / n) % 360 / (360 / n))
  local slice = ring:GetFrameRef("slice" .. idx)
  self:SetAttribute("type",      slice:GetAttribute("type"))
  self:SetAttribute("action",    slice:GetAttribute("action"))
  self:SetAttribute("spell",     slice:GetAttribute("spell"))
  self:SetAttribute("item",      slice:GetAttribute("item"))
  self:SetAttribute("macrotext", slice:GetAttribute("macrotext"))
  self:SetAttribute("unit",      slice:GetAttribute("unit"))
else
  self:SetAttribute("type", nil)
end
self:SetAttribute("useOnKeyDown", false)
ring:Hide(); self:GetFrameRef("capture"):Hide(); self:ClearBindings()
```

Wheel paging, on the capture frame:

```lua
-- _onmousewheel. Arguments: self, delta.
local ring  = self:GetFrameRef("active")
local count = ring:GetAttribute("pageCount")
local page  = ((ring:GetAttribute("page") - 1 + (delta > 0 and 1 or -1)) % count) + 1
ring:SetAttribute("page", page)                 -- presentation layer sees OnAttributeChanged
local base = ring:GetAttribute("pageBase" .. page)   -- first slot of that bar, or nil for a custom ring
if base then
  for i = 1, 12 do ring:GetFrameRef("slice" .. i):SetAttribute("action", base + i - 1) end
else
  ring:GetFrameRef("custom" .. page):Show()  -- custom rings are separate frames, swapped in place
end
```

(These are sketches to show the shape and that every call is in the sandbox's list; the real code needs bounds checks, per-trigger ring sets, and the tap modes.)

---

## 5. Interaction modes

The three modes from the brief map onto the sandbox like this.

| Mode | Gesture | Fire | Cancel | Depth |
|---|---|---|---|---|
| **A. Hold & release** (default) | press → move → release | release fires the slice in the cursor's direction | release in the dead zone; right-click; Escape | multi-tier by radius; nested rings by hovering a folder icon (`_onenter`) or by wheel |
| **B. Tap, then click** | tap → ring stays → left-click a slice | the click on the slice (each slice is its own secure button) | right-click; Escape; auto-hide after the mouse has left for N s | unlimited; clicking a folder slice opens the sub-ring in place |
| **C. Tap, hover, tap** ("click and mouseover") | tap → hover a slice → tap the trigger again | the second tap: the press-snippet sees the ring is open and fires the hovered slice | second tap in the dead zone; right-click; Escape | single depth by construction: the second tap is spent on confirming |

Notes:

- **Pure hover-to-fire is not possible** (section 3.3). Mode C is the closest legal form: hover selects, a tap confirms. That is also why it is single-depth, which matches the brief.
- Modes are per trigger. A thumb button can run mode A for the bar ring while a keyboard key runs mode B for a utility ring.
- Selection is by **direction**, not by hitting the icon (OPie's model). It is faster and forgiving: overshooting past the icon still selects it.
- Right-click cancel works because the capture frame is a secure click handler; it sees `button == "RightButton"`.
- Escape cancel is an override binding installed on open and cleared on close.
- Mode B auto-hide uses `capture:RegisterAutoHide(ttl)` so a forgotten ring closes itself.

---

## 6. What goes in a ring

### 6.1 The question: is there spare action-bar space?

Mainline (and therefore Forever) has **180 action slots** in 15 pages of 12:

| Slots | Page | Used by |
|---|---|---|
| 1–12 | 1 | Bar 1, page 1 |
| 13–24 | 2 | Bar 1, page 2 (reached with the page arrows / `NEXTACTIONPAGE`) |
| 25–36 | 3 | Bar 4 (`MultiBarRight`) |
| 37–48 | 4 | Bar 5 (`MultiBarLeft`) |
| 49–60 | 5 | Bar 3 (`MultiBarBottomRight`) |
| 61–72 | 6 | Bar 2 (`MultiBarBottomLeft`) |
| 73–120 | 7–10 | Bonus bars: stances and forms replace Bar 1 page 1 (Warrior stances, Druid forms, Rogue Stealth, Priest Shadowform) |
| 121–144 | 11–12 | Special bars (skyriding on Retail; vehicle, possess, override). The exact page numbers come from `GetVehicleBarIndex()`, `GetOverrideBarIndex()`, `GetTempShapeshiftBarIndex()`, all callable inside snippets. Never hardcode them. |
| 145–156 | 13 | Bar 6 (`MultiBar5`) |
| 157–168 | 14 | Bar 7 (`MultiBar6`) |
| 169–180 | 15 | Bar 8 (`MultiBar7`) |

So: **yes, there is spare space**, in two flavours.

- **Hidden bars.** Bars 6–8 (36 slots) and Bar 1 page 2 (12 slots) exist whether or not Edit Mode shows them. Hide them and they are 48 slots of pure ring storage that still behave like action slots: drag-and-drop editing (temporarily show the bar in Edit Mode), Blizzard cooldowns and keybinds, macros, stance paging. Bonus-bar pages 7–10 are free for classes without stances, but a class's stance list can change with talents, so treat them as off-limits by default.
- **No slots at all.** A slice does not have to be an action slot. A secure button with `type="spell", spell=<id>` (or `item`, `macro`) casts directly and never touches the bars. This is OPie's model, it is unlimited, and it is how custom and context rings avoid competing with your real bars. The costs: we must render our own cooldown/usable/count visuals for those slices and write our own drag-and-drop editor (both solved problems; see section 9).

### 6.2 Recommendation: a hybrid ring model

A **ring** is an ordered list of slice definitions plus layout. A **slice** is one of:

- `{ action = N }` — mirrors action slot N (a bar slice)
- `{ spell = id }`, `{ item = id | "name" }`, `{ macro = name }`, `{ macrotext = "..." }` — direct content
- `{ ring = "name" }` — a folder that opens a nested ring
- `{}` — empty

A **bar ring** is simply a preset whose 12 slices are `action = base + i`. A **trigger** owns an ordered list of rings; the wheel cycles that list (Bar 1 → Bar 2 → Bar 3 → "Consumables" → …). Bar rings and custom rings coexist in the same cycle.

Why this rather than either extreme:

- Bar rings give the "scroll to change action bars" experience literally, and inherit everything you already set up (drag-and-drop, keybinds, macros, Blizzard's cooldown numbers, stance paging).
- Custom rings give unlimited, context-specific content without eating bar slots, and nested rings for utilities you rarely touch.
- One slice implementation covers both (section 9).

### 6.3 Bar rings should follow the game's own paging

Blizzard's main bar swaps its `actionpage` attribute by stance, vehicle, possession and override state. A "Bar 1" ring should do the same or it will show Cat Form's bar while you are in Bear Form. Inside the snippet: if the ring is a Bar 1 ring and `GetBonusBarIndex()` reports a bonus bar, use that page's base slot instead of 1. The functions Blizzard uses for this decision are all in the sandbox's list, so the ring can match the real bar exactly.

---

## 7. Geometry

### 7.1 Slice count and tiers

An action bar has 12 slots. Three sensible layouts:

| Layout | Sector size | Fits a bar? | Verdict |
|---|---|---|---|
| **12 flat** | 30° | exactly | Fine for direction-based selection (OPie users run 12+), but 30° is where mis-flicks start under stress. |
| **4 inner + 8 outer** (recommended) | inner 90°, outer 45° | exactly | Slots 1–4 sit on the inner tier: shortest travel, biggest sectors, so put your most-used spells in slots 1–4. Slots 5–12 on the outer tier at 45°, comfortable. Tier is chosen by distance from center, sector by angle. |
| 8 + 8 (the brief's "two tiers of 8") | 45° / 45° | 12 + 4 spare | The 4 extras are useful as "switch ring", "capture target", or context actions. Costs an extra tier boundary the hand has to learn. |

Default: 4 + 8, with 8 + 8 and 12-flat as per-ring options. Custom rings can be any count from 2 to 16 per tier.

### 7.2 Bands

Measured in ring radius `R` (the outer icon circle):

- `r < 0.15 R`: dead zone. Release here = cancel. Large enough that a nervous release does nothing.
- `0.15 R ≤ r < 0.55 R`: inner tier.
- `r ≥ 0.55 R`: outer tier, **unbounded outward**. You cannot overshoot: flick hard toward 3 o'clock and you still get the 3 o'clock slice.

Sector 1 is at 12 o'clock, clockwise, matching how people read a bar left-to-right around a clock face. The presentation layer draws icons at sector centers and a pointer from the center toward the cursor.

### 7.3 Nested rings

A `{ ring = "name" }` slice draws a folder icon. Opening it:

- Mode B/C: click (or tap) it; the sub-ring replaces the parent in place, with a "back" dead zone.
- Mode A: hover its icon; an `_onenter` snippet on the icon's hit-box shows the sub-ring around the parent ring. Releasing on a sub-ring slice fires it; releasing back in the parent's area cancels. Wheel can also step into and out of the sub-ring.

Depth 2 is plenty. Deeper trees fight the whole point of the addon (speed).

---

## 8. Context-aware rings

### 8.1 Detection

At press time the snippet classifies the unit under the cursor:

```lua
local ctx = "none"
if UnitExists("mouseover") and not UnitIsDead("mouseover") then
  if     PlayerCanAttack("mouseover") then ctx = "harm"
  elseif PlayerCanAssist("mouseover") then ctx = "help" end
end
```

Each trigger maps `harm`, `help` and `none` to a ring (any of them may be the same ring, or "do nothing"). This uses only macro-conditional-grade checks, which Midnight's restrictions leave alone.

### 8.2 Aiming: capture on press

The obvious approach, `unit = "mouseover"` on the slices, does not survive the ring opening: the moment the cursor moves onto the ring, the world unit under it is gone and `mouseover` is empty. OPie's answer is the right one, and the sandbox makes it clean:

- The **down-click** is itself a hardware event, so the opener performs a real action on it: `/focus [@mouseover,exists,nodead]` (or `/target …`), installed only when the context came out as `harm` or `help`. This happens before the ring has visibly moved anything.
- Slices in a context ring carry `unit = "focus"` (or `"target"`). Their macros can also use `[@focus]`.
- Per-trigger option, **capture as**: `focus` (default; leaves your target alone; Forever has focus), `target` (for players who use focus for something else), or `none` (context picks the ring but actions go to your current target).

The trade-off is honest: capturing into focus clobbers an existing focus. There is no API to save and restore it, so the option exists rather than a workaround.

### 8.3 Two bonuses that fall out of the secure templates

- **Smart slices, zero snippets.** Blizzard's templates remap the button suffix by the unit's disposition when `harmbutton` / `helpbutton` are set. A single slice with `unit="focus"`, `harmbutton="harm"`, `helpbutton="help"`, `type-harm="spell"`, `spell-harm="Smite"`, `type-help="spell"`, `spell-help="Lesser Heal"` casts Smite on an enemy and Lesser Heal on a friend. Useful for a single "context" ring instead of two.
- **Auto-split a bar.** Out of combat, `C_ActionBar.IsHarmfulAction(slot)` and `IsHelpfulAction(slot)` classify every slot on a bar. One button in the editor builds "Bar 1 · offense" and "Bar 1 · support" rings from a bar, so context rings need no manual setup to try.

---

## 9. Visuals under secret values

Slices need icons, cooldown swipes, charge/count text, usable and out-of-range tints, and proc glows. In combat on Forever some of the numbers behind those are **secret**: they can be handed to a widget but not compared or computed with. Rules for the presentation layer:

- Pass through, never branch: `cooldown:SetCooldown(info.startTime, info.duration, info.modRate)`, `count:SetText(value)`, `icon:SetVertexColor(...)` driven by widget-side state. `if isUsable then …` on a secret raises an error; that is exactly the kind of code to avoid.
- Don't reinvent this. **LibActionButton-1.0** (the button implementation behind Bartender4 and others) supports `action`, `spell`, `item` and `macro` buttons in one code path and is maintained alongside Bartender4, which runs on Midnight; its buttons are `SecureActionButtonTemplate` frames, so they double as our slice buttons for mode B. Adopt it as the slice implementation; validate on the beta as the first spike item. Fallback if it misbehaves on Forever: inherit Blizzard's `ActionBarButtonTemplate` for bar slices (Dominos's approach; Blizzard's own untainted handlers do the painting).
- Selection highlight and pointer are cosmetic: an `OnUpdate` reading `GetCursorPosition()` (allowed for ordinary code) and recolouring textures.
- Cooldown *numbers* come from Blizzard's cooldown widget; no addon arithmetic on durations.

---

## 10. Input and bindings

- Bindable triggers: any key, `BUTTON3`…`BUTTON31`, with modifiers (`SHIFT-BUTTON4`). Left and right mouse buttons cannot be bound (Blizzard). Suggested default: **BUTTON4** (thumb). Gaming mice with 12-button thumb grids send keys, which also work.
- Multiple triggers, each with its own ring set and mode. Bindings live in `Bindings.xml` so they appear in Blizzard's keybinding UI, plus an in-addon quick bind.
- While a ring is open: the wheel is captured through override bindings on `MOUSEWHEELUP` and `MOUSEWHEELDOWN` that click the header (no camera zoom, no accidental bar paging on Blizzard's bar, and no mouse-enabled frame needed); Escape cancels the same way; modifiers can be read in the release snippet (`IsShiftKeyDown()`) for a "shift = tier 2" style hybrid.
- Right-click cancel needs a mouse-enabled frame under the cursor, and a mouse-enabled frame may also swallow the thumb button's release. Until `SetPassThroughButtons` is tested on Forever, every ring frame stays mouse-transparent in hold-and-release mode; right-click cancel arrives with mode B in M2.
- Direction selection is computed from a screen-sized reference frame, so it works however far the cursor travels; nothing about it depends on a frame being under the cursor. Mode B's clickable slices will need mouse-enabled frames, sized to the ring only, so the world outside stays clickable.
- No cursor warping. There is no API to move the cursor; the ring opens where the cursor is, so no travel is needed.

---

## 11. Configuration and persistence

- Settings via SavedVariables, per character with named profiles; import/export strings for rings.
- Ring editor out of combat: drag from spellbook, bags or bars onto a slice (`GetCursorInfo()` / `ClearCursor()`), reorder by dragging, pick layout and mode per ring, assign context mapping per trigger. A "preview" toggle shows the ring centered on screen while editing.
- Options panel via Blizzard's `Settings` API. No Ace3 requirement; libraries: LibStub, CallbackHandler-1.0, LibActionButton-1.0.

---

## 12. Risks and unknowns to retire in the spike

1. **Down/up delivery from a mouse-button binding.** `SecureActionButton_OnClick` treats binding-delivered clicks as key presses and reads `useOnKeyDown` on every click (confirmed in source). Confirm in game that flipping `useOnKeyDown` in the pre-snippet gives "capture on down, fire on up" for `BUTTON4` as well as for keys.
2. **`$cursor` and `GetMousePosition` under UI scale.** Both scale-correct in source; confirm with a non-1 UI scale and a scaled ring.
3. **Mouseover loss once the ring is under the cursor.** Assumed; confirm. If it holds (expected), capture-on-press is mandatory for aimed rings, as designed.
4. **Secret values in LibActionButton on Forever.** Confirm no errors in combat for action, spell and item slices; otherwise fall back per section 9.
5. **Wheel events while the trigger button is held.** Expected to work (wheel events are not gated by button state); confirm with mode A.
6. **Stance and vehicle pages on Forever.** Read `GetBonusBarIndex()` and friends in the snippet rather than assuming Retail's numbers; verify Druid forms and Warrior stances at 60.
7. **Beta build regressions.** Secure snippets were broken before 70009; re-run the spike on each beta build.

---

## 13. Milestones

| Milestone | Delivers | Proves |
|---|---|---|
| **M0 · spike** (one file, built) | opener, screen and header frames; a 4+8 ring mirroring Bar 1 (stance-following) and Bar 2; `$cursor` open; direction release; wheel cycling and Escape through override bindings; `/rr` diagnostics; in combat on Forever beta and Retail | risks 1, 2, 5, 7 |
| **M1 · bar rings** | 4+8 layout, rings for Bars 1–8 with wheel cycling, LibActionButton slices, stance-following Bar 1 | risks 4, 6 |
| **M2 · modes** | modes B and C, dead zone, right-click/Escape cancel, auto-hide, per-trigger settings, Bindings.xml | |
| **M3 · context** | harm/help/none detection, capture-on-press (focus/target/none), smart slices, auto-split | risk 3 |
| **M4 · custom rings** | ring editor with drag-and-drop, nested rings, import/export, profiles, polish | |

Proposed layout:

```
RadicalRadial.toc          ## Interface: 16001, 120100
Bindings.xml               "Open radial" bindings
Core.lua                   saved variables, defaults, profiles, ring model
Secure.lua                 opener/screen/capture frames, snippets, frame refs
Ring.lua                   ring frames, geometry, tiers, nested rings
Slice.lua                  slice buttons (LibActionButton wrapper)
Context.lua                harm/help detection, capture macro, auto-split
Editor.lua                 ring editor (drag and drop, preview)
Options.lua                Settings panel
Libs/                      LibStub, CallbackHandler-1.0, LibActionButton-1.0
```

---

## 14. Decisions (made 2026-09-28)

1. **Default trigger**: `BUTTON4`.
2. **Default layout**: 4 + 8, mapping a bar exactly.
3. **Bar rings follow stance/vehicle paging** like the real Bar 1: yes.
4. **Context capture default**: focus.
5. **v1 scope**: bar rings with wheel paging first (M0–M2), context rings second (M3).

---

## 15. Sources

- Blizzard UI source 12.1.0 (69933), via github.com/Gethe/wow-ui-source: `Blizzard_RestrictedAddOnEnvironment/RestrictedEnvironment.lua`, `RestrictedFrames.lua`, `SecureHoverDriver.lua`, `SecureHandlerTemplates.xml`; `Blizzard_FrameXML/SecureTemplates.lua`; `Blizzard_ActionBar/Shared/ActionButton.lua`.
- github.com/Thunderz96/forever-addon-kit: README findings (build 69893/70009, interface 16001, Retail project, secret values, snippet fix, SavedVariables bug) and `data/forever_api.json` (frames and functions present on the beta).
- warcraft.wiki.gg: *SecureHandlers*, *Action slot*, *Secret values*, *Patch 12.0.0/API changes*, *World of Warcraft: Forever*.
- OPie user guide, townlong-yak.com/addons/opie/guide.
- Blizzard, "Carve a New Path with World of Warcraft: Forever"; Wowhead and Icy Veins coverage of the September 17, 2026 developer Q&A on addons.
