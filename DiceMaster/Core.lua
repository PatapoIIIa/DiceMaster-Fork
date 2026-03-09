-------------------------------------------------------------------------------
-- Dice Master (C) 2023 <The League of Lordaeron> - Moon Guard
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- SS13 combat prototype.
-- Grouped players use an authoritative leader/server, while solo players trust
-- their own client and resolve attacks locally. The UI is a zone matrix made
-- from clickable squares instead of a character model.
-------------------------------------------------------------------------------

local Me = DiceMaster4

if not Me then
	return
end

-------------------------------------------------------------------------------
-- Shared constants and compatibility wrappers.
-------------------------------------------------------------------------------

local PREFIX = "SS13_CORE"
local CHANNEL = "PARTY"
local FRAME_WIDTH = 300
local FRAME_HEIGHT = 500
local BOARD_WIDTH = 240
local BOARD_HEIGHT = 360
local BUTTON_COOLDOWN_DURATION = 1.5
local WINDOW_TITLE = "Bonk-O-Mat 9000"
local BOARD_CAPTION = "Advanced Ouch Selector"
local CHAT_PREFIX = "|cFFFFB347[Bonk-O-Mat 9000]|r "
local IMPACT_SPRITE = "Interface\\AddOns\\DiceMaster\\Texture\\Damage\\slashing"

local RegisterAddonPrefix = C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix or RegisterAddonMessagePrefix
local SendAddon = C_ChatInfo and C_ChatInfo.SendAddonMessage or SendAddonMessage
local BackdropTemplateType = BackdropTemplateMixin and "BackdropTemplate" or nil

local SS13 = Me.SS13Combat or {}
Me.SS13Combat = SS13

-------------------------------------------------------------------------------
-- Target filter.
-- Fill npcIDs and/or npcNames to lock the window to a specific encounter NPC.
-------------------------------------------------------------------------------

local TARGET_FILTER = {
	npcIDs = {
		-- [31146] = true, -- Example: Raider's Training Dummy
	},
	npcNames = {
		-- ["Training Dummy"] = true,
	},
	allowAnyNPCWhenEmpty = true,
}

-------------------------------------------------------------------------------
-- Zone matrix.
-- The coordinates are local board positions. Each zone also exposes a
-- normalized center so the hit animation can still play at a consistent point.
-------------------------------------------------------------------------------

SS13.ZoneLayout = {
	{ key = "crown",      label = "Crown",      short = "Top",     x = 90,  y = 330, width = 60, height = 24, hitChance = 34 },
	{ key = "left_ear",   label = "Left Ear",   short = "L\nEar",  x = 10,  y = 286, width = 30, height = 32, hitChance = 55 },
	{ key = "left_eye",   label = "Left Eye",   short = "L\nEye",  x = 44,  y = 286, width = 34, height = 32, hitChance = 42 },
	{ key = "head",       label = "Head",       short = "Head",    x = 84,  y = 278, width = 72, height = 40, hitChance = 58 },
	{ key = "right_eye",  label = "Right Eye",  short = "R\nEye",  x = 162, y = 286, width = 34, height = 32, hitChance = 42 },
	{ key = "right_ear",  label = "Right Ear",  short = "R\nEar",  x = 200, y = 286, width = 30, height = 32, hitChance = 55 },
	{ key = "mouth",      label = "Mouth",      short = "Mouth",   x = 84,  y = 238, width = 72, height = 30, hitChance = 48 },
	{ key = "neck",       label = "Neck",       short = "Neck",    x = 90,  y = 204, width = 60, height = 26, hitChance = 46 },
	{ key = "left_arm",   label = "Left Arm",   short = "L\nArm",  x = 6,   y = 138, width = 46, height = 102, hitChance = 72 },
	{ key = "body",       label = "Body",       short = "Body",    x = 76,  y = 138, width = 88, height = 68, hitChance = 88 },
	{ key = "right_arm",  label = "Right Arm",  short = "R\nArm",  x = 188, y = 138, width = 46, height = 102, hitChance = 72 },
	{ key = "left_hand",  label = "Left Hand",  short = "L\nHand", x = 8,   y = 94,  width = 42, height = 36, hitChance = 60 },
	{ key = "belly",      label = "Belly",      short = "Belly",   x = 82,  y = 92,  width = 76, height = 38, hitChance = 78 },
	{ key = "right_hand", label = "Right Hand", short = "R\nHand", x = 190, y = 94,  width = 42, height = 36, hitChance = 60 },
	{ key = "groin",      label = "Groin",      short = "Groin",   x = 88,  y = 58,  width = 64, height = 28, hitChance = 64 },
	{ key = "left_leg",   label = "Left Leg",   short = "L\nLeg",  x = 84,  y = 12,  width = 34, height = 42, hitChance = 70 },
	{ key = "right_leg",  label = "Right Leg",  short = "R\nLeg",  x = 122, y = 12,  width = 34, height = 42, hitChance = 70 },
	{ key = "left_foot",  label = "Left Foot",  short = "L\nFoot", x = 70,  y = 0,   width = 44, height = 16, hitChance = 56 },
	{ key = "right_foot", label = "Right Foot", short = "R\nFoot", x = 126, y = 0,   width = 44, height = 16, hitChance = 56 },
}

