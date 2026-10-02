# ManaMaster changelog

## v0.2.4

- Druids: the meter window has a "Resources spent" section showing mana, rage and energy together, each in its own colour with its own scale.
- The Details plugin shows every resource spent, coloured by resource. Overall segments that mix caster and cat fights no longer add mana and energy into the same bars.
- Clicking a rage, energy or mana bar opens the history panel on that resource.
- History panel: the resource button is now a dropdown.
- Fights end the way Details ends a combat, so they line up with Details' segments: a fight stays open while your group is still fighting, or while Vanish is up.
- Nothing is counted while you're dead, and a resurrection's mana isn't counted as recovered.
- A fight stays open while you can still be resurrected (soulstone, Ankh, a battle resurrection on offer).

## v0.2.4-beta2

- WoW Forever is now included in the CurseForge release (it was missing from v0.2.4-beta1).
- The WoW Forever build is no longer loaded by the retail client.

## v0.2.4-beta1

- First release built and uploaded automatically: the addon is checked, packaged and published to CurseForge from GitHub.
- No changes to the addon itself since v0.2.3.

## v0.2.3

- Arena fights end as soon as the match is decided, so regen during the scoreboard no longer counts.
- The arena's end-of-match mana refill is no longer shown.
- The fight history follows Details!: fights whose Details segment is removed are removed too, and resetting Details asks whether to clear ManaMaster's history.
- Details plugin: Overall now selects every fight Details counts in it, and the plugin keeps following the right window after a reload.

## v0.2.2

- Left-click a bar in the meter window or the Details plugin to open that fight in the history panel.
- Meter and Details bars show cast counts, with ranks and details in the tooltip.
- History panel: see-through background, a narrower fight list and a simpler header; row text shows data, explanations are in tooltips.
- Mana saved now counts pull casts made on a proc before combat.
- 200 fights are kept per character by default; change it with `/mm keep`.
- Classic Era support (not yet tested in game).

## v0.2.1

- WoW Forever: regen buffs such as Blessing of Wisdom are added to the regen estimate, since the game's regen rate leaves them out.
- Regen buff uptime no longer drops out early in combat.
- Regen lost at full mana isn't counted before the fight's first cast.
- `/mm debug` also covers rage and energy, and keeps a log in the saved variables.

## v0.2.0

- Rage and energy are tracked alongside mana: spent per ability, and gained where the game shows it.

## v0.1.0

- First version: mana spent, gained, saved and drained per fight, with a history panel, a meter window, a minimap button and a Details! plugin.
