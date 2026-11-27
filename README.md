# Scrollable Quest Tracker (v0.4.0)

Adds a **Max Height** setting and a **scrollable** tracked-quest list to the default Objective Tracker. All settings live in Edit Mode, on the Objective Tracker's own settings panel.

## Install

1. Copy the `ScrollableQuestTracker` folder into `World of Warcraft\<game folder>\Interface\AddOns\`.
2. In-game, run `/dump select(4, GetBuildInfo())`. If the number isn't `16001`, put it on the `## Interface:` line in `ScrollableQuestTracker.toc` (or tick "Load out of date AddOns").
3. `/reload`

## Using it

The addon works straight away, with the tracker in its default spot under the minimap or anywhere you've moved it. It's on by default with a Max Height of 400 px.

1. To change settings, open Edit Mode and click the Objective Tracker. New rows appear under Blizzard's settings:
   - **Scrollable Tracker**: turns the feature on or off.
   - **Max Height**: 150–1000 px. This is the tallest the whole tracker (header included) will get. In the default position it's also capped at the space Blizzard gives the tracker there, so it never runs past where the default tracker would stop. In Edit Mode the selection box is exactly this tall, so you can see the space it will take up.
   - **Always Show Scroll Bar**: keeps the bar visible whenever there's something to scroll. When it's off, the bar fades in while you scroll, drag it or hover over it, then fades out.
   - **Caith Style**: a dark, bevelled look in the spirit of the Masque: Caith button skin. It adds a charcoal border with black edges around the tracker (scroll bar included), darker grey header banners, a flat dark scroll bar, and a soft fade along the bottom of the list while there are more quests below.
   - **Background**: how opaque the black background behind the tracker is (default 60%). While Caith Style is on, it replaces Blizzard's Opacity slider.
2. Leave Edit Mode. When your tracked quests don't fit, scroll the mouse wheel over the tracker.

When everything fits, the tracker looks and acts exactly like the default one. The mouse wheel only gets taken over when there's something to scroll, so camera zoom still works over a short tracker.

## Notes and limits

- While Scrollable Tracker is on, it replaces Blizzard's **Height** slider. That slider still shows up, but has no effect.
- These settings are account-wide and save as soon as you change them. They aren't part of Edit Mode layouts, so **Revert Changes** and switching layouts don't affect them.
- In Edit Mode the tracker isn't scrollable. It shows what fits inside Max Height, the way the default tracker does.
- In the default position Blizzard's frame manager keeps placing the tracker as usual; the addon only controls its height. If you've moved the tracker and it was saved anchored by its bottom or center, the addon pins it by its top-left while you're playing, so growing content doesn't push it upward. The saved Edit Mode anchor is never changed, and it's put back when you enter Edit Mode or turn the feature off.

## How it works (for maintenance)

- `Core.lua` post-hooks `ObjectiveTrackerFrame:UpdateHeaderPosition()` (runs at the end of every tracker layout pass, including the deferred "dirty" updates) and `ObjectiveTrackerFrame:UpdateHeight()`.
- Outside Edit Mode it makes the tracker frame tall enough that Blizzard never truncates the quest list. It moves the tracker's modules into a `ScrollFrame` below the header and limits that frame to Max Height. It also ends the background (`NineSlice`) at the bottom of that visible area and shrinks the clamp-to-screen rectangle to match.
- The scroll bar is Blizzard's `MinimalScrollBar` template. `Skin.lua` restyles it, and draws the tracker border and background, using flat colour textures, so no art files are shipped. The border is sized in physical pixels, so it stays crisp at any UI scale.
- **Taint:** quest item buttons in the tracker call a protected function, so the addon never replaces or calls Blizzard's tracker or Edit Mode Lua functions and never writes fields onto Blizzard frames. It only uses `hooksecurefunc`, reads values, and calls C widget methods (`SetHeight`, `SetPoint`, `SetParent`, `SetClampRectInsets`, and Edit Mode's saved `SetPointBase` / `ClearAllPointsBase`). If you ever see "blocked from an action" errors that point at this addon, that rule has been broken somewhere.