SS13.ZonesByKey = SS13.ZonesByKey or {}

for _, zone in ipairs(SS13.ZoneLayout) do
	zone.centerX = ((zone.x + (zone.width / 2)) / BOARD_WIDTH) * 100
	zone.centerY = ((zone.y + (zone.height / 2)) / BOARD_HEIGHT) * 100
	SS13.ZonesByKey[zone.key] = zone
end

-------------------------------------------------------------------------------
-- Utility helpers.
-------------------------------------------------------------------------------

local function Clamp(value, minValue, maxValue)
	if value < minValue then
		return minValue
	end

	if value > maxValue then
		return maxValue
	end

	return value
end

local function IsTableEmpty(tbl)
	return next(tbl) == nil
end

local function ShortName(name)
	if not name then
		return nil
	end

	if Ambiguate then
		return Ambiguate(name, "short")
	end

	return name:match("([^%-]+)")
end

local function GetNPCIDFromGUID(guid)
	if not guid then
		return nil
	end

	local unitType, _, _, _, _, npcID = strsplit("-", guid)

	if unitType == "Creature" or unitType == "Vehicle" or unitType == "Pet" then
		return tonumber(npcID)
	end

	return nil
end

local function PackMessage(...)
	local fields = {}

	for index = 1, select("#", ...) do
		fields[index] = tostring(select(index, ...))
	end

	return table.concat(fields, "|")
end

