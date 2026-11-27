--[[
	Scrollable Quest Tracker - Core

	How it works
	------------
	The default tracker (ObjectiveTrackerFrame) lays out its modules top to bottom and stops
	("truncates") once it runs out of height. This addon:

	  1. Gives the tracker frame enough height that it never truncates while you're playing.
	  2. Moves the tracker's modules into a ScrollFrame (a clipped viewport) that sits under the
	     tracker header and is never taller than the chosen Max Height.
	  3. Adds a minimal scroll bar next to the viewport that fades in while you scroll.

	In Edit Mode the tracker is sized to exactly Max Height, so the selection box you drag around
	shows the real footprint of the tracker.

	Taint safety
	------------
	The quest item buttons in the tracker call a protected function when clicked, so Blizzard's
	tracker code must never run "tainted". To keep it clean this file:
	  - never replaces or calls Blizzard's tracker / Edit Mode Lua functions that change state;
	    it only post-hooks them with hooksecurefunc and reads their values;
	  - never writes fields onto Blizzard frames or tables;
	  - only changes Blizzard frames through C-side widget methods (SetHeight, SetPoint,
	    SetParent, SetClampRectInsets), which don't carry taint.
	Blizzard then reacts to the size change itself (OnSizeChanged -> its own update).
]]

local ADDON_NAME, ns = ...;

ns.DEFAULTS = {
	enabled = true,
	maxHeight = 400,
	alwaysShowScrollBar = false,
	skinEnabled = true,
	backgroundOpacity = 60,
};

ns.MAX_HEIGHT_MIN = 150;
ns.MAX_HEIGHT_MAX = 1000;
ns.MAX_HEIGHT_STEP = 10;

-- Viewport clip margins around the tracker's own width. POI buttons and some header art hang
-- past the tracker's left/right edges, so the clip region is wider than the tracker.
local CLIP_LEFT = 45;
local CLIP_RIGHT = 20;
ns.CLIP_LEFT = CLIP_LEFT;
ns.CLIP_RIGHT = CLIP_RIGHT;

local SCROLLBAR_OFFSET_X = 8;			-- gap between the tracker's right edge and the scroll bar
local SCROLLBAR_MIN_VIEW_HEIGHT = 60;	-- don't show a bar on tiny viewports (steppers need room)
local WHEEL_STEP = 40;					-- pixels scrolled per mouse wheel notch

local LAYOUT_SLACK = 200;				-- extra room so a new objective line doesn't truncate before we grow
local SHRINK_HYSTERESIS = 400;			-- only shrink the frame when it's this much bigger than needed
local GROW_STEP = 400;
local MAX_FRAME_HEIGHT = 8000;

local FADE_IN_TIME = 0.15;
local FADE_OUT_TIME = 0.4;
local IDLE_BEFORE_FADE = 1.5;

local db;
local tracker;
local viewport, scrollChild, barHolder, scrollBar, fader;

local active = false;
local anchorConverted = false;
local lastTargetHeight = nil;
local scrollRange = 0;
local canScroll = false;
local syncingBar = false;
local fadeTarget = 0;
local idleTime = 0;
local reparentedModules = {};

-- ***********************************************************************************************
-- Helpers
-- ***********************************************************************************************

local function IsEditModeActive()
	return EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive();
end

local function IsTrackerInitialized()
	return tracker and tracker.IsInitialized and tracker:IsInitialized();
end

-- Works in both the default (screen-managed) position and a custom Edit Mode position.
function ns.IsAvailable()
	return IsTrackerInitialized();
end

-- In the default position the tracker lives in RightManagedFrameContainer, which has a fixed height
-- (screen height minus the minimap and a margin). Blizzard's UpdateHeight() fills the tracker down to
-- the bottom of that container: containerHeight + offsetY of the tracker's anchor. Same formula here,
-- read-only, so Max Height can be capped to that space.
local function GetDefaultPositionSpace()
	local _, _, _, _, offsetY = tracker:GetPoint(1);
	local parent = tracker:GetParent();
	if not (offsetY and parent) then
		return nil;
	end
	return math.max(parent:GetHeight() + offsetY, 20);
end

local function ShouldBeActive()
	return db and db.enabled and ns.IsAvailable();
end

-- The Max Height actually in effect: the setting, capped in the default position to the space
-- Blizzard would give the tracker there (so it never runs past where the default tracker stops).
local function GetMaxHeight()
	local maxHeight = Clamp(db.maxHeight or ns.DEFAULTS.maxHeight, ns.MAX_HEIGHT_MIN, ns.MAX_HEIGHT_MAX);
	if tracker:IsInDefaultPosition() then
		local space = GetDefaultPositionSpace();
		if space then
			maxHeight = math.min(maxHeight, space);
		end
	end
	return maxHeight;
