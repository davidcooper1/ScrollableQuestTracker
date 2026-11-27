--[[
	Scrollable Quest Tracker - Caith-style skin

	A dark, bevelled, pixel-crisp look in the spirit of the Masque: Caith button skin:
	  - a charcoal border with a black outer and inner edge and a subtle bevel (lighter
	    top/left, darker bottom/right) around the whole tracker, scroll bar included;
	  - a semi-transparent black background (opacity is a setting);
	  - darker, desaturated header banners;
	  - a matching flat scroll bar (dark track, charcoal thumb, grey arrows).

	Everything is drawn with flat colour textures, so no art files are shipped.

	Taint: same rules as Core.lua. The skin is our own frame; Blizzard's regions are only touched
	through C widget methods (SetAlpha, SetVertexColor, SetDesaturated), and Blizzard functions are
	only post-hooked with hooksecurefunc.
]]

local _, ns = ...;

local WHITE = "Interface\\Buttons\\WHITE8X8";

local COLOR_OUTER = { 0, 0, 0, 1 };
local COLOR_FRAME = { 0.17, 0.17, 0.17, 1 };
local COLOR_LIGHT = { 0.36, 0.36, 0.36, 1 };
local COLOR_DARK = { 0.07, 0.07, 0.07, 1 };
local COLOR_INNER = { 0, 0, 0, 1 };
local HEADER_TINT = { 0.42, 0.42, 0.42 };

local THUMB_UP = { 0.30, 0.30, 0.30, 1 };
local THUMB_OVER = { 0.42, 0.42, 0.42, 1 };
local THUMB_DOWN = { 0.24, 0.24, 0.24, 1 };
local ARROW_TINT = { 0.75, 0.75, 0.75 };

-- Skin box placement relative to the tracker's own background (NineSlice) and right edge.
local PAD_LEFT = 8;
local PAD_TOP = 4;
local PAD_BOTTOM = 2;
local RIGHT_EDGE = 26;		-- past the tracker's right edge, so the scroll bar sits inside the border

-- Border rings, from the outside in (in physical pixels).
local BORDER_PIXELS = 5;

local tracker;
local skinFrame, borderFrame, background;

-- Drawing order inside the tracker (frame level above the tracker):
--   background (+0) < quest contents < scroll bar (+50) < bottom fade (+60)
--   < scroll bar's down arrow (+65) < border (+70)
local BORDER_FRAME_LEVEL = 70;
local DOWN_ARROW_FRAME_LEVEL = 65;
local rings = {};
local skinnedBar;
local barParts;

local function GetDB()
	return ns.db;
end

local function IsSkinEnabled()
	local db = GetDB();
	return db and db.skinEnabled;
end

local function GetPixel(frame)
	return PixelUtil.GetNearestPixelSize(1, frame:GetEffectiveScale(), 1);
end

-- ***********************************************************************************************
-- Edge helpers
-- ***********************************************************************************************

local function NewEdgeSet(parent, layer, subLevel, color, sides)
	local set = { sides = sides or { TOP = true, BOTTOM = true, LEFT = true, RIGHT = true } };
	for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
		local texture = parent:CreateTexture(nil, layer, nil, subLevel);
		texture:SetTexture(WHITE);
		texture:SetVertexColor(unpack(color));
		texture:SetShown(set.sides[side] == true);
		set[side] = texture;
	end
	return set;
end

-- Positions a ring `insetPx` pixels inside `parent`, `thickPx` pixels thick.
local function LayoutEdgeSet(set, parent, insetPx, thickPx, px)
	local i, t = insetPx * px, thickPx * px;

	set.TOP:ClearAllPoints();
	set.TOP:SetPoint("TOPLEFT", parent, "TOPLEFT", i, -i);
	set.TOP:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -i, -i);
	set.TOP:SetHeight(t);

	set.BOTTOM:ClearAllPoints();
	set.BOTTOM:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", i, i);
	set.BOTTOM:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -i, i);
	set.BOTTOM:SetHeight(t);

	set.LEFT:ClearAllPoints();
	set.LEFT:SetPoint("TOPLEFT", parent, "TOPLEFT", i, -(i + t));
	set.LEFT:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", i, i + t);
	set.LEFT:SetWidth(t);

	set.RIGHT:ClearAllPoints();
	set.RIGHT:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -i, -(i + t));
	set.RIGHT:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -i, i + t);
	set.RIGHT:SetWidth(t);
