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
| Move and resize slices, in combat | `handle:SetPoint(point, otherHandle, relpoint, x, y)`, `handle:SetScale()`, `handle:Show()`, `handle:Hide()` (RestrictedFrames.lua; the relative frame must be protected) | The page snippet places the slices for the page's layout on every open and wheel notch (section 7.1), so a bar in 4 + 8 and a custom ring in 12 flat can follow each other on the wheel in combat. |
| Open the ring from an action bar | A macro `/click RadicalRadialMacro1`. The client's `/click` (SlashCommands.lua) calls `Button:Click("LeftButton", false)` on the named button: one up click per press of the macro, or a down click when the macro says `... LeftButton 1`. `SecureActionButton_OnClick` treats a click it cannot attribute to hardware as a key press and gates it on the button's own `useOnKeyDown` (SecureTemplates.lua). | The macro opener's wrap sets `useOnKeyDown` to match the phase of every click, so Blizzard's handler acts on whichever arrives (section 10). |

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
elseif r < 0.68 * R then tier, n, first = 1, ring:GetAttribute("innerCount"), 1
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

The three modes from the brief map onto the sandbox like this. Selection is always by **direction** from the ring centre (OPie's model), never by hitting an icon, so the ring frames stay mouse-transparent and nothing under them changes what the thumb button delivers.

| Mode | Gesture | Fire | Cancel | Depth |
|---|---|---|---|---|
| **hold** (default; the brief's "click and release") | press → move → release | release fires the slice in the cursor's direction | release in the dead zone or past the cancel radius; Escape | multi-tier by radius; nested rings by wheel (M4) |
| **tap** (the brief's "click and click" and "click and mouseover" folded together) | tap (press and release in the dead zone) → ring stays → move → press and release | the next release, wherever it lands between the dead zone and the cancel radius; hold-and-release still works from the first press | a press or a release in the dead zone or past the cancel radius; Escape; auto-hide N seconds after the cursor has left the ring | nested rings by releasing on a folder slice (section 7.3) |
| **macro** (0.6.0; any trigger, from an action bar) | press the macro's key, or click the macro on the bar → ring stays → move → press the key again, or left-click the ring | the second press, or the click, in the cursor's direction | a press or a click in the dead zone or past the cancel radius; a right click; Escape; auto-hide | nested rings as in tap mode |

Notes:

- **Pure hover-to-fire is not possible** (section 3.3). Tap mode is the closest legal form: hover selects, a tap confirms.
- The brief's "click, then click a slice" and "click, hover, click" collapse into one mode once selection is by direction: the confirming click is the trigger itself, aimed by the cursor. Firing with the left mouse button would need a mouse-enabled frame under the cursor (section 10), so it is not offered.
- Modes are per trigger. A thumb button can run hold mode for the bar rings while a keyboard key runs tap mode for a utility ring.
- Escape cancel is an override binding installed on open and cleared on close.
- Auto-hide uses Blizzard's secure hover driver (`ring:RegisterAutoHide(ttl)` from the open snippet). The driver only counts down after the cursor has been inside the frame's rect and left it, so the ring frame is sized to the square the ring occupies and registered after it is shown at the cursor. Whatever hides the ring (Close, Escape, auto-hide, `/rr preview`) runs the ring's `_onhide` snippet, which resets the open state and drops the temporary bindings.
- A ring is **waiting** whenever it is open with no button held: after the first tap, after a nested ring opened (in either mode), after the macro opened it. The header's `Rest` snippet handles that state in one place: it arms auto-hide with the trigger's delay (so hold mode uses the delay too, for nested rings), and shows the **clicker** when the trigger has *click to fire* on or the macro opened the ring. The clicker is a secure action button the size of the ring square that only exists while the ring waits; a left click on it fires the slice in the cursor's direction (the clicker performs the action itself, so the hardware-event rule holds), a right click cancels. It stays hidden for a held ring, so a thumb button's release still reaches its binding. Right-click cancel therefore exists exactly where it is safe: on a waiting ring.

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

Built in 0.5.0 (M4, first cut): a custom ring is `{ name, slices[1..12] }` with slices `{ kind = "spell", id }`, `{ kind = "item", id }` or `{ kind = "macro", name }` (a mount is stored as its spell), in the same 4 + 8 layout as a bar; wheel lists hold bar numbers and ring names side by side (`bars = { 1, 2, "Utility" }`). On the secure side a ring is bar code `8 + index` with a fixed page: every slice registers one LibActionButton state per ring past the fifteen action pages (state `15 + index`), so the page snippet, the wheel and the context lists treat rings and bars alike, and the library paints spell, item and macro slices with its own code. The release snippet copies the slice's `type` and the attribute LibActionButton names in `action_field` (`action`, `spell`, `item` or `macro`) onto the opener, clears `macrotext`, and Blizzard's handler does the rest.

0.6.0 adds `{ kind = "ring", name }` (a nested ring, section 7.3), a `layout` per ring (section 7.1) and sixteen slots per ring (a layout shows the first inner + outer of them; the rest are kept but not shown). A nested-ring slice is an empty LibActionButton state plus a `sub-<state>` attribute on the slice holding the target's bar code; the page snippet copies it to the slice's `subring`, and the presentation paints a folder icon and the ring's name over the empty slot from that attribute. `macrotext` slices are not built.

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

Default: 4 + 8. **Built in 0.6.0** as seven presets, `4+8`, `12`, `8`, `6`, `4`, `6+6` and `8+8` (inner + outer; single tiers have no boundary, everything past the dead zone selects by direction): a trigger's `layout` says how it shows bars (a smaller layout shows the bar's first slots, 8 + 8 leaves four empty), and each custom ring carries its own. The ring has sixteen slice buttons; the page snippet places the ones the layout uses (`SetScale`, `SetPoint` against the scaled parent, `Show`) and hides the rest, on every open and wheel notch, so the layout can change with the page in combat. The inner icon ring sits at `max(0.40, 0.058 n) R` so eight inner icons do not touch (0.46 R). The secure side gets a layout as `inner * 100 + outer` (`layoutofbar<code>` on the header for rings, `layout` on the opener for bars) and stores the tier sizes it applied as `incount` and `outcount`, which the release snippet and the presentation both read.

### 7.2 Bands

Measured in ring radius `R` (the outer icon circle):

- `r < 0.15 R`: dead zone. Release here = cancel. Large enough that a nervous release does nothing.
- `0.15 R ≤ r < 0.68 R`: inner tier. The inner icons end at `0.55 R`; the boundary sits midway through the gap to the outer icons (which begin at `0.82 R`), so the cursor keeps the inner slice for a little way past its icon (0.5.1; 0.55 up to 0.5.0, which switched tiers at the icon's edge).
- `0.68 R ≤ r ≤ outer · R`: outer tier. The outer icons end at about `1.2 R`, so a hard flick still lands in its sector.
- `r > outer · R`: past the cancel radius (0.4.2). Nothing is selected, the ring dims, and a release or a tap out there cancels, so moving away from the ring is a way to abort without finding the centre. `outer` is a setting (`/rr outer`, 1.2 to 3, default 1.6), carried on the header as an attribute so the release snippet and the presentation layer read the same value.

Sector 1 is at 12 o'clock, clockwise, matching how people read a bar left-to-right around a clock face. The presentation layer draws icons at sector centers and a pointer from the center toward the cursor.

### 7.3 Nested rings

Built in 0.6.0. A `{ kind = "ring", name }` slice draws a folder icon with the ring's name. It opens on the same gesture that fires any other slice, in every mode: releasing on it (hold or tap), a second macro press over it, or a left click on a waiting ring. The header's `OpenSub` snippet sets `sub` to the target's bar code, re-runs the page snippet (which shows the target ring with its own layout, aimed at the same captured unit), re-centres the ring on the cursor and leaves it waiting (`Rest`). So in hold mode a nested ring costs one extra press-and-release; there is no hover-to-open, which would need a mouse-enabled hit box under a held thumb button (section 10), and there is no second tier boundary to learn.

Going back: a press (or right click) in the dead zone of a nested ring runs `LeaveSub`, which brings the ring it came from back at the cursor, still waiting; a second one closes the ring. The wheel leaves a nested ring first and then pages the wheel list, since a nested ring is not on it. Escape closes everything. Any depth works (a ring can nest a ring that nests a ring; a ring cannot nest itself, and a slice whose target no longer exists is dropped on load, on remove and on import). The label reads `Potions « Utility` while a nested ring shows.

The hover-to-open variant is still possible later (an `_onenter` snippet on mouse-enabled hit boxes with `SetPassThroughButtons` for the thumb buttons), but the release-to-open form needs nothing that is untested on Forever.

---

## 8. Context-aware rings

Built in M3 for bar rings: each trigger has a **harm** and a **help** bar list (empty means "use the normal bars") and a **capture** setting.

### 8.1 Detection

At press time the snippet classifies the unit under the cursor:

```lua
local ctx = "none"
if UnitExists("mouseover") and not UnitIsDead("mouseover") then
  if     PlayerCanAttack("mouseover") then ctx = "harm"
  elseif PlayerCanAssist("mouseover") then ctx = "help" end
end
if ctx ~= "none" and self:GetAttribute(ctx .. "count") == 0 then ctx = "none" end
```

Each trigger maps `harm`, `help` and `none` to a bar list. This uses only macro-conditional-grade checks (`PlayerCanAttack` is `UnitCanAttack("player", unit)` inside the sandbox), which Midnight's restrictions leave alone. The wheel cycles within the context's list, and the label says which context is showing and what it aims at (`Bar 3 · enemy @focus`).

### 8.2 Aiming: capture on press

The obvious approach, `unit = "mouseover"` on the slices, does not survive the ring opening: the moment the cursor moves onto the ring, the world unit under it is gone and `mouseover` is empty. OPie's answer is the right one, and the sandbox makes it clean:

- The **down-click** is itself a hardware event, so the opener performs a real action on it. The press snippet sets `useOnKeyDown = true`, `type = "macro"` and `macrotext = "/focus [@mouseover,exists,nodead]"` (or `/target …`) and lets Blizzard's handler run; the release snippet sets `useOnKeyDown = false` again before it decides anything, so the release fires the slice as usual. Capture only happens when the context came out as `harm` or `help` and the trigger has a ring for it.
- Slices in a context ring carry `unit = "focus"` (or `"target"`), set by the page snippet on every page change and cleared when a plain ring opens. Blizzard's action handler passes it to `UseAction(slot, unit)`. The range tint does not follow it: the 12.x client reports range against the current target only (section 9).
- Blizzard's click handler (`GetConvertedButtonUnitAndActionType` in SecureTemplates.lua) drops the whole click when the button's `unit` names a unit that does not exist. The opener's `unit` keeps whatever the last release aimed at, so in 0.4.0 a target-capture press made with no current target never ran its macro (a focus usually persists, which is why focus capture seemed fine). The press snippet now clears `unit` before handing the capture click to Blizzard, and a cancelled release clears it too.
- Per-trigger option, **capture as**: `focus` (default; leaves your target alone; Forever has focus), `target` (for players who use focus for something else), or `none` (context picks the ring but actions go to your current target).

The trade-off is honest: capturing into focus clobbers an existing focus. There is no API to save and restore it, so the option exists rather than a workaround.

### 8.3 Two bonuses that fall out of the secure templates (M4)

- **Smart slices, zero snippets.** Blizzard's templates remap the button suffix by the unit's disposition when `harmbutton` / `helpbutton` are set. A single slice with `unit="focus"`, `harmbutton="harm"`, `helpbutton="help"`, `type-harm="spell"`, `spell-harm="Smite"`, `type-help="spell"`, `spell-help="Lesser Heal"` casts Smite on an enemy and Lesser Heal on a friend. Useful for a single "context" ring instead of two.
- **Auto-split a bar.** Out of combat, `C_ActionBar.IsHarmfulAction(slot)` and `IsHelpfulAction(slot)` classify every slot on a bar. One button in the editor builds "Bar 1 · offense" and "Bar 1 · support" rings from a bar, so context rings need no manual setup to try. **Built in 0.5.0** as "Fill from bar" with an everything / offensive only / helpful only choice (`/rr ring fill NAME BAR [harm|help]`); a bar's spells, items, macros (by name) and mounts (as their spell) become direct slices, flyouts and pet actions are skipped. Smart slices are not built.

---

## 9. Visuals under secret values

Slices need icons, cooldown swipes, charge/count text, usable and out-of-range tints, and proc glows. In combat on Forever some of the numbers behind those are **secret**: they can be handed to a widget but not compared or computed with. Rules for the presentation layer:

- Pass through, never branch: `cooldown:SetCooldown(info.startTime, info.duration, info.modRate)`, `count:SetText(value)`, `icon:SetVertexColor(...)` driven by widget-side state. `if isUsable then …` on a secret raises an error; that is exactly the kind of code to avoid.
- Don't reinvent this. **LibActionButton-1.0** (the button implementation behind Bartender4 and others) supports `action`, `spell`, `item` and `macro` buttons in one code path and is maintained alongside Bartender4, which runs on Midnight; r160 also names Forever explicitly. Its buttons are `SecureActionButtonTemplate` frames, so they double as our slice buttons. Adopted in M1 (vendored under `Libs/`, with LibStub and CallbackHandler-1.0). LibButtonGlow-1.0 is optional and not vendored, so proc glows only appear when another addon provides the library. Fallback if it misbehaves on Forever: inherit Blizzard's `ActionBarButtonTemplate` for bar slices (Dominos's approach; Blizzard's own untainted handlers do the painting).
- Selection highlight and pointer are cosmetic: an `OnUpdate` reading `GetCursorPosition()` (allowed for ordinary code) and recolouring textures.
- Cooldown *numbers* come from Blizzard's cooldown widget; no addon arithmetic on durations.
- Out-of-range tint: LibActionButton r160 still polls `IsActionInRange`, which the 12.x client no longer answers usefully for addons (Blizzard's own buttons stopped calling it in 10.1.5). Ring.lua asks the client to watch the slots the ring shows (`C_ActionBar.EnableActionRangeCheck`) and feeds `ACTION_RANGE_CHECK_UPDATE` into each slice's `IsInRange`, so the library's range loop and tint code run unchanged. The flag is per slot and shared with Blizzard's bars, which clear it for slots they stop showing, so the ring asserts it again on every open.

---

## 10. Input and bindings

- Bindable triggers: any key, `BUTTON3`…`BUTTON31`, with modifiers (`SHIFT-BUTTON4`). Left and right mouse buttons cannot be bound (Blizzard). Suggested default: **BUTTON4** (thumb). Gaming mice with 12-button thumb grids send keys, which also work.
- Multiple triggers (up to four), each with its own bar list, mode and auto-hide delay, on its own opener button (`RadicalRadialOpener1`…`4`) so the release snippet knows which trigger it serves. Pressing one trigger while another's ring is open cancels that ring. Bindings live in `Bindings.xml` so they appear in Blizzard's keybinding UI (the `header` attribute goes on the first entry only; the client warns "loaded more than once" when it is repeated), plus `/rr [n] bind KEY` and the settings window's key capture.
- While a ring is open: the ring itself is a `SecureHandlerMouseWheelTemplate` (`EnableMouseWheel` without `EnableMouse`, so clicks still pass through) and pages in `_onmousewheel`, one notch per event, before any chat or scroll frame underneath can see it. Override bindings on `MOUSEWHEELUP` and `MOUSEWHEELDOWN` that click the header stay as the fallback for a cursor past the ring's edge; a bound key clicks on its press and again on its release, so only the press counts there. Either way there is no camera zoom and no paging of Blizzard's bar. Escape cancels through the same binding mechanism; modifiers can be read in the release snippet (`IsShiftKeyDown()`) for a "shift = tier 2" style hybrid.
- Right-click cancel needs a mouse-enabled frame under the cursor, and a mouse-enabled frame may also swallow the thumb button's release. Every ring frame therefore stays mouse-transparent while a trigger is held. A **waiting** ring (section 5) may take the mouse instead: the clicker (0.6.0), a `SecureActionButtonTemplate` child of the ring the size of its square, registered for up clicks of any button, with its own `_onmousewheel` so the wheel keeps paging while it is on top. Its wrapped `OnClick` resolves the slice under the cursor like a release does, copies the slice onto the clicker itself (`Fire`) and lets Blizzard's handler act; a right click cancels or goes back from a nested ring. It is shown by `Rest` only for a ring the macro opened or a trigger with *click to fire* on, and hidden again by every open, so `SetPassThroughButtons` is not needed: a thumb button pressed over a waiting ring lands on the clicker, which fires the slice like any other button, and pressed over a held ring reaches its binding as before.
- Direction selection is computed from a screen-sized reference frame, so it works however far the cursor travels; nothing about it depends on a frame being under the cursor.
- **From an action bar** (0.6.0): each trigger also has a macro opener, `RadicalRadialMacro<i>`, a `SecureActionButtonTemplate` button for the macro `/click RadicalRadialMacro<i>`. The client's `/click` delivers one click per press of the macro (up, unless the macro adds `1`), so the macro opener's wrap sets `useOnKeyDown` to the click's own phase and then treats every click as a whole gesture: with the ring closed it opens it (running the capture macro on that same click when the trigger has a ring for the unit under the cursor, as the key opener does on its press) and leaves it waiting; with the ring open it fires the slice under the cursor (onto itself), opens a nested ring, goes back, or cancels, exactly as a release or a click would. The trigger's settings stay on its key opener; the macro opener only knows its trigger index. `/rr macro create` (or the window's button) makes the macro, `Radial <i>`, with `CreateMacro` (or updates it with `EditMacro`) and puts it on the cursor with `PickupMacro`, out of combat. A macro on a bar can carry conditionals (`/click [combat] RadicalRadialMacro1; RadicalRadialMacro2`), and the macro can be pressed with the mouse: the ring opens around the bar button and, since the macro path always shows the clicker, a click on the ring fires.
- No cursor warping. There is no API to move the cursor; the ring opens where the cursor is, so no travel is needed.

---

## 11. Configuration and persistence

- Settings via SavedVariables, one account-wide file (`RadicalRadialDB`) with a per-character part (0.5.1). Account-wide: `scale`, `outer`, `debug`, `triggers[]` with `key`, `capture`, `mode`, `autohide`, `layout` and `click` (0.6.0) and a stable `id`. Per character, under `chars["Name-Realm"]`: `rings[]` with `name`, `layout` (0.6.0) and `slices` (sixteen), and `lists[id]` with that trigger's `bars`, `harm` and `help` (bar numbers and ring names). Rings hold class spells, so they belong to a character; the wheel lists name rings, so they follow; which button opens the ring and how it behaves is the same everywhere. At runtime the trigger tables carry the current character's lists (`ns.AttachCharacter`), so the rest of the addon reads and writes `t.bars` as before, and `NormalizeTrigger` keeps the character's saved copy pointing at them. A character seen for the first time starts with the lists the last character saved, minus rings it lacks; rings saved by 0.5.0 (then shared) go to the first character that logs in with 0.5.1. Saved variables from earlier layouts are migrated on load; bad rings, slices and dangling ring references are dropped; reset clears the shared settings and the current character only. Named, shareable profiles remain second-cut work. Import/export strings for rings (built, 0.5.0): `RR1:<name>:<12 slices>` with `s<spell id>`, `i<item id>`, `m<macro name>` or `-`, names escaping `%`, `,` and `:`; 0.6.0 writes `RR2:<name>:<layout>:<16 slices>` with `r<ring name>` for a nested ring, and still reads `RR1`. A nested ring the importing character does not have is dropped from the string with a chat line. Copying between characters (0.5.1) reads the other character's entry straight from the saved variables: a menu in the editor (`MenuUtil.CreateContextMenu`, one submenu per character) or `/rr ring copy CHARACTER NAME`.
- Ring editor (built, 0.5.0, Editor.lua): the "Custom rings" tab shows a ring as the 4 + 8 slot layout. Dropping uses `GetCursorInfo()` (a spell's id is the fourth return, a mount's comes from `C_MountJournal.GetMountInfoByID`) and `ClearCursor()`; clicking or dragging a filled slot puts its content back on the cursor (`C_Spell.PickupSpell`, `C_Item.PickupItem`, `PickupMacro`) and empties the slot, so a drop on another slot moves and a drop on a filled slot swaps; right-click clears. Slot art is Blizzard's `UI-HUD-ActionBar-IconFrame` atlases when `C_Texture.GetAtlasInfo` knows them. Renaming follows every wheel list that names the ring; removing strips it from them. Per-ring layout (0.6.0): a row of radios under the name; the slot buttons are placed for the layout like the live ring's slices. Nested rings (0.6.0): right-click an empty slot for a `MenuUtil` menu of the other rings; a nested slot shows the folder icon and the ring's name, a click on it reopens the menu (with Clear), a right-click clears it, and it has no cursor form, so it is never picked up. The trigger page gained a Bar layout row, a Click to fire box and, under the binding, the trigger's macro with a Create macro button.
- Settings window and the client's panels (0.5.1): the window used to sit on `UISpecialFrames` so that Escape closed it, but on Forever the client also empties that list when it opens some of its own panels; the spellbook did, which is exactly when the ring editor is in use. The window now handles Escape itself out of combat: its keyboard is enabled whenever it is shown, every key propagates to the game except the ones it keeps (a capture, Escape), and since whether a key propagates is decided after the handler returns and `SetPropagateKeyboardInput` is protected in combat, a kept key switches propagation off and a `C_Timer.After(0)` switches it back on the next frame. In combat the window joins `UISpecialFrames` (at `PLAYER_REGEN_DISABLED`, leaving again at `PLAYER_REGEN_ENABLED`) so Escape keeps working through Blizzard's path. As insurance a post-hook on `ShowUIPanel` puts the window back if it was hidden in the same frame as a panel opened, unless the panel is the game menu or full-screen; `/rr debug` reports when that fires.
- Settings window (built, 0.4.0): `/rr` opens a standalone window (`ButtonFrameTemplate` with the portrait hidden; `BasicFrameTemplateWithInset` no longer exists in 12.1) with the ring scale, debug toggle, preview and reset, and one page per trigger: key capture (keyboard chords through `CreateKeyChordStringUsingMetaKeyState`, mouse buttons 3 and up through `GetConvertedKeyOrButton`, Escape cancels, left and right are refused, the keyboard is only captured while binding so Escape otherwise closes the window), hold/tap radios, an auto-hide slider, bar checkboxes that keep the order they were ticked in, enemy and friend rings, the capture choice, add and remove. It calls the same setters as the slash commands (`ns.SetTrigger*`, `ns.SetScale`, … in Config.lua) and `ApplyConfig` refreshes it, so the two never disagree; in combat the setters save and defer, and the footer says so. The Options → AddOns entry is a canvas page with a button to the window (`Settings.RegisterCanvasLayoutCategory`), and `## AddonCompartmentFunc` puts it on the minimap's addon button. No Ace3 requirement; libraries: LibStub, CallbackHandler-1.0, LibActionButton-1.0.

---

## 12. Risks and unknowns to retire in the spike

Status as of 2026-09-28, from the M0 spike on Forever beta build 1.60.1.70009.

1. **Down/up delivery from a mouse-button binding.** `SecureActionButton_OnClick` treats binding-delivered clicks as key presses and reads `useOnKeyDown` on every click (confirmed in source). **Confirmed in game:** `BUTTON4` delivers both clicks, the wrap swallows the down click, the release fires the action.
2. **`$cursor` and `GetMousePosition` under UI scale.** Both scale-correct in source. **Confirmed in game at ring scale 1.4** (`/rr scale`) **and under a non-default UI scale** (0.4.1): the ring scales with the UI and the highlighted slice matches the one the secure side fires.
3. **Mouseover loss once the ring is under the cursor.** Assumed; the ring frames are mouse-transparent, so the world unit under the cursor may in fact survive, but capture-on-press does not depend on it either way. What M3 needs confirmed in game: the `/focus [@mouseover,exists,nodead]` macro runs on the down click of a mouse-button binding (with `useOnKeyDown` flipped on for that click) and the release still fires the slice on `focus`. **Confirmed in game (0.4.0)** for focus, harm and help rings, **and for target capture in 0.4.1**, which had failed until then because of the click handler's unit check (section 8.2).
4. **Secret values in LibActionButton on Forever.** LibActionButton-1.0 r160 declares Forever support (`buildInfo >= 16001 and buildInfo < 20000` is treated as Mainline, with the 12.0 duration objects and display-count APIs). Confirm no errors in combat for action slices; otherwise fall back per section 9. **Cooldowns and charges confirmed in game (0.4.0), no errors; the range tint confirmed in 0.4.1** through the event path of section 9.
5. **Wheel events while the trigger button is held.** **Confirmed in game:** wheel override bindings page the ring while `BUTTON4` is held, and the camera does not zoom. Up to 0.4.0 notches were unreliable (some dropped, some doubled); 0.4.1 lets the ring take the wheel itself and keeps the binding as the fallback (section 10), with `/rr debug` naming the path each notch took. **Confirmed reliable in 0.4.1.**
6. **Stance and vehicle pages on Forever.** Read `GetBonusBarIndex()` and friends in the snippet rather than assuming Retail's numbers; verify Druid forms and Warrior stances at 60. `/rr status` prints what the client reports so the numbers can be compared with the ring. **Open.**
7. **Beta build regressions.** Secure snippets were broken before 70009. **Confirmed working on 70009**; re-run the spike on each beta build.

---

## 13. Milestones

| Milestone | Delivers | Proves |
|---|---|---|
| **M0 · spike** (done; confirmed in game) | opener, screen and header frames; a 4+8 ring mirroring Bar 1 (stance-following) and Bar 2; `$cursor` open; direction release; wheel cycling and Escape through override bindings; `/rr` diagnostics; in combat on Forever beta and Retail | risks 1, 2, 5, 7 |
| **M1 · bar rings** (built) | 4+8 layout, rings for Bars 1–8 with wheel cycling, LibActionButton slices with one state per action page, stance-following Bar 1, files split by layer | risks 4, 6 |
| **M2 · modes** (built) | hold and tap modes, dead zone, Escape cancel, auto-hide through the secure hover driver, up to four triggers each with key, bars, mode and auto-hide, Bindings.xml entries per trigger, saved-variable migration | |
| **M3 · context** (built) | harm/help/none detection, per-trigger harm and help bar lists, capture-on-press (focus/target/none), slices aimed at the captured unit | risk 3 |
| **Settings window** (built, 0.4.0) | `/rr` window with key capture, per-trigger pages, shared setters with the slash commands, Options → AddOns entry, addon compartment button; the `Bindings.xml` header fix | |
| **0.4.1, 0.4.2** (built) | target capture fix, range tint through the client's range-check events, the ring takes the wheel itself, the cancel radius | risks 2, 3, 4, 5 confirmed |
| **M4 · custom rings, first cut** (built, 0.5.0; drops, move/swap/clear and fill-from-bar confirmed in game) | named rings of direct spell/item/macro slices as LibActionButton states, rings in the wheel and context lists by name, the drag-and-drop editor tab, fill-from-bar with the offensive/helpful filter, import/export strings, `/rr ring` commands | risk 4 for spell and item slices |
| **0.5.1** (built; boundary and window confirmed in game, per-character storage untested on a second character) | rings and wheel lists per character with copy-from-character, the tier boundary moved off the inner icons' edge, the settings window no longer closed by the spellbook | |
| **0.6.0** (built; passes the harness, not yet tried in game) | layouts (seven presets, per trigger for bars and per custom ring; slices placed by the page snippet), nested rings (release-to-open, centre to go back, wheel to leave), the macro opener (`/click RadicalRadialMacro<i>` from an action bar, `/rr macro create`), the clicker and click to fire, `RR2` strings | slice `SetPoint`/`SetScale` from a snippet in combat; `/click` delivery and `useOnKeyDown` on a virtual click; a mouse-enabled child of the ring taking a thumb button's click |
| **M4 · second cut** | smart slices (`harmbutton`/`helpbutton`), profiles, `macrotext` slices, hover-to-open for nested rings if `SetPassThroughButtons` proves out, polish | |

Layout. The `RadicalRadial/` folder is the addon and drops into `Interface/AddOns`; the design doc and the offline harness (`tools/`) live beside it at the repository root and never ship.

```
RadicalRadial/
  RadicalRadial.toc        ## Interface: 16001, 120100
  Bindings.xml             "Open radial" bindings
  Core.lua                 namespace, constants, defaults, saved variables, geometry
  Rings.lua                custom rings: validation, layouts, nested-ring targets, wheel lists, the cursor and action slots as sources, codec, setters
  Ring.lua                 ring frames, sixteen LibActionButton slices, the clicker, presentation (highlight, label, folder art, cursor tracking)
  Secure.lua               opener, macro opener and header frames, snippets (open, page and layout, nested rings, fire, pick), frame refs
  Config.lua               applying settings, events, the setters both UIs share, /rr commands, status
                           (context detection and capture live in Secure.lua's snippets)
  Options.lua              settings window, Options → AddOns page, addon compartment entry
  Editor.lua               the "Custom rings" tab: slots in the ring's layout, drag and drop, the nested-ring menu, fill from bar, import/export
  Libs/                    LibStub, CallbackHandler-1.0, LibActionButton-1.0 (vendored, unmodified)
tools/                     offline harness (tools/check.py runs tools/harness.lua)
DESIGN.md, README.md
```

Bar paging with LibActionButton: every slice registers 15 states out of combat, state *p* = action slot `(p - 1) * 12 + i` (slices 13-16 are empty on every bar page). Switching bars in combat is then `slice:RunAttribute("UpdateState", p)` followed by `slice:CallMethod("UpdateAction")` from the header snippet, the same path Bartender4's state headers use, so the library's own painting code (icons, cooldown duration objects, display counts, usable and range tints) runs unchanged; every slice follows the page, shown or not, so a hidden slice never keeps a stale action. The harness swaps the library for a small fake that keeps this contract and runs the real `UpdateState` snippet extracted from the vendored file.

Attribute names are case-insensitive in the client. `SetAttribute("Open", snippet)` followed by `SetAttribute("open", false)` leaves one attribute holding `false`, and `RunAttribute("Open")` then fails with "Invalid snippet body" (RestrictedFrames.lua:755), which is exactly how 0.3.0 failed on its first press. Snippet attributes therefore use names no state flag can take (`Resolve`, `ApplyPage`, `StepPage`, `OpenRing`, `CloseRing`), and the harness lowercases attribute names too.

A secure action button's `unit` attribute is a precondition, not just a target: Blizzard's click handler returns before doing anything when that unit does not exist. Any attribute the release snippet leaves on the opener is still there on the next press, so the press snippet clears `unit` before it hands a capture click to Blizzard, and the harness's fake handler enforces the same rule. The same goes for `macro`: the handler runs a named macro before it looks at `macrotext`, so after a macro slice's release the capture click would run that macro again unless the press snippet clears it first, which it does.

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
