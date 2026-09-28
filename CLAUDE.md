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
- The combat log (`COMBAT_LOG_EVENT_UNFILTERED`) is not used. Current retail restricts it for addons. This hasn't been verified on WoW Forever; `/mm debug` includes a check.
- Values may be "secret" during combat on retail. Guard reads with `issecretvalue`.
- On WoW Forever, the player's current mana (`UnitPower`) has been observed as secret, even at the moment combat starts. `UnitPowerMax` is readable. When mana is hidden at any point in a fight, the total spent falls back to the sum of listed spell costs (`castSpent`), and recovered/lowest mana aren't recorded (`nil`).
- WoW Forever uses the retail regen model: regen is continuous, with no 2-second ticks, but the five-second rule still applies.
- Passive regen is estimated, not measured, since mana is hidden. `GetManaRegen()` gives rates per second (inactive, active). The addon applies the active rate for 5 seconds after each mana-cost cast (five-second rule) and the inactive rate otherwise. The result is stored as `fight.regen`. Rates are cached from the last readable read. Potions, Innervate and similar bursts are not included.
- Regen buff uptime is tracked by scanning player buffs on `UNIT_AURA` against `REGEN_BUFFS`, a table of English buff names at the top of `ManaMaster.lua`. It's stored per fight as `fight.buffs[name] = { uptime, spellID, icon }` and shown as a fourth panel section with its own 0-100% bar scale.
- Fights are named after the boss encounter. Otherwise they use the first hostile target, at combat start or via `PLAYER_TARGET_CHANGED`, and fall back to "Combat". Target names are readable on WoW Forever (confirmed in game).
- WoW Forever has spell ranks, and each rank has its own spell ID and cost. `fight.spells` is keyed by spell ID, and each entry stores `name` and `rank` (from `C_Spell.GetSpellSubtext`). Fights saved before this change are keyed by spell name and have no `name`/`rank` fields; `SortedEntries` handles both.
- The history panel shows three sections: spent (`fight.spells`), gained (`fight.recovered` or `fight.regen`, plus `fight.gains`) and drained (`fight.drains`). `fight.gains` and `fight.drains` use the same entry shape as `fight.spells` but nothing fills them yet. Whether they can be measured depends on combat log access, which `/mm debug` checks.
- Fight history is stored in `ManaMasterDB.fights` (the last 50 fights).

## Testing

In game, the addon folder must be named `ManaMaster` inside the client's `Interface\AddOns\` directory. Use `/reload` after making changes.