end

-- ***********************************************************************************************
-- Tracker box
-- ***********************************************************************************************

local function LayoutBorder()
	if not skinFrame then
		return;
	end
	local px = GetPixel(skinFrame);
	LayoutEdgeSet(rings.outer, skinFrame, 0, 1, px);
	LayoutEdgeSet(rings.frame, skinFrame, 1, 3, px);
	LayoutEdgeSet(rings.light, skinFrame, 1, 1, px);
	LayoutEdgeSet(rings.dark, skinFrame, 3, 1, px);
	LayoutEdgeSet(rings.inner, skinFrame, 4, 1, px);

	background:ClearAllPoints();
	background:SetPoint("TOPLEFT", skinFrame, "TOPLEFT", BORDER_PIXELS * px, -BORDER_PIXELS * px);
	background:SetPoint("BOTTOMRIGHT", skinFrame, "BOTTOMRIGHT", -BORDER_PIXELS * px, BORDER_PIXELS * px);
end

local function CreateSkinFrame()
	local nineSlice = tracker.NineSlice;

	-- Child of the tracker's background panel, so it shows/hides and resizes with it, but ignores
	-- its alpha (we set that panel to 0 while skinned).
	skinFrame = CreateFrame("Frame", nil, nineSlice);
	skinFrame:SetIgnoreParentAlpha(true);
	skinFrame:SetFrameLevel(tracker:GetFrameLevel());
	skinFrame:SetPoint("TOPLEFT", nineSlice, "TOPLEFT", -PAD_LEFT, PAD_TOP);
	skinFrame:SetPoint("TOPRIGHT", tracker, "TOPRIGHT", RIGHT_EDGE, PAD_TOP);
	skinFrame:SetPoint("BOTTOMLEFT", nineSlice, "BOTTOMLEFT", -PAD_LEFT, -PAD_BOTTOM);

	-- The border lives on its own frame so it can draw above the bottom fade and the scroll bar.
	borderFrame = CreateFrame("Frame", nil, skinFrame);
	borderFrame:SetAllPoints(skinFrame);
	borderFrame:SetFrameLevel(tracker:GetFrameLevel() + BORDER_FRAME_LEVEL);

	background = skinFrame:CreateTexture(nil, "BACKGROUND");
	background:SetTexture(WHITE);
	background:SetVertexColor(0, 0, 0, 1);

	rings.outer = NewEdgeSet(borderFrame, "BORDER", 0, COLOR_OUTER);
	rings.frame = NewEdgeSet(borderFrame, "BORDER", 1, COLOR_FRAME);
	rings.light = NewEdgeSet(borderFrame, "BORDER", 2, COLOR_LIGHT, { TOP = true, LEFT = true });
	rings.dark = NewEdgeSet(borderFrame, "BORDER", 2, COLOR_DARK, { BOTTOM = true, RIGHT = true });
	rings.inner = NewEdgeSet(borderFrame, "BORDER", 3, COLOR_INNER);

	LayoutBorder();

	local events = CreateFrame("Frame");
	events:RegisterEvent("UI_SCALE_CHANGED");
	events:RegisterEvent("DISPLAY_SIZE_CHANGED");
	events:SetScript("OnEvent", LayoutBorder);
end

local function GetBlizzardBackgroundAlpha()
	return (ObjectiveTrackerManager and ObjectiveTrackerManager.backgroundAlpha) or 0;
end

