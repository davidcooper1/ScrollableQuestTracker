--[[
	Scrollable Quest Tracker - Edit Mode settings

	Adds rows under the Objective Tracker's own settings in the Edit Mode settings dialog:
	  - Scrollable Tracker (checkbox)
	  - Max Height (slider)
	  - Always Show Scroll Bar (checkbox)
	  - Caith Style (checkbox)
	  - Background (opacity slider, 0-100%)

	The rows use the same templates/fonts as Blizzard's rows. They live in our own panel frame
	parented to the dialog (not inside Blizzard's pooled Settings frame), and the dialog's button
	area is re-anchored below the panel with a plain SetPoint. The dialog's own Layout() then sizes
	around it. Changes apply and save immediately; they aren't part of the Edit Mode layout data.
]]

local _, ns = ...;
local L = ns.L;

local ROW_WIDTH = 343;
local ROW_SPACING = 2;

local panel;
local enableRow, heightRow, alwaysShowRow, skinRow, opacityRow;
local rows = {};

local function GetDB()
	return ns.db;
end

-- ***********************************************************************************************
-- Row builders
-- ***********************************************************************************************

local function CreateCheckboxRow(parent, label, onToggle)
	local row = CreateFrame("Frame", nil, parent, "EditModeSettingCheckboxTemplate");
	row.labelText = label;

	-- The template's CheckButton calls self:GetParent():OnCheckButtonClick().
	row.OnCheckButtonClick = function(self)
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON);
		self.checked = not self.checked;
		onToggle(self.checked);
	end

	row.Refresh = function(self, checked, disabled, disabledTooltip)
		self:SetupSetting({
			displayInfo = {
				setting = 0,
				disabled = disabled,
				disabledTooltipText = disabledTooltip,
			},
			currentValue = checked and 1 or 0,
			settingName = self.labelText,
		});
		self:Show();
		self:Layout();
	end

	return row;
end

local function CreateSliderRow(parent, label, minValue, maxValue, step, onChange, formatValue)
	local row = CreateFrame("Frame", nil, parent);
	row:SetSize(ROW_WIDTH, 32);

	row.Label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium");
	row.Label:SetSize(100, 32);
	row.Label:SetJustifyH("LEFT");
	row.Label:SetPoint("LEFT");
	row.Label:SetText(label);

	row.Slider = CreateFrame("Frame", nil, row, "MinimalSliderWithSteppersTemplate");
	row.Slider:SetSize(200, 32);
	row.Slider:SetPoint("LEFT", row.Label, "RIGHT", 5, 0);

	local rightLabel = MinimalSliderWithSteppersMixin.Label.Right;
	row.formatters = {
		[rightLabel] = CreateMinimalSliderFormatter(rightLabel, formatValue or function(value)
			return tostring(Round(value));
		end),
	};

	row.Slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_owner, value)
		if not row.initializing then
			onChange(Round(value / step) * step);
		end
	end, row);

	row.Refresh = function(self, value, disabled)
		-- Don't re-init while the player is dragging this slider.
		if not self.Slider.Slider:IsDraggingThumb() then
			self.initializing = true;
			self.Slider:Init(value, minValue, maxValue, (maxValue - minValue) / step, self.formatters);
			self.initializing = false;
		end
		self.Slider:SetEnabled(not disabled);
		self.Label:SetFontObject(disabled and "GameFontDisableMed2" or "GameFontHighlightMedium");
		self:Show();
	end

	return row;
end

-- ***********************************************************************************************
-- Panel
-- ***********************************************************************************************

local function LayoutRows()
	local y = 0;
	for _, row in ipairs(rows) do
		row:ClearAllPoints();
		row:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -y);
		y = y + row:GetHeight() + ROW_SPACING;
	end
	panel:SetSize(ROW_WIDTH, math.max(y - ROW_SPACING, 1));
end

local function RefreshPanel()
	local db = GetDB();
	local scrolling = db.enabled;

	enableRow:Refresh(db.enabled, false);
	heightRow:Refresh(db.maxHeight, not scrolling);
	alwaysShowRow:Refresh(db.alwaysShowScrollBar, not scrolling);
	skinRow:Refresh(db.skinEnabled, false);
	opacityRow:Refresh(db.backgroundOpacity, not db.skinEnabled);
	LayoutRows();
end

local function OnEnableToggled(checked)
	GetDB().enabled = checked;
	ns.OnSettingsChanged();
	RefreshPanel();
end

local function OnMaxHeightChanged(value)
	local db = GetDB();
	value = Clamp(value, ns.MAX_HEIGHT_MIN, ns.MAX_HEIGHT_MAX);
	if db.maxHeight ~= value then
		db.maxHeight = value;
		ns.OnSettingsChanged();
	end
end

local function OnAlwaysShowToggled(checked)
	GetDB().alwaysShowScrollBar = checked;
	ns.OnSettingsChanged();
	RefreshPanel();
end

local function OnSkinToggled(checked)
	GetDB().skinEnabled = checked;
	ns.OnSettingsChanged();
	RefreshPanel();
end

local function OnOpacityChanged(value)
	local db = GetDB();
	value = Clamp(value, 0, 100);
	if db.backgroundOpacity ~= value then
		db.backgroundOpacity = value;
		ns.OnSettingsChanged();
	end
end

local function FormatPercent(value)
	return string.format("%d%%", Round(value));
end

local function CreatePanel(dialog)
	panel = CreateFrame("Frame", nil, dialog);
	panel:SetSize(ROW_WIDTH, 1);
	panel:Hide();

	enableRow = CreateCheckboxRow(panel, L.ENABLE, OnEnableToggled);
	heightRow = CreateSliderRow(panel, L.MAX_HEIGHT, ns.MAX_HEIGHT_MIN, ns.MAX_HEIGHT_MAX, ns.MAX_HEIGHT_STEP, OnMaxHeightChanged);
	alwaysShowRow = CreateCheckboxRow(panel, L.ALWAYS_SHOW_SCROLLBAR, OnAlwaysShowToggled);

	skinRow = CreateCheckboxRow(panel, L.SKIN, OnSkinToggled);
	opacityRow = CreateSliderRow(panel, L.BACKGROUND_OPACITY, 0, 100, 5, OnOpacityChanged, FormatPercent);

	rows = { enableRow, heightRow, alwaysShowRow, skinRow, opacityRow };
end

-- Post-hook of EditModeSystemSettingsDialog:UpdateSettings(). Blizzard re-anchors its Buttons
-- block under its Settings block each time; when the tracker is the selected system we slot our
-- panel in between. Blizzard's UpdateSizeAndAnchors() runs right after and resizes the dialog.
local function OnDialogUpdateSettings(dialog)
	if not panel then
		return;
	end

	if dialog.attachedToSystem ~= ObjectiveTrackerFrame then
		panel:Hide();
		return;
	end

	RefreshPanel();

	panel:ClearAllPoints();
	if dialog.Settings:IsShown() then
		panel:SetPoint("TOPLEFT", dialog.Settings, "BOTTOMLEFT", 0, -ROW_SPACING);
	else
		panel:SetPoint("TOP", dialog.Title, "BOTTOM", 0, -12);
	end
	panel:Show();

	dialog.Buttons:ClearAllPoints();
	dialog.Buttons:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 0, -12);
end

function ns.InitEditModeSettings()
	local dialog = EditModeSystemSettingsDialog;
	CreatePanel(dialog);
	hooksecurefunc(dialog, "UpdateSettings", OnDialogUpdateSettings);
	ns.editModeReady = true;
end