end

local function GetModules()
	return tracker.modules or {};
end

-- Mirrors ObjectiveTrackerContainerMixin:Update(): modules with contents are stacked top to bottom
-- with moduleSpacing between them.
local function GetModuleStack()
	local firstModule, lastModule;
	local stackHeight = 0;
	local truncated = false;
	local spacing = tracker.moduleSpacing or 10;

	for _, module in ipairs(GetModules()) do
		if module:GetContentsHeight() > 0 then
			if firstModule then
				stackHeight = stackHeight + spacing;
			end
			firstModule = firstModule or module;
			lastModule = module;
			stackHeight = stackHeight + module:GetHeight();
		end
		if module:IsTruncated() then
			truncated = true;
		end
	end

	return firstModule, lastModule, stackHeight, truncated;
end

local function GetMustFitHeight()
	local height = 0;
	for _, module in ipairs(GetModules()) do
		if module.mustFit then
			height = height + module:GetContentsHeight();
		end
	end
	return height;
end

-- The height the tracker has while in Edit Mode; also its "logical" height for anchoring.
local function GetEditModeTrackerHeight()
	return math.max(GetMaxHeight(), GetMustFitHeight());
end

-- ***********************************************************************************************
-- Tracker anchoring
-- ***********************************************************************************************

-- Outside Edit Mode the tracker frame can be much taller than what's visible. If it's anchored by
-- its bottom or center, growing it would push the visible part upward, so while active we pin it
-- by its top-left at the same on-screen spot. Uses the original C widget methods saved by Edit
-- Mode (SetPointBase / ClearAllPointsBase) so Edit Mode's own Lua bookkeeping isn't touched.
local function EnsureTopAnchor()
	-- In the default position the frame manager anchors the tracker by its top already.
	if tracker:IsInDefaultPosition() or not (tracker.SetPointBase and tracker.ClearAllPointsBase) then
		return;
	end

	local point = tracker:GetPoint(1);
	if not point or point:find("TOP") then
		return;
	end

	local left, bottom = tracker:GetLeft(), tracker:GetBottom();
	if not (left and bottom) then
		return;
	end

	local logicalHeight = GetEditModeTrackerHeight();
	local top;
	if point:find("BOTTOM") then
		top = bottom + logicalHeight;
	else
		local _, centerY = tracker:GetCenter();
		top = centerY + (logicalHeight / 2);
	end

	tracker:ClearAllPointsBase();
	tracker:SetPointBase("TOPLEFT", UIParent, "BOTTOMLEFT", left, top);
	anchorConverted = true;
end

-- Put the tracker back on the anchor saved in the Edit Mode layout.
local function RestoreSavedAnchor()
	if not anchorConverted then
		return;
	end
	anchorConverted = false;

	if not (tracker.SetPointBase and tracker.ClearAllPointsBase) or tracker:IsInDefaultPosition() then
		return;
	end

	local systemInfo = tracker.systemInfo;
	local anchorInfo = systemInfo and systemInfo.anchorInfo;
	if not anchorInfo then
		return;
	end

	local scale = tracker:GetScale();
	tracker:ClearAllPointsBase();
	tracker:SetPointBase(anchorInfo.point, anchorInfo.relativeTo, anchorInfo.relativePoint, anchorInfo.offsetX / scale, anchorInfo.offsetY / scale);

	local anchorInfo2 = systemInfo.anchorInfo2;
	if anchorInfo2 and anchorInfo2.point then
		tracker:SetPointBase(anchorInfo2.point, anchorInfo2.relativeTo, anchorInfo2.relativePoint, anchorInfo2.offsetX / scale, anchorInfo2.offsetY / scale);
	end
end

-- ***********************************************************************************************
-- Tracker height
-- ***********************************************************************************************

local function ComputeTargetHeight(topPadding, contentHeight, truncated)
	local maxHeight = GetMaxHeight();

	if IsEditModeActive() then
		return GetEditModeTrackerHeight();
	end

	local current = math.max(lastTargetHeight or maxHeight, maxHeight);

	if truncated then
		return math.min(MAX_FRAME_HEIGHT, current + math.max(GROW_STEP, maxHeight));
	end

	local needed = math.min(MAX_FRAME_HEIGHT, math.max(maxHeight, topPadding + contentHeight + LAYOUT_SLACK));
	if needed > current or (current - needed) > SHRINK_HYSTERESIS then
		return needed;
	end
	return current;