local function UnpackMessage(message)
	local fields = {}

	for token in string.gmatch(message or "", "([^|]+)") do
		fields[#fields + 1] = token
	end

	return fields
end

local function BuildCombatLogMessage(targetName, zoneLabel, result)
	if result == "HIT" then
		return string.format("You bonk %s in the %s.", targetName, zoneLabel)
	end

	return string.format("You whiff at %s's %s.", targetName, zoneLabel)
end

-------------------------------------------------------------------------------
-- Group and authority helpers.
-------------------------------------------------------------------------------

function SS13:GetPlayerName()
	self.playerName = self.playerName or ShortName(UnitName("player"))
	return self.playerName
end

function SS13:CanUsePartyTransport()
	return IsInGroup()
end

function SS13:IsAuthorityPlayer()
	return not self:CanUsePartyTransport() or UnitIsGroupLeader("player")
end

function SS13:GetAuthorityName()
	if not self:CanUsePartyTransport() or self:IsAuthorityPlayer() then
		return self:GetPlayerName()
	end

	if IsInRaid() then
		for index = 1, GetNumGroupMembers() do
			local unit = "raid" .. index
			if UnitExists(unit) and UnitIsGroupLeader(unit) then
				return ShortName(GetUnitName(unit, true))
			end
		end
	else
		for index = 1, GetNumSubgroupMembers() do
			local unit = "party" .. index
			if UnitExists(unit) and UnitIsGroupLeader(unit) then
				return ShortName(GetUnitName(unit, true))
			end
		end
	end

	return nil
end

function SS13:IsGroupMemberName(name)
	local searchName = ShortName(name)

	if not searchName then
		return false
	end

	if not self:CanUsePartyTransport() then
		return searchName == self:GetPlayerName()
	end

	if searchName == self:GetPlayerName() then
		return true
	end

	if IsInRaid() then
		for index = 1, GetNumGroupMembers() do
			local unit = "raid" .. index
			if UnitExists(unit) and ShortName(GetUnitName(unit, true)) == searchName then
				return true
			end
		end
	else
		for index = 1, GetNumSubgroupMembers() do
			local unit = "party" .. index
			if UnitExists(unit) and ShortName(GetUnitName(unit, true)) == searchName then
				return true
			end
		end
	end

	return false
end

function SS13:IsSenderAuthority(sender)
	return ShortName(sender) == self:GetAuthorityName()
end

-------------------------------------------------------------------------------
-- Target selection helper.
-------------------------------------------------------------------------------

function SS13:IsConfiguredTarget(unit)
	if not UnitExists(unit) or UnitIsPlayer(unit) then
		return false
	end

	local targetGUID = UnitGUID(unit)
	local npcID = GetNPCIDFromGUID(targetGUID)
	local targetName = ShortName(GetUnitName(unit, true) or UnitName(unit))
	local hasNPCIDs = not IsTableEmpty(TARGET_FILTER.npcIDs)
	local hasNPCNames = not IsTableEmpty(TARGET_FILTER.npcNames)

	if not hasNPCIDs and not hasNPCNames then
		return TARGET_FILTER.allowAnyNPCWhenEmpty
	end

	if npcID and TARGET_FILTER.npcIDs[npcID] then
		return true
	end

	if targetName and TARGET_FILTER.npcNames[targetName] then
		return true
	end

	return false
end

-------------------------------------------------------------------------------
-- Visual state helpers for zone buttons.
-------------------------------------------------------------------------------

function SS13:UpdateZoneButtonVisual(button)
	if not button or not button.SetBackdropColor then
		return
	end

	local isOnCooldown = self:IsOnCooldown()
	local isSelected = self.selectedZoneKey == button.zoneData.key
	local isHovered = button.isHovered

	if isOnCooldown then
		button:SetBackdropColor(0.16, 0.16, 0.16, 0.94)
		button:SetBackdropBorderColor(0.40, 0.40, 0.40, 0.92)
		button.Label:SetTextColor(0.72, 0.72, 0.72)
	elseif isSelected then
		button:SetBackdropColor(0.62, 0.20, 0.22, 0.96)
		button:SetBackdropBorderColor(1.0, 0.86, 0.64, 1.0)
		button.Label:SetTextColor(1.0, 0.97, 0.94)
	elseif isHovered then
		button:SetBackdropColor(0.54, 0.18, 0.20, 0.95)
		button:SetBackdropBorderColor(1.0, 0.80, 0.70, 0.96)
		button.Label:SetTextColor(1.0, 0.95, 0.92)
	else
		button:SetBackdropColor(0.46, 0.15, 0.17, 0.94)
		button:SetBackdropBorderColor(0.95, 0.64, 0.58, 0.92)
		button.Label:SetTextColor(0.98, 0.90, 0.88)
	end
end

function SS13:IsWindowEnabled()
	return not Me.db or Me.db.global.enableBonkWindow ~= false
end

function SS13:IsOnCooldown()
	return self.cooldownEndTime and self.cooldownEndTime > GetTime()
end

function SS13:GetCooldownProgress()
	if not self:IsOnCooldown() then
		return 1
	end

	local remaining = math.max(0, self.cooldownEndTime - GetTime())
	return Clamp(1 - (remaining / BUTTON_COOLDOWN_DURATION), 0, 1)
end

function SS13:UpdateCooldownVisuals()
	if not self.zoneButtons then
		return
	end

	local isOnCooldown = self:IsOnCooldown()
	local progress = self:GetCooldownProgress()

	for _, button in pairs(self.zoneButtons) do
		if button.CooldownFill then
			if isOnCooldown then
				button.CooldownFill:SetHeight(math.max(0, (button:GetHeight() - 6) * progress))
				button.CooldownFill:Show()
			else
				button.CooldownFill:SetHeight(button:GetHeight() - 6)
				button.CooldownFill:Hide()
			end
		end

		self:UpdateZoneButtonVisual(button)
	end
end

function SS13:OnCooldownUpdate()
	if not self:IsOnCooldown() then
		self.cooldownEndTime = nil
		self:UpdateCooldownVisuals()
		if self.cooldownTicker then
			self.cooldownTicker:SetScript("OnUpdate", nil)
		end
		return
	end

	self:UpdateCooldownVisuals()
end

function SS13:StartCooldown()
	self.cooldownEndTime = GetTime() + BUTTON_COOLDOWN_DURATION
	self:UpdateCooldownVisuals()

	if self.cooldownTicker then
		self.cooldownTicker:SetScript("OnUpdate", function()
			self:OnCooldownUpdate()
		end)
	end
end

function SS13:RefreshZoneButtonVisuals()
	if not self.zoneButtons then
		return
	end

	for _, button in pairs(self.zoneButtons) do
		self:UpdateZoneButtonVisual(button)
	end
end

function SS13:SetSelectedZone(zoneKey)
	self.selectedZoneKey = zoneKey
	self:RefreshZoneButtonVisuals()
end

function SS13:LogToAddonChat(message)
	if Me and Me.PrintMessage then
		Me.PrintMessage(CHAT_PREFIX .. message, "SYSTEM")
	end
end

-------------------------------------------------------------------------------
-- Client block: build the tactical zone board.
-------------------------------------------------------------------------------

function SS13:CreateZoneButtons(parent)
	self.zoneButtons = self.zoneButtons or {}

	for _, zone in ipairs(self.ZoneLayout) do
		local button = CreateFrame("Button", nil, parent, BackdropTemplateType)
		button:SetSize(zone.width, zone.height)
		button:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", zone.x, zone.y)
		button:RegisterForClicks("LeftButtonUp")
		button.zoneData = zone

		if button.SetBackdrop then
			button:SetBackdrop({
				bgFile = "Interface\\Buttons\\WHITE8x8",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
				edgeSize = 10,
				insets = { left = 2, right = 2, top = 2, bottom = 2 },
			})
		end

		local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		label:SetPoint("TOPLEFT", 3, -3)
		label:SetPoint("BOTTOMRIGHT", -3, 3)
		label:SetJustifyH("CENTER")
		label:SetJustifyV("MIDDLE")
		label:SetText(zone.short)
		button.Label = label

		local cooldownFill = button:CreateTexture(nil, "ARTWORK")
		cooldownFill:SetTexture("Interface\\Buttons\\WHITE8x8")
		cooldownFill:SetVertexColor(0.92, 0.52, 0.46, 0.40)
		cooldownFill:SetPoint("BOTTOMLEFT", 3, 3)
		cooldownFill:SetPoint("BOTTOMRIGHT", -3, 3)
		cooldownFill:SetHeight(button:GetHeight() - 6)
		cooldownFill:Hide()
		button.CooldownFill = cooldownFill

		button:SetScript("OnEnter", function(zoneButton)
			zoneButton.isHovered = true
			SS13:UpdateZoneButtonVisual(zoneButton)

			GameTooltip:SetOwner(zoneButton, "ANCHOR_RIGHT")
			GameTooltip:SetText(zone.label)
			GameTooltip:AddLine("Click to attack this zone.", 0.8, 0.8, 0.8, true)
			GameTooltip:Show()
		end)

		button:SetScript("OnLeave", function(zoneButton)
			zoneButton.isHovered = nil
			SS13:UpdateZoneButtonVisual(zoneButton)
			GameTooltip:Hide()
		end)

		button:SetScript("OnClick", function(zoneButton)
			SS13:OnZoneButtonClick(zoneButton.zoneData)
		end)

		self.zoneButtons[zone.key] = button
		self:UpdateZoneButtonVisual(button)
	end
end

function SS13:CreateCombatFrame()
	if self.frame then
		return
	end

	local frame = CreateFrame("Frame", "SS13_CombatFrame", UIParent, BackdropTemplateType)
	frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
	frame:SetPoint("CENTER", UIParent, "CENTER", 420, 0)
	frame:SetFrameStrata("HIGH")
	frame:SetClampedToScreen(true)
	frame:Hide()

	if frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 14,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		frame:SetBackdropColor(0.03, 0.03, 0.05, 0.96)
		frame:SetBackdropBorderColor(0.70, 0.70, 0.75, 1)
	end

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	title:SetPoint("TOP", 0, -14)
	title:SetText(WINDOW_TITLE)
	frame.Title = title

	local roleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	roleText:SetPoint("TOP", title, "BOTTOM", 0, -8)
	roleText:SetText("Mode: Client")
	frame.RoleText = roleText

	local targetText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	targetText:SetPoint("TOP", roleText, "BOTTOM", 0, -10)
	targetText:SetText("Target: none")
	frame.TargetText = targetText

	local board = CreateFrame("Frame", nil, frame, BackdropTemplateType)
	board:SetSize(BOARD_WIDTH, BOARD_HEIGHT)
	board:SetPoint("TOP", targetText, "BOTTOM", 0, -12)

	if board.SetBackdrop then
		board:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8x8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12,
			insets = { left = 2, right = 2, top = 2, bottom = 2 },
		})
		board:SetBackdropColor(0.05, 0.05, 0.06, 0.94)
		board:SetBackdropBorderColor(0.35, 0.35, 0.40, 0.9)
	end

	local boardCaption = board:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	boardCaption:SetPoint("TOP", 0, -8)
	boardCaption:SetText(BOARD_CAPTION)
	board.Caption = boardCaption
	frame.Board = board

	local hintText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hintText:SetPoint("TOP", board, "BOTTOM", 0, -10)
	hintText:SetWidth(FRAME_WIDTH - 36)
	hintText:SetJustifyH("CENTER")
	hintText:SetText("Click a zone square to attack.")
	frame.HintText = hintText

	local resultText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	resultText:SetPoint("TOP", hintText, "BOTTOM", 0, -10)
	resultText:SetWidth(FRAME_WIDTH - 36)
	resultText:SetJustifyH("CENTER")
	resultText:SetText("Awaiting target.")
	frame.ResultText = resultText

	self.frame = frame
	self:CreateZoneButtons(board)
