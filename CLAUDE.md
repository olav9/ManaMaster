# ManaMaster

ManaMaster is a World of Warcraft addon for mana tracking and management.

## Target game version

- The addon targets **World of Warcraft: Forever**, a new version of WoW.
- WoW Forever uses the **current retail WoW API**. Write code against retail APIs, not Classic APIs.
- The client reports interface/build **16001**. Keep `## Interface: 16001` in `ManaMaster.toc`. This is correct even though it doesn't follow the usual 6-digit retail format.

## Structure

One codebase serves several clients. Each client gets its own TOC, which loads the shared files plus that client's mana file.

- `ManaMaster.toc`: addon manifest for WoW Forever (interface 16001). SavedVariables: `ManaMasterDB`. Loads `ManaMaster.lua`, `Mana_Forever.lua`, `HistoryPanel.lua` and `MinimapButton.lua`.
- `ManaMaster.lua`: shared core: fight lifecycle and naming, per-spell spending from casts, pre-combat casts, buff uptime (`REGEN_BUFFS`, `ScanAuras`), readable-mana delta tracking, history, the on-screen display and mana bar, the chat summary, events, and the slash commands `/mm` and `/manamaster`. It exposes helpers and state through the addon namespace `ns`: `ns.current` is the running fight, and `ns.debugMode`, `ns.Debug`, `ns.IsReadable` and others are shared helpers. It calls the client's `ns.Mana.*` hooks, documented at the top of the file.
- `Mana_Forever.lua`: the WoW Forever implementation of `ns.Mana`: the estimated mana pool, the regen and five-second rule, full-mana detection, potion estimates (`KNOWN_MANA_RESTORES`) and regen blockers (`REGEN_BLOCKERS`). Everything that exists because mana is secret there.
- Planned: `ManaMaster_TBC.toc` (interface **20506**, confirmed in the TBC Anniversary client) and `Mana_TBC.lua`. TBC has readable mana and the combat log, per Details' TBC setup; this isn't tested yet.
- `HistoryPanel.lua`: fight history window (`/mm`). Loaded after `ManaMaster.lua`. Provides `ns.ToggleHistory`, `ns.RefreshHistory` and `ns.ShowNewestFight`. The panel shows the newest fight when it opens, and switches to each new fight as it ends while open.
- `MinimapButton.lua`: draggable minimap button that toggles the history panel. Created from `OnAddonLoaded` once `ManaMasterDB` exists. Position is saved in `ManaMasterDB.minimapAngle`.

## How tracking works

- A fight starts on `PLAYER_REGEN_DISABLED` or `ENCOUNTER_START`. It ends on `PLAYER_REGEN_ENABLED`, or on `ENCOUNTER_END` if a boss encounter is active.
- Total spent/recovered comes from `UNIT_POWER_FREQUENT` mana deltas. The per-spell breakdown comes from `UNIT_SPELLCAST_SUCCEEDED` plus `C_Spell.GetSpellPowerCost`.
- The combat log (`COMBAT_LOG_EVENT_UNFILTERED`) is not available. On WoW Forever, registering for it triggers the "blocked from an action only available to the Blizzard UI" pop-up (confirmed in game). Don't register it, not even behind a debug flag.
- Values may be "secret" during combat on retail. Guard reads with `issecretvalue`.
- On WoW Forever, the player's current mana (`UnitPower`) is secret in and out of combat (confirmed in game). `UnitPowerMax` is readable. When mana is hidden at any point in a fight, the total spent falls back to the sum of listed spell costs (`castSpent`), and recovered/lowest mana aren't recorded (`nil`).
- WoW Forever uses the retail regen model: regen is continuous, with no 2-second ticks, but the five-second rule still applies.
- Passive regen is estimated, not measured, since mana is hidden. `GetManaRegen()` gives rates per second (inactive, active). The addon applies the active rate for 5 seconds after each mana-cost cast (five-second rule) and the inactive rate otherwise. The result is stored as `fight.regen`. Rates are cached from the last readable read. Potions, Innervate and similar bursts are not included, so the simulated pool can read lower than the real one after using them.
- The addon keeps a running estimate of the mana pool (`pool` in `ManaMaster.lua`) at all times, not just in fights. A 1-second ticker (`OnPoolTick`) advances it with regen (`AdvancePool`, which applies the five-second rule), and casts and potions adjust it in and out of combat.
  - **Initial value:** full mana at login or reload (`InitPool`), with `pool.confirmed = false`.
  - **Anchoring:** `AnchorPool` sets a known value in two cases. The first is a readable mana reading, never seen on WoW Forever. The second is **full-mana detection** (`CheckFullMana`, out of combat only): mana events (`UNIT_POWER_FREQUENT`) fire continuously while mana regenerates and stop once it's full. So no mana event for `max(2 s, time to regen 3 mana)` means full. The quiet window has to fall outside the five-second rule, because regen is about 0 there and events stop too. This means resting or drinking to full is detected.
  - **Fight start:** `fight.startMana` comes from the pool. `fight.startManaAssumed` is true only if the pool was never anchored since login.
  - **During the fight:** casts subtract their cost, and regen adds up to max mana. Pre-combat casts are already out of the pool when they're added to the fight (`AddCast(..., inPool = true)`).
  - **Wasted regen:** regen past max goes to `fight.wastedFull`. While a `REGEN_BLOCKERS` debuff is up, all regen goes to `fight.wastedBlocked`, using the rates from before the debuff. `REGEN_BLOCKERS` is a table of English debuff names; it's empty until specific effects are identified.
  - `fight.regen` only counts regen that actually fit in the pool.