end

local function ApplyTrackerHeight(height)
	-- Only the top Max Height of the frame is ever visible, so clamp-to-screen should only consider
	-- that part. A positive bottom inset moves the clamp rect's bottom edge up.
	local bottomInset = 0;
	if not IsEditModeActive() then
		bottomInset = math.max(0, height - GetMaxHeight());
	end
	tracker:SetClampRectInsets(0, 0, 0, bottomInset);

	if math.abs(tracker:GetHeight() - height) > 0.5 then
		tracker:SetHeight(height);
	end
end

-- ***********************************************************************************************
-- Scroll bar
-- ***********************************************************************************************

local function IsScrollBarBusy()
	return scrollBar:IsMouseOver() or scrollBar:IsThumbMouseDown();
end

local function UpdateFader()
	if not canScroll then
		fader:Hide();
		scrollBar:SetAlpha(0);
		return;
	end

	if db.alwaysShowScrollBar then
		fader:Hide();
		scrollBar:SetAlpha(1);
		return;
	end

	if not fader:IsShown() then
		scrollBar:SetAlpha(0);
	end
end

function ns.RevealScrollBar()
	if not canScroll then
		return;
	end
	idleTime = 0;
	if db.alwaysShowScrollBar then
		scrollBar:SetAlpha(1);
		return;
	end
	fadeTarget = 1;
	fader:Show();
end

local function OnFaderUpdate(self, elapsed)
	local alpha = scrollBar:GetAlpha();

	if fadeTarget == 1 then
		alpha = math.min(1, alpha + (elapsed / FADE_IN_TIME));
		scrollBar:SetAlpha(alpha);

		if IsScrollBarBusy() then
			idleTime = 0;
		else
			idleTime = idleTime + elapsed;
		end

		if idleTime >= IDLE_BEFORE_FADE and not db.alwaysShowScrollBar then
			fadeTarget = 0;
		end
	else
		alpha = math.max(0, alpha - (elapsed / FADE_OUT_TIME));
		scrollBar:SetAlpha(alpha);
		if alpha <= 0 then
			self:Hide();
		end
	end
end

local function SyncScrollBar(viewHeight, contentHeight)
	syncingBar = true;
	local visibleExtent = (contentHeight > 0) and (viewHeight / contentHeight) or 1;
	scrollBar:SetVisibleExtentPercentage(visibleExtent);
	scrollBar:SetPanExtentPercentage((scrollRange > 0) and Saturate(WHEEL_STEP / scrollRange) or 0);
	local percentage = (scrollRange > 0) and (viewport:GetVerticalScroll() / scrollRange) or 0;
	scrollBar:SetScrollPercentage(percentage, true);
	syncingBar = false;
end

local function SetScrollOffset(offset)
	offset = Clamp(offset, 0, scrollRange);
	viewport:SetVerticalScroll(offset);

	syncingBar = true;
	scrollBar:SetScrollPercentage((scrollRange > 0) and (offset / scrollRange) or 0, true);
	syncingBar = false;
end

local function OnScrollBarScroll(_owner, percentage)
	if syncingBar then
		return;
	end
	viewport:SetVerticalScroll(Clamp(percentage * scrollRange, 0, scrollRange));
	ns.RevealScrollBar();
end

local function OnViewportMouseWheel(_self, delta)
	SetScrollOffset(viewport:GetVerticalScroll() - (delta * WHEEL_STEP));
	ns.RevealScrollBar();
end

-- ***********************************************************************************************
-- Frames
-- ***********************************************************************************************