end

function SS13:SetResultText(text, colorCode)
	if not self.frame or not self.frame.ResultText then
		return
	end

	if colorCode then
		self.frame.ResultText:SetText(colorCode .. text .. "|r")
	else
		self.frame.ResultText:SetText(text)
	end
end

function SS13:UpdateRoleText()
	if not self.frame then
		return
	end

	if not self:CanUsePartyTransport() then
		self.frame.RoleText:SetText("|cff8dd6ffMode: Self-Authoritative|r")
		self.frame.HintText:SetText("Click a zone square to resolve the attack locally.")
	elseif self:IsAuthorityPlayer() then
		self.frame.RoleText:SetText("|cff7dff7dMode: GM Server|r")
		self.frame.HintText:SetText("Click a zone square to send REQ_ATTACK and resolve it as the leader.")
	else
		self.frame.RoleText:SetText("|cffffd166Mode: Client|r")
		self.frame.HintText:SetText("Click a zone square to send REQ_ATTACK to the leader.")
	end
end

function SS13:RefreshTargetFrame()
	if not self.frame then
		return
	end

	if not self:IsWindowEnabled() then
		self.frame:Hide()
		return
	end

	local previousTargetGUID = self.currentTargetGUID

	if self:IsConfiguredTarget("target") then
		self.currentTargetGUID = UnitGUID("target")
		self.currentTargetName = ShortName(GetUnitName("target", true) or UnitName("target")) or "Unknown"

		if previousTargetGUID ~= self.currentTargetGUID then
			self:SetSelectedZone(nil)
		end

		self.frame.TargetText:SetText("Target: " .. self.currentTargetName)
		self.frame:Show()
	else
		self.currentTargetGUID = nil
		self.currentTargetName = nil
		self:SetSelectedZone(nil)
		self.frame.TargetText:SetText("Target: none")
		self:SetResultText("Awaiting configured NPC target.")
		self.frame:Hide()
	end