local function StyleHeader(header, skinned)
	local art = header and header.Background;
	if not art then
		return;
	end
	art:SetDesaturated(skinned);
	if skinned then
		art:SetVertexColor(HEADER_TINT[1], HEADER_TINT[2], HEADER_TINT[3]);
	else
		art:SetVertexColor(1, 1, 1);
	end
end

local function StyleHeaders(skinned)
	StyleHeader(tracker.Header, skinned);
	for _, module in ipairs(tracker.modules or {}) do
		StyleHeader(module.Header, skinned);
	end
end

local lastAppliedSkinned = nil;

local function ApplyTrackerSkin()
	if not tracker then
		return;
	end

	local skinned = IsSkinEnabled();
	if skinned and not skinFrame then
		CreateSkinFrame();
	end

	if skinned then
		skinFrame:Show();
		background:SetAlpha((GetDB().backgroundOpacity or 60) / 100);
		tracker.NineSlice:SetAlpha(0);
		StyleHeaders(true);
	elseif lastAppliedSkinned then
		if skinFrame then
			skinFrame:Hide();
		end
		tracker.NineSlice:SetAlpha(GetBlizzardBackgroundAlpha());
		StyleHeaders(false);
	end

	lastAppliedSkinned = skinned;
end

-- Blizzard's Opacity setting re-sets the background panel's alpha; keep it hidden while skinned.
local function OnSetBackgroundAlpha()
	if IsSkinEnabled() then
		tracker.NineSlice:SetAlpha(0);
	end
end

-- ***********************************************************************************************
-- Scroll bar
-- ***********************************************************************************************

local function SetColor(texture, color)
	texture:SetVertexColor(color[1], color[2], color[3], color[4] or 1);
end

local function UpdateThumbColor()
	if not barParts then
		return;
	end
	local thumb = skinnedBar.Track.Thumb;
	local color = THUMB_UP;
	if thumb:IsEnabled() then
		if thumb.down then
			color = THUMB_DOWN;
		elseif thumb.over then
			color = THUMB_OVER;
		end
	end
	SetColor(barParts.thumbFill, color);
end

local function StyleArrow(stepper)
	if not stepper.Texture then
		return;
	end
	local skinned = IsSkinEnabled();
	stepper.Texture:SetDesaturated(skinned);
	if skinned then
		stepper.Texture:SetVertexColor(ARROW_TINT[1], ARROW_TINT[2], ARROW_TINT[3]);
	else
		stepper.Texture:SetVertexColor(1, 1, 1);
	end
end

local function LayoutBarParts()
	if not barParts then
		return;
	end
	local px = GetPixel(skinnedBar);
	LayoutEdgeSet(barParts.trackBorder, skinnedBar.Track, 0, 1, px);
	barParts.trackFill:ClearAllPoints();
	barParts.trackFill:SetPoint("TOPLEFT", skinnedBar.Track, "TOPLEFT", px, -px);
	barParts.trackFill:SetPoint("BOTTOMRIGHT", skinnedBar.Track, "BOTTOMRIGHT", -px, px);

	local thumb = skinnedBar.Track.Thumb;
	LayoutEdgeSet(barParts.thumbBorder, thumb, 0, 1, px);
	barParts.thumbFill:ClearAllPoints();
	barParts.thumbFill:SetPoint("TOPLEFT", thumb, "TOPLEFT", px, -px);
	barParts.thumbFill:SetPoint("BOTTOMRIGHT", thumb, "BOTTOMRIGHT", -px, px);
	LayoutEdgeSet(barParts.thumbLight, thumb, 1, 1, px);
end

