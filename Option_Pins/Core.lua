--[[
	Option Pins  -  World of Warcraft: Forever (interface 16001)

	Quick-access controls for game settings, in four kinds:

	  bubble  a round minimap button (Core.lua)          - on/off or cycle settings
	  float   a free-floating button (Floating.lua)       - on/off or cycle settings
	  slider  a row in the shared slider panel (Sliders.lua)
	  block   a free-floating single-slider block (Sliders.lua)

	Options.lua reads every setting in the game's Options window and adds tick boxes next
	to each one there, so any of them can become a bubble, float, slider row or block.
	Toggles/*.lua and Sliders/Display.lua are hand-made ones with custom art (SD/HD, the
	music note) or that predate the Options integration (brightness, contrast, gamma).

	Core.lua is the framework: the element registry and saved settings, the minimap button
	factory, the right-click menu, the slash command and key bindings, events, and a
	half-second poll that keeps every control in step with the game if a setting is
	changed somewhere else.
]]

local ADDON_NAME = ...

local QT = {
	toggles = {}, byKey = {}, buttons = {}, -- minimap bubbles; buttons = key -> frame
	floats = {}, floatByKey = {},           -- free-floating buttons (Floating.lua)
	sliders = {}, sliderByKey = {},         -- shared slider panel rows (Sliders.lua)
	blocks = {}, blockByKey = {},           -- free-floating slider blocks (Sliders.lua)
	all = {},                               -- key -> def, every kind
}
_G.OptionPins = QT

-- One entry per element kind. Floating.lua and Sliders.lua fill in Setup / Refresh /
-- RefreshAll / Sync / Reset for theirs; the bubble ones are below.
QT.kindOrder = { "bubble", "float", "slider", "block" }
QT.kinds = {
	bubble = { title = "Minimap buttons",  noun = "button",          list = QT.toggles, byKey = QT.byKey,      store = "buttons" },
	float  = { title = "Floating buttons", noun = "floating button", list = QT.floats,  byKey = QT.floatByKey, store = "floats" },
	slider = { title = "Slider panel",     noun = "slider",          list = QT.sliders, byKey = QT.sliderByKey, store = "sliders" },
	block  = { title = "Floating sliders", noun = "floating slider", list = QT.blocks,  byKey = QT.blockByKey, store = "blocks" },
}

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

local DEFAULTS = {
	shown = true,      -- master switch for everything
	locked = false,    -- true = nothing can be dragged
	sound = true,      -- click sound on every flip
	announce = true,   -- chat line on every flip
	allowProxy = false, -- allow settings that run Blizzard code (Options.lua)
	buttons = {},      -- bubble key -> { enabled, angle }
	floats = {},       -- float key  -> { enabled, pos }
	sliders = {},      -- slider key -> { enabled }
	blocks = {},       -- block key  -> { enabled, pos }
	undo = {},         -- setting (undo key) -> value to undo back to
	sliderPos = false, -- slider panel { point, relPoint, x, y } relative to UIParent; false = default
	sliderCollapsed = false, -- slider panel folded down to its header
	stack = {},        -- { enabled, angle, open }: minimap buttons stacked into one "..." dot
}

local db -- OptionPinsDB after ADDON_LOADED
function QT:DB() return db end

local POLL = 0.5     -- seconds between re-reads of every setting
local RING_PAD = 5   -- px outside the minimap edge
local YELLOW = { 1, 0.82, 0 }
QT.YELLOW = YELLOW

local function Print(msg)
	print("|cff33ff99Option Pins:|r " .. msg)
end
QT.Print = Print

local RegisterDefEvents -- set in the events section

-------------------------------------------------------------------------------
-- Registry
-------------------------------------------------------------------------------

--[[
	Bubble and float defs (on/off or cycle settings):
	def = {
		key = "music",               -- saved variables, /pins <key>, bindings
		name = "Music",              -- menu and tooltip title
		defaultAngle = 200,          -- bubbles: where on the minimap ring it first appears (0 = right, 90 = top)
		defaultEnabled = true,       -- shown until the user unticks it (default true)
		IsAvailable = function() return ok, reasonIfNot end,   -- optional
		Get = function() return value end,                      -- current value (nil = unknown)
		Set = function(value) end,                              -- write it to the game
		Next = function(value) return other end,                -- optional, default `not value`
		Prev = function(value) return other end,                -- optional, shift-click; default Next
		Describe = function(value) return "music on" end,       -- for chat lines
		Parse = function(text) return value end,                -- optional, for "/pins music off"
		isToggle = true,                                        -- on/off (check / red X) vs cycle
		Create = function(button, disc) end,                    -- bubbles: build textures once
		Update = function(button, value) end,                   -- bubbles: draw the current value
		Tooltip = function(tooltip, value) end,                 -- optional extra lines
		events = { "CVAR_UPDATE" },                             -- optional, re-read on these
	}
	Slider and block defs: see Sliders.lua.
]]
function QT:RegisterElement(kind, def)
	local k = self.kinds[kind]
	assert(k, "Option Pins: unknown kind " .. tostring(kind))
	assert(type(def) == "table" and def.key and def.name, "Option Pins: bad definition")
	assert(not self.all[def.key], "Option Pins: duplicate key " .. tostring(def.key))
	def.kind = kind
	if def.defaultEnabled == nil then def.defaultEnabled = true end
	k.list[#k.list + 1] = def
	k.byKey[def.key] = def
	self.all[def.key] = def
	if db then
		if k.Setup then k.Setup(def) end
		RegisterDefEvents(def)
	end
	return def
end

local function ToggleDefaults(def)
	assert(def.Get and def.Set, "Option Pins: toggle needs Get and Set")
	def.Describe = def.Describe or function(v) return tostring(v) end
	def.Next = def.Next or function(v) return not v end
	def.Prev = def.Prev or def.Next
	if def.isToggle == nil then def.isToggle = true end
end
QT.ToggleDefaults = ToggleDefaults

-- Minimap bubble.
function QT:Register(def)
	ToggleDefaults(def)
	return self:RegisterElement("bubble", def)
end

function QT:Available(def)
	if def.IsAvailable then
		local ok, reason = def.IsAvailable()
		return ok and true or false, reason
	end
	return true
end

function QT:Settings(key)
	local def = self.all[key]
	local store = db[(def and self.kinds[def.kind].store) or "buttons"]
	local s = store[key]
	if not s then
		s = {}
		store[key] = s
	end
	if s.enabled == nil then s.enabled = not (def and def.defaultEnabled == false) end
	if def and def.kind == "bubble" and s.angle == nil then s.angle = def.defaultAngle or 220 end
	return s
end

function QT:IsEnabled(key)
	return self.all[key] ~= nil and self:Settings(key).enabled
end

-- Undo points are shared by every control for the same setting (a panel row and a block).
function QT:GetUndo(def) return db.undo[def.undoKey or def.key] end
function QT:SetUndo(def, v) db.undo[def.undoKey or def.key] = v end

-------------------------------------------------------------------------------
-- Minimap buttons
-------------------------------------------------------------------------------

-- Half the live minimap width plus a few px puts the button on the outer ring beside the
-- calendar and tracking buttons, whatever size the minimap is.
local function MinimapRadius()
	local w = Minimap and Minimap.GetWidth and Minimap:GetWidth()
	if not w or w < 50 then return 80 end
	return w / 2 + RING_PAD
end

-------------------------------------------------------------------------------
-- Stacking: with "Stack minimap buttons" on and two or more Option Pins buttons showing,
-- they fold into one "..." dot on the ring. Clicking it fans them out in an arc just
-- outside the ring, centred on the dot (more arcs further out if they don't fit);
-- clicking it again folds them back.
-------------------------------------------------------------------------------

local STACK_ANGLE = 170   -- where the stack dot first appears
-- A minimap button is 31 px plus its ring, so 34 px centre to centre leaves a gap of a
-- couple of pixels. /pins fan <spacing> <distance> changes both in game (saved).
local FAN_OUT = 34        -- how far outside the ring the fan's first arc sits (and each further arc)
local FAN_GAP = 34        -- centre-to-centre distance between neighbouring fanned dots
local FAN_MIN, FAN_MAX = 20, 80

local function Stack()
	local st = db.stack
	if st.enabled == nil then st.enabled = false end
	if st.angle == nil then st.angle = STACK_ANGLE end
	if st.open == nil then st.open = false end
	return st
end
QT.StackState = function() return Stack() end

local function FanGap() return Stack().gap or FAN_GAP end
local function FanOut() return Stack().out or FAN_OUT end

local function RingPoint(b, angleDeg, r)
	local a = math.rad(angleDeg)
	b:ClearAllPoints()
	b:SetPoint("CENTER", Minimap or UIParent, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

-- Fan slot `i` of `n`: arcs outside the ring, centred on the stack dot's angle.
local function FanPoint(b, i, n)
	local R = MinimapRadius()
	local gap, out = FanGap(), FanOut()
	local radius = R + out
	local arc, j, m = 0, i, n
	local step
	while true do
		-- Angle between neighbours so their centres are exactly `gap` apart (a chord).
		step = 2 * math.asin(math.min(1, gap / (2 * radius)))
		local cap = math.max(1, math.floor(2 * math.pi / step))
		if j <= cap then m = math.min(m, cap) break end
		j, m = j - cap, m - cap
		arc = arc + 1
		radius = radius + out
	end
	step = math.deg(step)
	RingPoint(b, Stack().angle + (j - (m + 1) / 2) * step, radius)
end

function QT:Place(def)
	local b = self.buttons[def.key]
	if not b then return end
	local slot = self.fanSlot and self.fanSlot[def.key]
	if slot then
		FanPoint(b, slot, self.fanCount)
	else
		RingPoint(b, self:Settings(def.key).angle, MinimapRadius())
	end
end

function QT:PlaceAll()
	for _, def in ipairs(self.toggles) do self:Place(def) end
	if self.stackButton then RingPoint(self.stackButton, Stack().angle, MinimapRadius()) end
end

if Minimap and Minimap.HookScript then
	Minimap:HookScript("OnSizeChanged", function()
		if db then QT:PlaceAll() end
	end)
end

-- Angle of the cursor around the minimap centre.
local function CursorAngle()
	local parent = Minimap or UIParent
	local mx, my = parent:GetCenter()
	local cx, cy = GetCursorPosition()
	local scale = parent:GetEffectiveScale()
	if not (mx and cx and scale and scale > 0) then return nil end
	cx, cy = cx / scale, cy / scale
	return math.deg(math.atan2(cy - my, cx - mx))
end

local function OnDrag(self)
	local a = CursorAngle()
	if not a then return end
	QT:Settings(self.def.key).angle = a
	QT:Place(self.def)
end

-- Shared tooltip for bubbles and floating buttons.
function QT:ToggleTooltip(frame, anchor)
	if not GameTooltip then return end
	local def = frame.def
	GameTooltip:SetOwner(frame, anchor or "ANCHOR_LEFT")
	GameTooltip:ClearLines()
	GameTooltip:AddLine(def.name)
	local ok, reason = QT:Available(def)
	if not ok then
		GameTooltip:AddLine(reason or "Not available.", 1, 0.3, 0.3, true)
	elseif def.Tooltip then
		def.Tooltip(GameTooltip, def.Get())
	else
		GameTooltip:AddLine("Now: " .. def.Describe(def.Get()), 1, 1, 1)
		GameTooltip:AddLine("Click for " .. def.Describe(def.Next(def.Get())) .. ".", 0.6, 1, 0.6)
		if not def.isToggle then
			GameTooltip:AddLine("Shift-click to go back.", 0.6, 1, 0.6)
		end
	end
	GameTooltip:AddLine(db.locked and "Right-click for the menu. Locked in place." or "Right-click for the menu. Drag to move.", 0.5, 0.5, 0.5)
	GameTooltip:AddLine("Alt-click to remove this button.", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

local function OnEnter(self) QT:ToggleTooltip(self, "ANCHOR_LEFT") end
local function OnLeave() if GameTooltip then GameTooltip:Hide() end end

-- Shared click handling for bubbles and floating buttons.
-- Alt-click removes the button (same as unticking it in the menu); the setting is left alone.
function QT:ToggleClick(frame, mouseButton)
	if mouseButton == "RightButton" then
		self:OpenMenu(frame)
	elseif IsAltKeyDown and IsAltKeyDown() then
		if GameTooltip and GameTooltip:IsOwned(frame) then GameTooltip:Hide() end
		self:SetEnabled(frame.def.key, false)
		Print(self:ElementName(frame.def.key) .. " removed. Add it back from the menu (right-click another control, or /pins) or the Options window.")
	else
		self:Press(frame.def.key, nil, IsShiftKeyDown and IsShiftKeyDown())
	end
end

local function CreateButton(def)
	local b = CreateFrame("Button", "OptionPins_" .. def.key:gsub("[^%w_]", "_") .. "_Button", Minimap or UIParent)
	b.def = def
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetSize(21, 21)
	b.bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	b.bg:SetPoint("TOPLEFT", 6, -5)
	b.disc = b:CreateTexture(nil, "BORDER")
	b.disc:SetSize(19, 19)
	b.disc:SetColorTexture(0.05, 0.05, 0.05, 0.9)
	b.disc:SetPoint("CENTER", b.bg, "CENTER")
	b.ring = b:CreateTexture(nil, "OVERLAY")
	b.ring:SetSize(53, 53)
	b.ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	b.ring:SetPoint("TOPLEFT")
	if def.Create then def.Create(b, b.disc) end

	b:SetScript("OnClick", function(self, mouseButton) QT:ToggleClick(self, mouseButton) end)
	b:SetScript("OnDragStart", function(self)
		if db.locked or (QT.fanSlot and QT.fanSlot[def.key]) then return end -- fanned dots stay in the fan
		self:SetScript("OnUpdate", OnDrag)
	end)
	b:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	b:SetScript("OnEnter", OnEnter)
	b:SetScript("OnLeave", OnLeave)
	b:Hide()
	return b
end

-- Redraw one bubble from the game's current value.
function QT:Update(def)
	local b = self.buttons[def.key]
	if not b then return end
	local value = def.Get()
	b.last = value
	if def.Update then def.Update(b, value) end
	if GameTooltip and GameTooltip:IsOwned(b) then OnEnter(b) end
end

local function Wanted(def)
	return db.shown and QT:IsEnabled(def.key) and QT:Available(def)
end

-- The stack dot: the usual round button with three yellow dots in it.
local function StackTooltip(self)
	if not GameTooltip then return end
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:ClearLines()
	GameTooltip:AddLine("Option Pins (" .. #(QT.stacked or {}) .. ")")
	for _, def in ipairs(QT.stacked or {}) do
		GameTooltip:AddDoubleLine(def.name, def.Describe(def.Get()), 1, 1, 1, 1, 0.82, 0)
	end
	GameTooltip:AddLine(Stack().open and "Click to fold them back in." or "Click to show them.", 0.6, 1, 0.6)
	GameTooltip:AddLine(db.locked and "Right-click for the menu. Locked in place." or "Right-click for the menu. Drag to move.", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

local function CreateStackButton()
	local b = CreateFrame("Button", "OptionPinsStackButton", Minimap or UIParent)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(9)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetSize(21, 21)
	b.bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	b.bg:SetPoint("TOPLEFT", 6, -5)
	b.disc = b:CreateTexture(nil, "BORDER")
	b.disc:SetSize(19, 19)
	b.disc:SetColorTexture(0.05, 0.05, 0.05, 0.9)
	b.disc:SetPoint("CENTER", b.bg, "CENTER")
	b.ring = b:CreateTexture(nil, "OVERLAY")
	b.ring:SetSize(53, 53)
	b.ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	b.ring:SetPoint("TOPLEFT")
	b.dots = {}
	for i = -1, 1 do
		local d = b:CreateTexture(nil, "ARTWORK")
		d:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask") -- a filled disc
		d:SetVertexColor(QT.YELLOW[1], QT.YELLOW[2], QT.YELLOW[3])
		d:SetSize(4, 4)
		d:SetPoint("CENTER", b.disc, "CENTER", i * 5, 0)
		b.dots[#b.dots + 1] = d
	end
	b:SetScript("OnClick", function(self, mouseButton)
		if mouseButton == "RightButton" then
			QT:OpenMenu(self)
		else
			QT:SetStackOpen(not Stack().open)
		end
	end)
	b:SetScript("OnDragStart", function(self)
		if db.locked then return end
		self:SetScript("OnUpdate", function()
			local a = CursorAngle()
			if not a then return end
			Stack().angle = a
			QT:PlaceAll()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnEnter", StackTooltip)
	b:SetScript("OnLeave", OnLeave)
	b:Hide()
	return b
end

-- Decides, for all minimap buttons at once, which show, where, and whether the stack dot
-- shows: stacked needs the option on and at least two buttons to stack.
function QT:RefreshBubbles()
	local st = Stack()
	local wanted = {}
	for _, def in ipairs(self.toggles) do
		if self.buttons[def.key] and Wanted(def) then wanted[#wanted + 1] = def end
	end
	local stacked = st.enabled and #wanted >= 2
	self.stacked = stacked and wanted or nil
	self.fanSlot, self.fanCount = nil, 0
	if stacked and st.open then
		self.fanSlot, self.fanCount = {}, #wanted
		for i, def in ipairs(wanted) do self.fanSlot[def.key] = i end
	end
	for _, def in ipairs(self.toggles) do
		local b = self.buttons[def.key]
		if b then
			self:Place(def)
			if Wanted(def) and (not stacked or st.open) then
				self:Update(def)
				b:Show()
			else
				b:Hide()
			end
		end
	end
	if not self.stackButton then self.stackButton = CreateStackButton() end
	RingPoint(self.stackButton, st.angle, MinimapRadius())
	if stacked then self.stackButton:Show() else self.stackButton:Hide() end
	if GameTooltip and GameTooltip:IsOwned(self.stackButton) then StackTooltip(self.stackButton) end
end

function QT:ApplyVisibility(def)
	self:RefreshBubbles()
end

function QT:SetStacked(on)
	local st = Stack()
	st.enabled = on and true or false
	st.open = false
	self:RefreshBubbles()
end

function QT:SetStackOpen(open)
	Stack().open = open and true or false
	self:RefreshBubbles()
end

function QT:Setup(def)
	if not self.buttons[def.key] then
		self.buttons[def.key] = CreateButton(def)
	end
	self:Settings(def.key)
	self:Place(def)
	self:ApplyVisibility(def)
end

do
	local k = QT.kinds.bubble
	k.Setup = function(def) QT:Setup(def) end
	k.Refresh = function(def) QT:ApplyVisibility(def) end
	k.RefreshAll = function() QT:RefreshBubbles() end
	k.Sync = function()
		for _, def in ipairs(QT.toggles) do
			local b = QT.buttons[def.key]
			if b and b:IsShown() and def.Get() ~= b.last then QT:Update(def) end
		end
	end
	k.Reset = function()
		for _, def in ipairs(QT.toggles) do QT:Settings(def.key).angle = def.defaultAngle or 220 end
		Stack().angle = STACK_ANGLE
		QT:RefreshBubbles()
	end
end

function QT:Refresh()
	for _, kind in ipairs(self.kindOrder) do
		local k = self.kinds[kind]
		if k.RefreshAll then k.RefreshAll() end
	end
end

-- Re-read every visible control (after a change, an event, or on the poll).
function QT:SyncAll()
	for _, kind in ipairs(self.kindOrder) do
		local k = self.kinds[kind]
		if k.Sync then k.Sync() end
	end
end

-------------------------------------------------------------------------------
-- Flipping a setting
-------------------------------------------------------------------------------

-- Flip bubble or floating button `key` (backwards for cycles when `back`), or set it to
-- `value` when given. Returns true if the game was changed.
function QT:Press(key, value, back)
	local def = self.all[key]
	if not def or not (def.kind == "bubble" or def.kind == "float") then
		Print("no toggle called '" .. tostring(key) .. "'. /pins list shows them.")
		return false
	end
	local ok, reason = self:Available(def)
	if not ok then
		Print(def.name .. ": " .. (reason or "not available here."))
		return false
	end
	local cur = def.Get()
	if value == nil then value = back and def.Prev(cur) or def.Next(cur) end
	if value == cur then
		Print(def.name .. ": already " .. def.Describe(cur) .. ".")
		self:SyncAll()
		return false
	end
	local wrote = def.Set(value)
	if wrote == false then -- Set refused (combat, game rejected it); it printed why
		self:SyncAll()
		return false
	end
	if db.sound and PlaySound and SOUNDKIT then
		PlaySound((value == false) and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	end
	if db.announce then
		Print(def.name .. ": " .. def.Describe(value) .. ".")
	end
	self:Update(def)
	self:SyncAll()
	return true
end

function QT:SetEnabled(key, enabled)
	local def = self.all[key]
	if not def then return false end
	self:Settings(key).enabled = enabled and true or false
	local k = self.kinds[def.kind]
	if k.Refresh then k.Refresh(def) end
	if self.OnEnabledChanged then self:OnEnabledChanged(def) end
	return true
end

-- Display name for chat lines: "Music button", "Brightness slider".
function QT:ElementName(key)
	local def = self.all[key]
	if not def then return key end
	return def.name .. " " .. self.kinds[def.kind].noun
end

function QT:SetShown(shown)
	db.shown = shown and true or false
	self:Refresh()
end

function QT:ResetPositions()
	db.sliderPos = false
	for _, kind in ipairs(self.kindOrder) do
		local k = self.kinds[kind]
		if k.Reset then k.Reset() end
	end
end

-------------------------------------------------------------------------------
-- The menu: tick the buttons and sliders you want
-------------------------------------------------------------------------------

-- Sections in display order, skipping empty kinds.
function QT:MenuSections()
	local out = {}
	for _, kind in ipairs(self.kindOrder) do
		local k = self.kinds[kind]
		if #k.list > 0 then out[#out + 1] = { title = k.title, list = k.list } end
	end
	return out
end

local function OpenGameOptions()
	if QT.OpenOptions then QT:OpenOptions() end
end

local fallbackMenu

-- Used when the client has no MenuUtil (and in the headless tests).
local function OpenFallbackMenu(owner)
	local m = fallbackMenu
	if not m then
		m = CreateFrame("Frame", "OptionPinsMenu", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
		fallbackMenu = m
		m:SetFrameStrata("DIALOG")
		m:SetSize(260, 100)
		m:EnableMouse(true)
		if m.SetBackdrop then
			m:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
			m:SetBackdropColor(0, 0, 0, 0.9)
			m:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
		end
		m.title = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		m.title:SetPoint("TOPLEFT", 12, -10)
		m.title:SetText("Option Pins")
		m.close = CreateFrame("Button", nil, m, "UIPanelCloseButton")
		m.close:SetPoint("TOPRIGHT", 2, 2)
		m.close:SetScript("OnClick", function() m:Hide() end)
		m.rows = {}
		m.headers = {}
		local function Check(label, onClick)
			local c = CreateFrame("CheckButton", nil, m, "UICheckButtonTemplate")
			c:SetSize(24, 24)
			c.label = m:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			c.label:SetPoint("LEFT", c, "RIGHT", 2, 0)
			c.label:SetText(label)
			c:SetScript("OnClick", onClick)
			return c
		end
		m.lock = Check("Lock buttons and sliders in place", function(self) db.locked = self:GetChecked() and true or false end)
		m.stack = Check("Stack minimap buttons into one", function(self) QT:SetStacked(self:GetChecked()) end)
		m.proxy = Check("Allow settings that run Blizzard code", function(self)
			if QT.SetAllowProxy then QT:SetAllowProxy(self:GetChecked() and true or false) end
		end)
		m.reset = CreateFrame("Button", nil, m, "UIPanelButtonTemplate")
		m.reset:SetSize(120, 22)
		m.reset:SetText("Reset positions")
		m.reset:SetScript("OnClick", function() QT:ResetPositions() end)
		m.options = CreateFrame("Button", nil, m, "UIPanelButtonTemplate")
		m.options:SetSize(110, 22)
		m.options:SetText("Add more...")
		m.options:SetScript("OnClick", function() m:Hide(); OpenGameOptions() end)
		if UISpecialFrames then tinsert(UISpecialFrames, "OptionPinsMenu") end
	end

	local y, i, h = -30, 0, 0
	for _, section in ipairs(QT:MenuSections()) do
		h = h + 1
		local fs = m.headers[h]
		if not fs then
			fs = m:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			m.headers[h] = fs
		end
		fs:ClearAllPoints()
		fs:SetPoint("TOPLEFT", 14, y - 4)
		fs:SetText(section.title)
		fs:Show()
		y = y - 18
		for _, def in ipairs(section.list) do
			i = i + 1
			local row = m.rows[i]
			if not row then
				row = CreateFrame("CheckButton", nil, m, "UICheckButtonTemplate")
				row:SetSize(24, 24)
				row.label = m:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
				row.label:SetPoint("LEFT", row, "RIGHT", 2, 0)
				row:SetScript("OnClick", function(self)
					QT:SetEnabled(self.def.key, self:GetChecked() and true or false)
				end)
				m.rows[i] = row
			end
			row.def = def
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", 10, y)
			row:SetChecked(QT:IsEnabled(def.key))
			local ok, reason = QT:Available(def)
			row.label:SetText(ok and def.name or (def.name .. " |cff888888(" .. (reason or "not available") .. ")|r"))
			row:Show()
			y = y - 24
		end
	end
	for k = i + 1, #m.rows do m.rows[k]:Hide() end
	for k = h + 1, #m.headers do m.headers[k]:Hide() end

	m.lock:ClearAllPoints()
	m.lock:SetPoint("TOPLEFT", 10, y - 6)
	m.lock:SetChecked(db.locked)
	m.stack:ClearAllPoints()
	m.stack:SetPoint("TOPLEFT", 10, y - 30)
	m.stack:SetChecked(Stack().enabled)
	m.proxy:ClearAllPoints()
	m.proxy:SetPoint("TOPLEFT", 10, y - 54)
	m.proxy:SetChecked(db.allowProxy)
	m.reset:ClearAllPoints()
	m.reset:SetPoint("TOPLEFT", 14, y - 84)
	m.options:ClearAllPoints()
	m.options:SetPoint("LEFT", m.reset, "RIGHT", 6, 0)
	m:SetHeight(-y + 120)

	m:SetWidth(260)
	m:ClearAllPoints()
	if owner and owner ~= UIParent then
		m:SetPoint("TOPRIGHT", owner, "BOTTOMLEFT", 0, 0)
	else
		local x, cy = GetCursorPosition()
		local s = UIParent:GetEffectiveScale()
		m:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s, cy / s)
	end
	m:Show()
end

function QT:OpenMenu(owner)
	if not db then return end
	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(owner or UIParent, function(_, root)
			root:CreateTitle("Option Pins")
			local function AddRow(def)
				local ok, reason = QT:Available(def)
				local box = root:CreateCheckbox(def.name,
					function() return QT:IsEnabled(def.key) end,
					function() QT:SetEnabled(def.key, not QT:IsEnabled(def.key)) end)
				if not ok and box.SetEnabled then
					box:SetEnabled(false)
					if box.SetTooltip then
						box:SetTooltip(function(tooltip) tooltip:AddLine(reason or "Not available.", 1, 0.3, 0.3, true) end)
					end
				end
			end
			for n, section in ipairs(QT:MenuSections()) do
				if n > 1 then root:CreateDivider() end
				root:CreateTitle(section.title)
				for _, def in ipairs(section.list) do AddRow(def) end
			end
			root:CreateDivider()
			root:CreateCheckbox("Lock buttons and sliders in place",
				function() return db.locked end,
				function() db.locked = not db.locked end)
			root:CreateCheckbox("Stack minimap buttons into one",
				function() return Stack().enabled end,
				function() QT:SetStacked(not Stack().enabled) end)
			if QT.SetAllowProxy then
				root:CreateCheckbox("Allow settings that run Blizzard code",
					function() return db.allowProxy end,
					function() QT:SetAllowProxy(not db.allowProxy) end)
			end
			root:CreateButton("Reset positions", function() QT:ResetPositions() end)
			if QT.OpenOptions then
				root:CreateButton("Add more from the Options window...", OpenGameOptions)
			end
		end)
	else
		OpenFallbackMenu(owner)
	end
end

-------------------------------------------------------------------------------
-- Key bindings (Bindings.xml calls this) and slash commands
-------------------------------------------------------------------------------

BINDING_NAME_OPTIONPINS_MENU = "Option Pins: open the menu"

function OptionPins_Press(key)
	if not db then return end
	if key == "menu" then
		QT:OpenMenu(UIParent)
	else
		QT:Press(key)
	end
end

local function BindKey(toggleKey, key)
	local def = QT.byKey[toggleKey]
	key = key and key:upper()
	if not def or not key or key == "" then
		Print("usage: /pins key <toggle> <KEY>   e.g. /pins key music F11")
		return
	end
	local action = "OPTIONPINS_" .. toggleKey:upper()
	if not _G["BINDING_NAME_" .. action] then
		Print(def.name .. " has no key binding entry (needs a line in Bindings.xml).")
		return
	end
	if SetBinding(key, action) then
		SaveBindings(GetCurrentBindingSet())
		Print(key .. " now flips " .. def.name .. ".")
	else
		Print("could not bind " .. key .. ".")
	end
end

local function List()
	for _, kind in ipairs({ "bubble", "float" }) do
		local k = QT.kinds[kind]
		for _, def in ipairs(k.list) do
			local ok, reason = QT:Available(def)
			local s = QT:Settings(def.key)
			Print(string.format("%s  (/pins %s)  %s %s  now: %s%s",
				def.name, def.key, k.noun,
				s.enabled and "on" or "off",
				ok and def.Describe(def.Get()) or "n/a",
				ok and "" or ("  - " .. (reason or "not available"))))
		end
	end
	for _, kind in ipairs({ "slider", "block" }) do
		local k = QT.kinds[kind]
		for _, def in ipairs(k.list) do
			local ok, reason = QT:Available(def)
			local s = QT:Settings(def.key)
			local undo = QT:GetUndo(def)
			Print(string.format("%s  (/pins %s <%s>|undo)  %s %s  now: %s%s%s",
				def.name, def.key, def.rangeText, k.noun,
				s.enabled and "on" or "off",
				ok and def.Format(def.Get()) or "n/a",
				(ok and undo) and ("  undo to " .. def.Format(undo)) or "",
				ok and "" or ("  - " .. (reason or "not available"))))
		end
	end
end

SLASH_OPTIONPINS1 = "/pins"
SLASH_OPTIONPINS2 = "/pin"
SLASH_OPTIONPINS3 = "/optionpins"

-- Keys are matched case-insensitively (generic ones carry the game's camelCase names).
local function FindKey(text)
	if QT.all[text] then return text end
	local lower = text:lower()
	for key in pairs(QT.all) do
		if key:lower() == lower then return key end
	end
end

SlashCmdList["OPTIONPINS"] = function(msg)
	if not db then return end
	msg = (msg or ""):match("^%s*(.-)%s*$")
	local word, rest = msg:match("^(%S+)%s*(.-)$")
	local cmd = (word or ""):lower()
	rest = rest or ""
	local key = word and FindKey(word)
	local def = key and QT.all[key]

	if cmd == "" or cmd == "menu" then
		QT:OpenMenu(UIParent)
	elseif cmd == "options" then
		OpenGameOptions()
	elseif def and (def.kind == "bubble" or def.kind == "float") then
		if rest == "" then
			QT:Press(key)
		elseif rest:lower() == "on" and not def.Parse then
			QT:Press(key, true)
		elseif rest:lower() == "off" and not def.Parse then
			QT:Press(key, false)
		elseif def.Parse then
			local v = def.Parse(rest)
			if v == nil then Print(def.name .. ": don't know '" .. rest .. "'.") else QT:Press(key, v) end
		else
			Print(def.name .. ": don't know '" .. rest .. "'.")
		end
	elseif def and (def.kind == "slider" or def.kind == "block") then
		QT:SliderCommand(key, rest)
	elseif cmd == "enable" or cmd == "disable" then
		local k = FindKey(rest)
		if k and QT:SetEnabled(k, cmd == "enable") then
			Print(QT:ElementName(k) .. " " .. (cmd == "enable" and "on." or "off."))
		else
			Print("no toggle called '" .. rest:lower() .. "'. /pins list shows them.")
		end
	elseif cmd == "list" or cmd == "status" then
		List()
	elseif cmd == "show" then
		QT:SetShown(true)
	elseif cmd == "hide" then
		QT:SetShown(false)
	elseif cmd == "lock" then
		db.locked = true
		Print("buttons and sliders locked.")
	elseif cmd == "unlock" then
		db.locked = false
		Print("buttons and sliders unlocked, drag them to move.")
	elseif cmd == "reset" then
		QT:ResetPositions()
		QT:SetShown(true)
		Print("button and slider positions reset.")
	elseif cmd == "sound" then
		db.sound = (rest:lower() ~= "off")
		Print("sound " .. (db.sound and "on" or "off") .. ".")
	elseif cmd == "announce" then
		db.announce = (rest:lower() ~= "off")
		Print("chat announcement " .. (db.announce and "on" or "off") .. ".")
	elseif cmd == "fan" then
		local g, o = rest:match("^(%d+)%s*(%d*)$")
		g, o = tonumber(g), tonumber(o)
		local st = Stack()
		if g and g >= FAN_MIN and g <= FAN_MAX and (not o or (o >= FAN_MIN and o <= FAN_MAX)) then
			st.gap = g
			if o then st.out = o end
			QT:RefreshBubbles()
		elseif rest:lower() == "reset" then
			st.gap, st.out = nil, nil
			QT:RefreshBubbles()
		elseif rest ~= "" then
			Print(string.format("usage: /pins fan <spacing> [distance], each %d-%d px, or /pins fan reset", FAN_MIN, FAN_MAX))
			return
		end
		Print(string.format("fanned dots: %d px apart, %d px out from the ring (defaults %d and %d).", FanGap(), FanOut(), FAN_GAP, FAN_OUT))
	elseif cmd == "stack" then
		local arg = rest:lower()
		local on
		if arg == "" then on = not Stack().enabled else on = (arg ~= "off") end
		QT:SetStacked(on)
		Print(on and "minimap buttons stacked into one dot. Click it to fan them out." or "minimap buttons unstacked.")
	elseif cmd == "collapse" or cmd == "expand" then
		if QT.SetSlidersCollapsed then QT:SetSlidersCollapsed(cmd == "collapse") end
	elseif cmd == "blizzard" or cmd == "proxy" then
		if QT.SetAllowProxy then QT:SetAllowProxy(rest:lower() ~= "off") end
	elseif cmd == "key" then
		local t, k = rest:match("^(%S+)%s+(%S+)$")
		BindKey(t and t:lower(), k)
	else
		Print("commands: /pins (menu), /pins options, /pins <toggle> [value], /pins <slider> <value>|undo, enable|disable <name>, list, show, hide, stack on|off, fan <spacing> [distance], collapse, expand, lock, unlock, reset, blizzard on|off, sound on|off, announce on|off, key <toggle> <KEY>")
	end
end

-------------------------------------------------------------------------------
-- Events and polling
-------------------------------------------------------------------------------

local ev = CreateFrame("Frame", "OptionPinsEvents", UIParent)
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
QT.eventFrame = ev
QT.eventHandlers = {} -- event -> { function(event, ...) } added by other files

function QT:On(event, fn)
	local list = self.eventHandlers[event]
	if not list then
		list = {}
		self.eventHandlers[event] = list
		ev:RegisterEvent(event)
	end
	list[#list + 1] = fn
end

RegisterDefEvents = function(def)
	for _, e in ipairs(def.events or {}) do ev:RegisterEvent(e) end
end

ev:SetScript("OnEvent", function(self, event, arg1, ...)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON_NAME then return end
		-- Settings saved by Quick Toggle (this add-on's old name) carry over once.
		if OptionPinsDB == nil and type(QuickToggleDB) == "table" then
			OptionPinsDB = QuickToggleDB
		end
		QuickToggleDB = nil
		OptionPinsDB = OptionPinsDB or {}
		db = OptionPinsDB
		for k, v in pairs(DEFAULTS) do
			if db[k] == nil then db[k] = (type(v) == "table") and {} or v end
		end
		Stack()
		-- 1.1/1.2 kept undo points inside db.sliders[key].revert.
		for key, s in pairs(db.sliders) do
			if s.revert ~= nil then
				local def = QT.all[key]
				db.undo[(def and def.undoKey) or key] = s.revert
				s.revert = nil
			end
		end
		for _, kind in ipairs(QT.kindOrder) do
			local k = QT.kinds[kind]
			for _, def in ipairs(k.list) do
				if k.Setup then k.Setup(def) end
				RegisterDefEvents(def)
			end
		end
		if QT.OnLoaded then QT:OnLoaded() end
	elseif not db then
		return
	elseif event == "PLAYER_LOGIN" then
		QT:Refresh()
		for _, kind in ipairs(QT.kindOrder) do
			for _, def in ipairs(QT.kinds[kind].list) do
				local ok, reason = QT:Available(def)
				if not ok and QT:IsEnabled(def.key) then
					Print(QT:ElementName(def.key) .. " hidden: " .. (reason or "not available here") .. ".")
				end
			end
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		QT:RefreshBubbles()
		QT:PlaceAll()
		if QT.PlaceSliderPanel then QT:PlaceSliderPanel() end
		QT:Refresh()
	end
	local handlers = QT.eventHandlers[event]
	if handlers and db then
		for _, fn in ipairs(handlers) do fn(event, arg1, ...) end
	end
	if event ~= "ADDON_LOADED" and db then
		QT:SyncAll()
	end
end)

-- No event fires for some settings (the SD/HD switch has none), so poll all of them.
local elapsed = 0
ev:SetScript("OnUpdate", function(self, dt)
	elapsed = elapsed + dt
	if elapsed < POLL then return end
	elapsed = 0
	if not db then return end
	QT:SyncAll()
end)