end

function SS13:OnZoneButtonClick(zone)
	if not zone or not self.currentTargetGUID or self:IsOnCooldown() then
		return
	end

	self:SetSelectedZone(zone.key)
	if self:SendAttackRequest(self.currentTargetGUID, zone.key) then
		self:StartCooldown()
	end
end

-------------------------------------------------------------------------------
-- Protocol block.
-- Requests are now zone-based rather than raw click coordinates.
-------------------------------------------------------------------------------

function SS13:SendAttackRequest(targetGUID, zoneKey)
	local zone = self.ZonesByKey[zoneKey]

	if not zone then
		return false
	end

	if not self:CanUsePartyTransport() then
		self:SetResultText("Resolving " .. zone.label .. " locally.", "|cffc8c8ff")
		self:HandleAttackRequest({ "REQ_ATTACK", targetGUID, zoneKey }, self:GetPlayerName())
		return true
	end

	if not SendAddon then
		self:SetResultText("Addon transport is unavailable.", "|cffff6060")
		return false
	end

	local payload = PackMessage("REQ_ATTACK", targetGUID, zoneKey)
	SendAddon(PREFIX, payload, CHANNEL)
	self:SetResultText("REQ_ATTACK: " .. zone.label, "|cffc8c8ff")

	-- Party leaders may not receive their own PARTY addon messages.
	if self:IsAuthorityPlayer() then
		self:HandleAttackRequest(UnpackMessage(payload), self:GetPlayerName())
	end

	return true