- Potions, runes and gems are estimated.
  - On `UNIT_SPELLCAST_SUCCEEDED` during a fight, `GetManaRestore` parses the spell's English description for `^Restores X to Y mana` or `^Restores X mana`, and skips drinks ("over N sec"). Results are cached per spell ID.
  - `KNOWN_MANA_RESTORES` is a fallback for when the description can't be read. It has spell 437, Minor Mana Potion, at 140-180.
  - The average goes into `fight.gains[spellID]` (the same entry shape as spells, with the range as `rank`) and into the simulated pool. Overflow past max counts toward `wastedFull`.
  - `ns.RestoredTotal` sums the gains for the chat summary and the panel's Net.
- Regen buff uptime is tracked by scanning player buffs on `UNIT_AURA` against `REGEN_BUFFS`, a table of English buff names at the top of `ManaMaster.lua`. It's stored per fight as `fight.buffs[name] = { uptime, spellID, icon }` and shown as a fourth panel section with its own 0-100% bar scale.
- In combat, `C_UnitAuras.GetAuraDataByIndex` throws "Auras cannot be accessed when secret" for some buffs (seen with Blood Fury). It doesn't return a secret value for them. Always call it through `pcall` and skip the slot on error.
- Fights are named after the boss encounter. Otherwise they use the first hostile target, at combat start or via `PLAYER_TARGET_CHANGED`, and fall back to "Combat". Target names are readable on WoW Forever (confirmed in game).
- WoW Forever has spell ranks, and each rank has its own spell ID and cost. `fight.spells` is keyed by spell ID, and each entry stores `name` and `rank` (from `C_Spell.GetSpellSubtext`). Fights saved before this change are keyed by spell name and have no `name`/`rank` fields; `SortedEntries` handles both.
- The history panel shows three sections: spent (`fight.spells`), gained (`fight.recovered` or `fight.regen`, plus `fight.gains`) and drained (`fight.drains`). `fight.gains` holds the potion estimates. `fight.drains` uses the same entry shape but nothing fills it: drains can't be detected on this client, but the section is kept on purpose. Without the combat log, exact gains and drains can't be measured. Only estimates from the player's own casts and auras are possible.
- Fight history is stored in `ManaMasterDB.fights` (the last 50 fights).
- The end-of-fight chat summary and the on-screen display are **debug-only** (`/mm debug`). `/mm last` still prints the last summary on request. There's no separate summary setting anymore; the old `printSummary` saved setting is ignored.
- The on-screen display shows the spent number with a live mana bar under it (`UpdateManaBar`).
  - The bar passes the secret `UnitPower` value straight to `StatusBar:SetValue` and to `FontString:SetText` via `AbbreviateNumbers`, without reading it. Current and max mana use separate font strings, since a secret can't be joined into a string.
  - It's wrapped in `pcall`; if the client refuses, the bar hides for the session.
  - Confirmed working in game on WoW Forever, so rendering secret values this way works on this client.
  - It updates on `UNIT_POWER_FREQUENT` and `UNIT_MAXPOWER` while the display is shown.

## Combat log chat tab experiment (concluded: dead end)

**Result:** combat event lines in the Combat Log window's history are stored as protected placeholder tokens such as `|Ky1494|k`. The client swaps these for text only when drawing. `GetMessageInfo` returns ordinary strings, but they only hold the token (confirmed in game with `/mm scanlog`). Only non-combat system lines (`… dies, you gain 84 experience.`, `Your Lightning Bolt failed. (Your target is dead)`) are plain text. So addons can't read combat log text on WoW Forever: registering is blocked, live lines bypass Lua hooks, and stored lines are placeholders. Mana gains and drains from other sources must be estimated from the player's own casts (e.g. potion spell 437) and auras.

The experiment code has been removed from the addon: the Combat Log tab hooks in `/mm debug` and the `/mm scanlog` command. The notes below refer to it as it was.

Notes from the experiment:


- Blizzard's Combat Log chat tab is `ChatFrame2` (`COMBATLOG == ChatFrame2`, and `Blizzard_CombatLog` is loaded). `/mm debug` post-hooks its `AddMessage` and `BackFillMessage` with `hooksecurefunc`. This doesn't trigger the blocked pop-up.
- Lines refilled into the tab (`BackFillMessage`) are **readable** strings (confirmed in game).
- During a fight with the tab in the background, no lines arrived through either hook. The likely reason is that Blizzard only writes live lines while the tab is shown and backfills when it's opened. This is unconfirmed.
- Drinking produces no combat log lines at all, which fits the retail regen model where drinking is a regen-rate buff.
- A Minor Mana Potion fires `UNIT_SPELLCAST_SUCCEEDED` with spell **437** ("Restore Mana"), even with mana hidden. The Combat Log tab shows it as `Your Restore Mana energized You 160 (Mana).` (English client, the "Power Gains" filter option on). Its cast line is `You cast Restore Mana.` When the gain overflows max mana, the line ends with the wasted part: `Your Restore Mana energized You 120 (Mana). (43 Overenergized)`.
- There is one Combat Log window, and it holds only what the **currently selected filter** shows. Blizzard refills it when the filter changes, and there's no separate per-filter history. Any tracking built on it depends on the selected filter including Power Gains and Drains. `/mm scanlog` prints the selected filter's name from `Blizzard_CombatLog_CurrentSettings.name`.
- `/mm scanlog` didn't find that potion line even though the tab showed it. The cause isn't known yet: it could be line order, stored text that differs from what's displayed, or timing. The scan now prints lines from both ends with escape codes visible, and `/mm scanlog <text>` searches for any text.
- No live lines reached the `AddMessage`/`BackFillMessage` hooks, whether the tab was in the background or showing, even though the potion line appeared in the tab. Live lines bypass the Lua methods, probably added by the client directly. Only Blizzard's refills go through `BackFillMessage`.
- `/mm scanlog` reads the tab's stored history back with `ChatFrame2:GetNumMessages()`/`GetMessageInfo(i)`. Right after a `/reload`, all 100 lines checked were **readable** (confirmed in game). The history after a reload holds Blizzard's refill, and whether it keeps lines from before the reload is unknown.
- Live lines do land in that history, but combat events are `|K…|k` placeholder tokens (see Result above). The plain lines seen at first (`Razormane Scout dies, you gain 80 experience.`) were system messages, which is why the history looked readable.
- The history seems capped at **128 lines** (two scans both reported exactly 128), so old lines drop off. A real implementation must read new lines during the fight, not once at the end.

## Findings from Details! (reference copy in `DetailsReference/`)

`DetailsReference/` holds a copy of the Details! damage meter (version 20260918) for reference only. It's git-ignored, and none of it is loaded by ManaMaster.

- Details ships `Details_Camelot.toc` for interface 16001. It detects WoW Forever with `DF.IsForeverWow()` (build 16001–19999) and treats it like Midnight/retail 12.x (`IsAddonApocalypseWow`).
- **Details doesn't parse combat events on this client.** Its no-combat-log parser (`core/parser_nocleu*.lua`) displays Blizzard's built-in damage meter (`C_DamageMeter`, `Enum.DamageMeterType`, `DAMAGE_METER_COMBAT_SESSION_UPDATED`).
  - The meter types are damage, DPS, damage taken, avoidable damage taken, enemy damage taken, healing, HPS, absorbs, interrupts, dispels and deaths.
  - Details marks **"resources" and "mana gained" as not supported**, along with buff and debuff uptime. No Blizzard data source for mana gains or drains exists that Details knows of.
- Details' `core/aura_scan.lua` has no secret handling and is never started. A comment in `core/control.lua` says "auras are always secret" on these clients, so Details skips pre-combat buff scans there. ManaMaster's `pcall` per slot is still needed.
- **Hidden values can be displayed without reading them.** Details passes secret numbers and strings straight to `FontString:SetText`, `AbbreviateNumbers` and `StatusBar:SetMinMaxValues`/`SetValue`, and the client renders them. Math, comparisons and table keys on secrets still error. This means ManaMaster could show live current mana (a bar or number) even though it can't calculate with it.
- **Restriction state API:**
  - `C_RestrictedActions.GetAddOnRestrictionState(Enum.AddOnRestrictionType.X)` exists, with types `Combat`, `Encounter`, `ChallengeMode`, `PvPMatch` and `Map`, and the event `ADDON_RESTRICTION_STATE_CHANGED` (args: type, state).
  - Details also uses `PLAYER_IN_COMBAT_CHANGED` (arg: inCombat).
  - Details treats secret values as tied to these restrictions, and can error if `Combat` is off but values are still secret. This may explain ManaMaster seeing mana hidden out of combat, if some restriction such as `Map` stays active. Not tested yet.
- Blizzard damage meter data is secret during combat and becomes readable afterward; Details waits for "secrets to drop" before storing a session. Spell IDs in that data can be secret too, and Details checks with `issecretvalue(spellId)` before comparing them.

## Testing

In game, the addon folder must be named `ManaMaster` inside the client's `Interface\AddOns\` directory. Use `/reload` after making changes; new files or TOC changes need a full client restart. Both clients point at this project folder through directory junctions:

- WoW Forever: `_classic_beta_\Interface\AddOns\ManaMaster`
- TBC Anniversary: `_anniversary_\Interface\AddOns\ManaMaster`