function ns.UpdateScrollBarSkin()
	if not skinnedBar then
		return;
	end

	local bar = skinnedBar;
	local skinned = IsSkinEnabled();
	local blizzardAlpha = skinned and 0 or 1;

	for _, region in ipairs({ bar.Track.Begin, bar.Track.Middle, bar.Track.End, bar.Track.Thumb.Begin, bar.Track.Thumb.Middle, bar.Track.Thumb.End }) do
		region:SetAlpha(blizzardAlpha);
	end

	if skinned and not barParts then
		local thumb = bar.Track.Thumb;
		barParts = {
			trackFill = bar.Track:CreateTexture(nil, "BACKGROUND", nil, 1),
			trackBorder = NewEdgeSet(bar.Track, "BORDER", 0, COLOR_OUTER),
			thumbFill = thumb:CreateTexture(nil, "ARTWORK", nil, 5),
			thumbBorder = NewEdgeSet(thumb, "ARTWORK", 6, COLOR_OUTER),
			thumbLight = NewEdgeSet(thumb, "ARTWORK", 7, { 0.5, 0.5, 0.5, 1 }, { TOP = true }),
		};
		barParts.trackFill:SetTexture(WHITE);
		barParts.trackFill:SetVertexColor(0, 0, 0, 0.55);
		barParts.thumbFill:SetTexture(WHITE);
		LayoutBarParts();
	end

	if barParts then
		barParts.trackFill:SetShown(skinned);
		barParts.thumbFill:SetShown(skinned);
		for _, set in ipairs({ barParts.trackBorder, barParts.thumbBorder, barParts.thumbLight }) do
			for side, shown in pairs(set.sides) do
				set[side]:SetShown(skinned and shown);
			end
		end
	end

	StyleArrow(bar.Back);
	StyleArrow(bar.Forward);
	UpdateThumbColor();
end

-- Called by Core.lua once its scroll bar exists. The bar is our own frame, so hooking its methods
-- is fine.
function ns.SkinScrollBar(bar)
	skinnedBar = bar;

	-- Lift the down arrow above the bottom fade so it isn't darkened; the rest of the bar stays under it.
	bar.Forward:SetFrameLevel(tracker:GetFrameLevel() + DOWN_ARROW_FRAME_LEVEL);

	hooksecurefunc(bar.Track.Thumb, "OnButtonStateChanged", UpdateThumbColor);
	hooksecurefunc(bar.Back, "OnButtonStateChanged", StyleArrow);
	hooksecurefunc(bar.Forward, "OnButtonStateChanged", StyleArrow);

	local events = CreateFrame("Frame");
	events:RegisterEvent("UI_SCALE_CHANGED");
	events:RegisterEvent("DISPLAY_SIZE_CHANGED");
	events:SetScript("OnEvent", LayoutBarParts);

	ns.UpdateScrollBarSkin();
end

-- ***********************************************************************************************
-- Bottom fade ("blur")
-- ***********************************************************************************************
-- WoW's UI can't blur what's behind a frame, so this fakes it with three stacked black gradients
-- (tall/faint, medium, short/strong). Together they go from clear to nearly opaque (about 93%) at
-- the bottom edge with a soft, eased falloff. It only shows when there's more content below, and
-- eases out over the last few pixels of scrolling so it's gone at the very bottom.
--
-- It spans the skin's full outer box and sits under the border (the border is drawn above it), so
-- the fade reaches right to the border with no gap. It's drawn above the scroll bar, so the bottom
-- of the bar fades along with the quest text.

local FADE_TALL_HEIGHT = 64;
local FADE_TALL_ALPHA = 0.55;
local FADE_MID_HEIGHT = 32;
local FADE_MID_ALPHA = 0.5;
local FADE_SHORT_HEIGHT = 14;
local FADE_SHORT_ALPHA = 0.7;
local FADE_MAX_VIEW_FRACTION = 0.4;	-- never cover more than this much of the visible list
local FADE_EASE_DISTANCE = 40;		-- pixels from the bottom over which the fade eases out
local FADE_FRAME_LEVEL = 60;		-- above the scroll bar (+50), below the border (+70)

local fadeViewport;
local fadeFrame, fadeTall, fadeMid, fadeShort;

local function SetBottomGradient(texture, alpha)
	texture:SetGradient("VERTICAL", CreateColor(0, 0, 0, alpha), CreateColor(0, 0, 0, 0));