end

-------------------------------------------------------------------------------
-- GM / server block.
-------------------------------------------------------------------------------

function SS13:ResolveAttackResult(zone)
	if not zone then
		return "MISS", "Miss"
	end

	if math.random(1, 100) <= (zone.hitChance or 100) then
		return "HIT", zone.label
	end

	return "MISS", zone.label
end

function SS13:HandleAttackRequest(fields, sender)
	if not self:IsAuthorityPlayer() then
		return
	end

	if self:CanUsePartyTransport() and not self:IsGroupMemberName(sender) then
		return
	end

	local targetGUID = fields[2]
	local zoneKey = fields[3]
	local zone = self.ZonesByKey[zoneKey]

	if not targetGUID or not zone then
		return
	end

	if not UnitExists("target") or not self:IsConfiguredTarget("target") then
		return
	end

	if UnitGUID("target") ~= targetGUID then
		return
	end

	local result, zoneLabel = self:ResolveAttackResult(zone)

	if self:CanUsePartyTransport() then
		local payload = PackMessage("EXEC_HIT", targetGUID, zoneKey, zoneLabel, sender, result)
		SendAddon(PREFIX, payload, CHANNEL)
		self:HandleExecutionBroadcast(UnpackMessage(payload), self:GetPlayerName())
	else
		self:HandleExecutionBroadcast({ "EXEC_HIT", targetGUID, zoneKey, zoneLabel, sender, result }, self:GetPlayerName())
	end
end

-------------------------------------------------------------------------------
-- Visual effect block.
-------------------------------------------------------------------------------

function SS13:SetSpriteFrame(texture, frameIndex)
	local columns = 4
	local rows = 4
	local column = frameIndex % columns
	local row = math.floor(frameIndex / columns)
	local left = column / columns
	local right = (column + 1) / columns
	local top = row / rows
	local bottom = (row + 1) / rows

	texture:SetTexCoord(left, right, top, bottom)
end