local function CreateFrames()
	if viewport then
		return;
	end

	viewport = CreateFrame("ScrollFrame", "ScrollableQuestTrackerViewport", tracker);
	viewport:SetSize(1, 1);
	viewport:EnableMouseWheel(false);
	viewport:SetScript("OnMouseWheel", OnViewportMouseWheel);

	scrollChild = CreateFrame("Frame", nil, viewport);
	scrollChild:SetSize(1, 1);
	viewport:SetScrollChild(scrollChild);

	-- Holder gives the bar a frame level above the tracker contents.
	barHolder = CreateFrame("Frame", nil, tracker);
	barHolder:SetFrameLevel(tracker:GetFrameLevel() + 50);
	barHolder:SetAllPoints(tracker);

	scrollBar = CreateFrame("EventFrame", "ScrollableQuestTrackerScrollBar", barHolder, "MinimalScrollBar");
	scrollBar:SetPoint("TOPLEFT", viewport, "TOPRIGHT", SCROLLBAR_OFFSET_X - CLIP_RIGHT, 0);
	scrollBar:SetPoint("BOTTOMLEFT", viewport, "BOTTOMRIGHT", SCROLLBAR_OFFSET_X - CLIP_RIGHT, 0);
	scrollBar:SetAlpha(0);
	scrollBar:Hide();
	scrollBar:RegisterCallback(ScrollBarMixin.Event.OnScroll, OnScrollBarScroll, ns);

	-- Mouse wheel over the bar itself scrolls too.
	scrollBar:EnableMouseWheel(true);
	scrollBar:SetScript("OnMouseWheel", function(_self, delta)
		OnViewportMouseWheel(viewport, delta);
	end);

	-- Hovering or pressing any part of the bar reveals it.
	for _, part in ipairs({ scrollBar.Track, scrollBar.Track.Thumb, scrollBar.Back, scrollBar.Forward }) do
		part:HookScript("OnEnter", ns.RevealScrollBar);
		part:HookScript("OnMouseDown", ns.RevealScrollBar);
	end

	fader = CreateFrame("Frame");
	fader:Hide();
	fader:SetScript("OnUpdate", OnFaderUpdate);

	if ns.SkinScrollBar then
		ns.SkinScrollBar(scrollBar);
	end
	if ns.AttachScrollFade then
		ns.AttachScrollFade(viewport);
	end
end

local function ReparentModules(parent)
	for _, module in ipairs(GetModules()) do
		if module:GetParent() ~= parent then
			module:SetParent(parent);
		end
		reparentedModules[module] = true;
	end
end

local function RestoreModules()
	for module in pairs(reparentedModules) do
		if module:GetParent() ~= tracker then
			module:SetParent(tracker);
		end
	end
	wipe(reparentedModules);
end

-- ***********************************************************************************************
-- Activation
-- ***********************************************************************************************

local function Deactivate()
	if not active then
		return;
	end
	active = false;
	lastTargetHeight = nil;
	canScroll = false;
	scrollRange = 0;

	RestoreModules();

	-- Re-apply the anchors Blizzard's own layout would have set, so nothing jumps before its next update.
	local firstModule, lastModule = GetModuleStack();
	local topPadding = tracker.topModulePadding or 0;
	if firstModule then
		firstModule:SetPoint("TOP", tracker, "TOP", 0, -topPadding);
	end
	if lastModule then
		tracker.NineSlice:SetPoint("BOTTOM", lastModule, "BOTTOM", 0, -(tracker.bottomModulePadding or 10));
	end

	viewport:SetVerticalScroll(0);
	viewport:EnableMouseWheel(false);
	viewport:Hide();
	scrollBar:Hide();
	fader:Hide();

	tracker:SetClampRectInsets(0, 0, 0, 0);

	if tracker:IsInDefaultPosition() then
		anchorConverted = false;
		-- Same height Blizzard's UpdateHeight() uses in the default position.
		local space = GetDefaultPositionSpace();
		if space then
			tracker:SetHeight(space);
		end
	else
		RestoreSavedAnchor();
		-- Same height Blizzard's ObjectiveTrackerContainerMixin:UpdateHeight() uses for a moved tracker.
		tracker:SetHeight(math.max(tracker.editModeHeight or 800, GetMustFitHeight()));
	end

	if ns.UpdateScrollFade then
		ns.UpdateScrollFade();
	end
end

local function Activate()
	if active then
		return;
	end
	CreateFrames();
	active = true;
	viewport:Show();
end