end

local function CreateFadeLayer(subLevel, height, alpha)
	local texture = fadeFrame:CreateTexture(nil, "OVERLAY", nil, subLevel);
	texture:SetTexture(WHITE);
	texture:SetPoint("BOTTOMLEFT");
	texture:SetPoint("BOTTOMRIGHT");
	texture:SetHeight(height);
	SetBottomGradient(texture, alpha);
	return texture;
end

-- Needs the skin frame, which is only created once the skin is first enabled.
local function CreateFadeFrame()
	if fadeFrame or not skinFrame then
		return;
	end

	fadeFrame = CreateFrame("Frame", nil, skinFrame);
	fadeFrame:SetFrameLevel(tracker:GetFrameLevel() + FADE_FRAME_LEVEL);
	-- Full outer box of the skin: the fade runs under the border all the way to its outer edge,
	-- so no strip of quest text is left uncovered between the fade and the border.
	fadeFrame:SetPoint("BOTTOMLEFT", skinFrame, "BOTTOMLEFT", 0, 0);
	fadeFrame:SetPoint("BOTTOMRIGHT", skinFrame, "BOTTOMRIGHT", 0, 0);
	fadeFrame:SetHeight(FADE_TALL_HEIGHT);
	fadeFrame:Hide();

	fadeTall = CreateFadeLayer(1, FADE_TALL_HEIGHT, FADE_TALL_ALPHA);
	fadeMid = CreateFadeLayer(2, FADE_MID_HEIGHT, FADE_MID_ALPHA);
	fadeShort = CreateFadeLayer(3, FADE_SHORT_HEIGHT, FADE_SHORT_ALPHA);
end

-- Called by Core.lua once its viewport exists.
function ns.AttachScrollFade(viewport)
	if fadeViewport then
		return;
	end
	fadeViewport = viewport;
	viewport:HookScript("OnVerticalScroll", function()
		ns.UpdateScrollFade();
	end);
end

function ns.UpdateScrollFade()
	local active, viewport, scrollRange = ns.GetScrollInfo();
	if not (IsSkinEnabled() and active and viewport and scrollRange > 0) then
		if fadeFrame then
			fadeFrame:Hide();
		end
		return;
	end

	CreateFadeFrame();
	if not fadeFrame then
		return;
	end

	local remaining = scrollRange - viewport:GetVerticalScroll();
	local strength = Clamp(remaining / FADE_EASE_DISTANCE, 0, 1);
	if strength <= 0 then
		fadeFrame:Hide();
		return;
	end

	-- Scale the layers down together on short viewports.
	-- The bottom few pixels sit under the border, so add that on top of the visible height.
	local underBorder = (BORDER_PIXELS * GetPixel(skinFrame)) + PAD_BOTTOM;
	local height = math.min(FADE_TALL_HEIGHT, viewport:GetHeight() * FADE_MAX_VIEW_FRACTION) + underBorder;
	local scale = height / FADE_TALL_HEIGHT;
	fadeFrame:SetHeight(height);
	fadeTall:SetHeight(height);
	fadeMid:SetHeight(FADE_MID_HEIGHT * scale);
	fadeShort:SetHeight(FADE_SHORT_HEIGHT * scale);

	fadeFrame:SetAlpha(strength);
	fadeFrame:Show();
end

-- ***********************************************************************************************
-- Init / settings
-- ***********************************************************************************************

function ns.ApplySkin()
	ApplyTrackerSkin();
	ns.UpdateScrollBarSkin();
	ns.UpdateScrollFade();
end

function ns.InitSkin(trackerFrame)
	tracker = trackerFrame;
	-- Runs after every tracker layout pass, so headers on newly shown modules get styled.
	hooksecurefunc(tracker, "UpdateHeaderPosition", ApplyTrackerSkin);
	hooksecurefunc(tracker, "SetBackgroundAlpha", OnSetBackgroundAlpha);
	ApplyTrackerSkin();
end