function SS13:AcquireImpactFrame()
	self.impactPool = self.impactPool or {}

	for _, impactFrame in ipairs(self.impactPool) do
		if not impactFrame.inUse then
			return impactFrame
		end
	end

	local impactFrame = CreateFrame("Frame", nil, self.frame.Board)
	impactFrame:SetSize(72, 72)
	impactFrame:Hide()

	local texture = impactFrame:CreateTexture(nil, "OVERLAY")
	texture:SetAllPoints()
	texture:SetTexture(IMPACT_SPRITE)
	texture:SetBlendMode("ADD")
	impactFrame.Texture = texture

	local animationGroup = impactFrame:CreateAnimationGroup()
	local driver = animationGroup:CreateAnimation("Alpha")
	driver:SetFromAlpha(1)
	driver:SetToAlpha(1)
	driver:SetDuration(0.40)
	impactFrame.AnimationDuration = 0.40
	impactFrame.AnimationGroup = animationGroup

	animationGroup:SetScript("OnPlay", function()
		impactFrame.inUse = true
		impactFrame.elapsed = 0
		impactFrame.frameIndex = -1
		impactFrame:SetAlpha(1)
		SS13:SetSpriteFrame(impactFrame.Texture, 0)
		impactFrame:Show()
	end)

	animationGroup:SetScript("OnUpdate", function(_, elapsed)
		impactFrame.elapsed = impactFrame.elapsed + elapsed
		local progress = Clamp(impactFrame.elapsed / impactFrame.AnimationDuration, 0, 0.9999)
		local frameIndex = math.min(15, math.floor(progress * 16))

		if frameIndex ~= impactFrame.frameIndex then
			impactFrame.frameIndex = frameIndex
			SS13:SetSpriteFrame(impactFrame.Texture, frameIndex)
		end
	end)

	animationGroup:SetScript("OnFinished", function()
		impactFrame.inUse = false
		impactFrame:Hide()
	end)

	self.impactPool[#self.impactPool + 1] = impactFrame
	return impactFrame
end

function SS13:PlayFencingAnimation(x, y)
	if not self.frame or not self.frame:IsShown() or not self.frame.Board then
		return
	end

	local impactFrame = self:AcquireImpactFrame()
	impactFrame:ClearAllPoints()
	impactFrame:SetParent(self.frame.Board)
	impactFrame:SetPoint(
		"CENTER",
		self.frame.Board,
		"BOTTOMLEFT",
		self.frame.Board:GetWidth() * (Clamp(x, 0, 100) / 100),
		self.frame.Board:GetHeight() * (Clamp(y, 0, 100) / 100)
	)
	impactFrame.AnimationGroup:Stop()
	impactFrame.inUse = true
	impactFrame.AnimationGroup:Play()
end

-------------------------------------------------------------------------------
-- Broadcast receive block.
-------------------------------------------------------------------------------

function SS13:HandleExecutionBroadcast(fields, sender)
	if self:CanUsePartyTransport() and not self:IsSenderAuthority(sender) and sender ~= self:GetPlayerName() then
		return
	end

	local targetGUID = fields[2]
	local zoneKey = fields[3]
	local zoneLabel = fields[4] or "Unknown Zone"
	local attacker = fields[5] or sender
	local result = fields[6] or "MISS"
	local zone = self.ZonesByKey[zoneKey]

	if not targetGUID or not zone then
		return
	end

	if self.currentTargetGUID == targetGUID then
		self:SetSelectedZone(zoneKey)
		self:PlayFencingAnimation(zone.centerX, zone.centerY)
	end

	local targetLabel = self.currentTargetGUID == targetGUID and self.currentTargetName or "target"

	if attacker == self:GetPlayerName() then
		self:LogToAddonChat(BuildCombatLogMessage(targetLabel, zoneLabel, result))
	end

	if result == "HIT" then
		self:SetResultText(string.format("%s hit %s: %s", attacker, targetLabel, zoneLabel), "|cff7dff7d")
	else
		self:SetResultText(string.format("%s missed %s at %s", attacker, targetLabel, zoneLabel), "|cffff6060")
	end
end

function SS13:ApplyConfig()
	self:UpdateRoleText()
	self:RefreshTargetFrame()
	self:UpdateCooldownVisuals()
end

-------------------------------------------------------------------------------
-- Event block.
-------------------------------------------------------------------------------

function SS13:CHAT_MSG_ADDON(prefix, message, channel, sender)
	if prefix ~= PREFIX or channel ~= CHANNEL then
		return
	end

	local senderName = ShortName(sender)
	local fields = UnpackMessage(message)
	local messageType = fields[1]

	if not senderName or not messageType then
		return
	end

	if messageType == "REQ_ATTACK" then
		if senderName == self:GetPlayerName() then
			return
		end

		self:HandleAttackRequest(fields, senderName)
	elseif messageType == "EXEC_HIT" then
		if senderName == self:GetPlayerName() then
			return
		end

		self:HandleExecutionBroadcast(fields, senderName)
	end
end

function SS13:PLAYER_TARGET_CHANGED()
	self:RefreshTargetFrame()
end

function SS13:PLAYER_ENTERING_WORLD()
	self:RefreshTargetFrame()
	self:UpdateRoleText()
	self:RefreshZoneButtonVisuals()
end

function SS13:GROUP_ROSTER_UPDATE()
	self:UpdateRoleText()
end

function SS13:Initialize()
	if self.initialized then
		return
	end

	self.initialized = true
	self:CreateCombatFrame()

	if RegisterAddonPrefix then
		RegisterAddonPrefix(PREFIX)
	end

	self.eventFrame = CreateFrame("Frame")
	self.eventFrame:SetScript("OnEvent", function(_, event, ...)
		if self[event] then
			self[event](self, ...)
		end
	end)
	self.eventFrame:RegisterEvent("CHAT_MSG_ADDON")
	self.eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	self.eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	self.eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
	self.cooldownTicker = CreateFrame("Frame")

	self:UpdateRoleText()
	self:RefreshTargetFrame()
	self:UpdateCooldownVisuals()
end

SS13:Initialize()
