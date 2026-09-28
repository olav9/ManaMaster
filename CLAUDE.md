# ManaMaster

ManaMaster is a World of Warcraft addon for mana tracking and management.

## Target game version

- The addon targets **World of Warcraft: Forever**, a new version of WoW.
- WoW Forever uses the **current retail WoW API**. Write code against retail APIs, not Classic APIs.
- The client reports interface/build **16001**. Keep `## Interface: 16001` in `ManaMaster.toc`. This is correct even though it doesn't follow the usual 6-digit retail format.

## Structure

- `ManaMaster.toc`: addon manifest. SavedVariables: `ManaMasterDB`.
- `ManaMaster.lua`: main addon code (event handling, saved settings, slash commands `/mm` and `/manamaster`). Shares helpers with other files through the addon namespace `ns`.
- `HistoryPanel.lua`: fight history window (`/mm`). Loaded after `ManaMaster.lua`. Provides `ns.ToggleHistory` and `ns.RefreshHistory`.
- `MinimapButton.lua`: draggable minimap button that toggles the history panel. Created from `OnAddonLoaded` once `ManaMasterDB` exists. Position is saved in `ManaMasterDB.minimapAngle`.

## How tracking works

- A fight starts on `PLAYER_REGEN_DISABLED` or `ENCOUNTER_START`. It ends on `PLAYER_REGEN_ENABLED`, or on `ENCOUNTER_END` if a boss encounter is active.
- Total spent/recovered comes from `UNIT_POWER_FREQUENT` mana deltas. The per-spell breakdown comes from `UNIT_SPELLCAST_SUCCEEDED` plus `C_Spell.GetSpellPowerCost`.
- The combat log (`COMBAT_LOG_EVENT_UNFILTERED`) is not available. On WoW Forever, registering for it triggers the "blocked from an action only available to the Blizzard UI" pop-up (confirmed in game). Don't register it, not even behind a debug flag.
- Values may be "secret" during combat on retail. Guard reads with `issecretvalue`.
- On WoW Forever, the player's current mana (`UnitPower`) is secret in and out of combat (confirmed in game), so `lastSeenMana` never gets a value and fights start with mana assumed full. `UnitPowerMax` is readable. When mana is hidden at any point in a fight, the total spent falls back to the sum of listed spell costs (`castSpent`), and recovered/lowest mana aren't recorded (`nil`).
- WoW Forever uses the retail regen model: regen is continuous, with no 2-second ticks, but the five-second rule still applies.
- Passive regen is estimated, not measured, since mana is hidden. `GetManaRegen()` gives rates per second (inactive, active). The addon applies the active rate for 5 seconds after each mana-cost cast (five-second rule) and the inactive rate otherwise. The result is stored as `fight.regen`. Rates are cached from the last readable read. Potions, Innervate and similar bursts are not included, so the simulated pool can read lower than the real one after using them.
- The addon simulates the mana pool (`fight.simMana`) to estimate wasted regen:
  - **Start value:** the current reading if it's visible. Otherwise, the last out-of-combat reading (`lastSeenMana`), which is cleared when a later reading is hidden. Otherwise, full mana (`startManaAssumed`).
  - **During the fight:** casts subtract their cost, and regen adds up to max mana.
  - **Wasted regen:** regen past max goes to `fight.wastedFull`. While a `REGEN_BLOCKERS` debuff is up, all regen goes to `fight.wastedBlocked`, using the rates from before the debuff. `REGEN_BLOCKERS` is a table of English debuff names; it's empty until specific effects are identified.
  - `fight.regen` only counts regen that actually fit in the pool.
- Regen buff uptime is tracked by scanning player buffs on `UNIT_AURA` against `REGEN_BUFFS`, a table of English buff names at the top of `ManaMaster.lua`. It's stored per fight as `fight.buffs[name] = { uptime, spellID, icon }` and shown as a fourth panel section with its own 0-100% bar scale.
- In combat, `C_UnitAuras.GetAuraDataByIndex` throws "Auras cannot be accessed when secret" for some buffs (seen with Blood Fury). It doesn't return a secret value for them. Always call it through `pcall` and skip the slot on error.
- Fights are named after the boss encounter. Otherwise they use the first hostile target, at combat start or via `PLAYER_TARGET_CHANGED`, and fall back to "Combat". Target names are readable on WoW Forever (confirmed in game).
- WoW Forever has spell ranks, and each rank has its own spell ID and cost. `fight.spells` is keyed by spell ID, and each entry stores `name` and `rank` (from `C_Spell.GetSpellSubtext`). Fights saved before this change are keyed by spell name and have no `name`/`rank` fields; `SortedEntries` handles both.
- The history panel shows three sections: spent (`fight.spells`), gained (`fight.recovered` or `fight.regen`, plus `fight.gains`) and drained (`fight.drains`). `fight.gains` and `fight.drains` use the same entry shape as `fight.spells` but nothing fills them yet. Without the combat log, exact gains and drains can't be measured. Only estimates from the player's own casts and auras are possible.
- Fight history is stored in `ManaMasterDB.fights` (the last 50 fights).
- The on-screen display shows the spent number with a live mana bar under it (`UpdateManaBar`).
  - The bar passes the secret `UnitPower` value straight to `StatusBar:SetValue` and to `FontString:SetText` via `AbbreviateNumbers`, without reading it. Current and max mana use separate font strings, since a secret can't be joined into a string.
  - It's wrapped in `pcall`; if the client refuses, the bar hides for the session.
  - Confirmed working in game on WoW Forever, so rendering secret values this way works on this client.
  - It updates on `UNIT_POWER_FREQUENT` and `UNIT_MAXPOWER` while the display is shown.

## Combat log chat tab experiment (in progress)

- Blizzard's Combat Log chat tab is `ChatFrame2` (`COMBATLOG == ChatFrame2`, and `Blizzard_CombatLog` is loaded). `/mm debug` post-hooks its `AddMessage` and `BackFillMessage` with `hooksecurefunc`. This doesn't trigger the blocked pop-up.
- Lines refilled into the tab (`BackFillMessage`) are **readable** strings (confirmed in game).
- During a fight with the tab in the background, no lines arrived through either hook. The likely reason is that Blizzard only writes live lines while the tab is shown and backfills when it's opened. This is unconfirmed.
- Drinking produces no combat log lines at all, which fits the retail regen model where drinking is a regen-rate buff.

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

In game, the addon folder must be named `ManaMaster` inside the client's `Interface\AddOns\` directory. Use `/reload` after making changes.