-- Runs after every tracker layout pass (and whenever settings change).
local function RunLayout()
	if not tracker then
		return;
	end

	if not ShouldBeActive() then
		Deactivate();
		return;
	end

	Activate();
	ReparentModules(scrollChild);

	local editMode = IsEditModeActive();
	local topPadding = tracker.topModulePadding or 0;
	local firstModule, lastModule, stackHeight, truncated = GetModuleStack();
	local contentHeight = lastModule and (stackHeight + (tracker.bottomModulePadding or 10)) or 0;

	local maxViewHeight = math.max(GetMaxHeight() - topPadding, 20);
	local viewHeight = 0;
	if lastModule and not tracker:IsCollapsed() then
		viewHeight = math.min(contentHeight, maxViewHeight);
	end

	-- Viewport sits directly under the tracker header.
	viewport:ClearAllPoints();
	viewport:SetPoint("TOPLEFT", tracker, "TOPLEFT", -CLIP_LEFT, -topPadding);
	viewport:SetPoint("TOPRIGHT", tracker, "TOPRIGHT", CLIP_RIGHT, -topPadding);
	viewport:SetHeight(math.max(viewHeight, 1));
	scrollChild:SetSize(tracker:GetWidth() + CLIP_LEFT + CLIP_RIGHT, math.max(contentHeight, 1));

	-- The first module is anchored to the scroll child instead of the tracker; the rest are chained
	-- below it by Blizzard's layout, so they follow along.
	if firstModule then
		firstModule:SetPoint("TOP", scrollChild, "TOP", 0, 0);
	end

	-- Background ends at the bottom of the visible area rather than the bottom of the content.
	if lastModule then
		tracker.NineSlice:SetPoint("BOTTOM", viewport, "BOTTOM", 0, 0);
	end

	scrollRange = editMode and 0 or math.max(0, contentHeight - viewHeight);
	if scrollRange < 0.5 then
		scrollRange = 0;
	end
	if viewport:GetVerticalScroll() > scrollRange then
		viewport:SetVerticalScroll(scrollRange);
	end

	canScroll = scrollRange > 0;
	viewport:EnableMouseWheel(canScroll);
	scrollBar:SetShown(canScroll and viewHeight >= SCROLLBAR_MIN_VIEW_HEIGHT);
	SyncScrollBar(viewHeight, contentHeight);
	UpdateFader();

	if not editMode then
		EnsureTopAnchor();
	end

	lastTargetHeight = ComputeTargetHeight(topPadding, contentHeight, truncated);
	ApplyTrackerHeight(lastTargetHeight);

	if ns.UpdateScrollFade then
		ns.UpdateScrollFade();
	end
end

ns.Refresh = RunLayout;

-- Read-only view of the scroll state for Skin.lua.
function ns.GetScrollInfo()
	return active, viewport, scrollRange;
end

-- ***********************************************************************************************
-- Hooks
-- ***********************************************************************************************

-- Called at the end of every ObjectiveTrackerFrame:Update(), including the deferred "dirty" updates.
local function OnTrackerUpdated()
	RunLayout();
end

-- Blizzard's UpdateHeight() just set the height it wants; put ours back.
local function OnTrackerHeightUpdated()
	if ShouldBeActive() then
		if active and lastTargetHeight then
			if IsEditModeActive() then
				lastTargetHeight = GetEditModeTrackerHeight();
			end
			ApplyTrackerHeight(lastTargetHeight);
		else
			RunLayout();
		end
	elseif active then
		Deactivate();
	end
end

local function OnEditModeEnter()
	if not active then
		return;
	end
	viewport:SetVerticalScroll(0);
	RestoreSavedAnchor();
	RunLayout();
end

local function OnEditModeExit()
	RunLayout();
end

function ns.OnSettingsChanged()
	RunLayout();
	if ns.ApplySkin then
		ns.ApplySkin();
	end
	if active then
		UpdateFader();
	end
end

local function InitTracker()
	tracker = ObjectiveTrackerFrame;
	hooksecurefunc(tracker, "UpdateHeaderPosition", OnTrackerUpdated);
	hooksecurefunc(tracker, "UpdateHeight", OnTrackerHeightUpdated);
	EventRegistry:RegisterCallback("EditMode.Enter", OnEditModeEnter, ns);
	EventRegistry:RegisterCallback("EditMode.Exit", OnEditModeExit, ns);
	if ns.InitSkin then
		ns.InitSkin(tracker);
	end
	ns.trackerReady = true;
end

-- ***********************************************************************************************
-- Loading
-- ***********************************************************************************************

local function InitDB()
	ScrollableQuestTrackerDB = ScrollableQuestTrackerDB or {};
	db = ScrollableQuestTrackerDB;
	for key, value in pairs(ns.DEFAULTS) do
		if db[key] == nil then
			db[key] = value;
		end
	end
	db.maxHeight = Clamp(db.maxHeight, ns.MAX_HEIGHT_MIN, ns.MAX_HEIGHT_MAX);
	db.backgroundOpacity = Clamp(db.backgroundOpacity, 0, 100);
	ns.db = db;
end

local loader = CreateFrame("Frame");
loader:RegisterEvent("ADDON_LOADED");
loader:SetScript("OnEvent", function(self, _event, addonName)
	if addonName == ADDON_NAME then
		InitDB();
	end

	if not db then
		return;
	end

	if not ns.trackerReady and ObjectiveTrackerFrame then
		InitTracker();
	end

	if not ns.editModeReady and EditModeSystemSettingsDialog and ns.InitEditModeSettings then
		ns.InitEditModeSettings();
	end

	if ns.trackerReady and ns.editModeReady then
		self:UnregisterEvent("ADDON_LOADED");
	end
end);
