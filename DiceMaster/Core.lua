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
local ACTION_PANEL_WIDTH = 220
local ACTION_PANEL_GAP = 14
local ACTION_PANEL_TITLE = "Action Rack"
local ACTION_PANEL_HINT = "Temporary profile picker."
local INTENT_PANEL_WIDTH = 220
local INTENT_PANEL_GAP = 12
local INTENT_PANEL_TITLE = "Intent Tray"
local WEAPON_INTENT_PANEL_WIDTH = 190
local WEAPON_INTENT_PANEL_GAP = 12
local WEAPON_INTENT_PANEL_TITLE = "Weapon Intent"
local COMBAT_STATE_PANEL_HEIGHT = 108
local COMBAT_STATE_PANEL_GAP = 10
local COMBAT_STATE_PANEL_TITLE = "Combat Stance"
local DEFAULT_DEFENSE_METHOD = "parry"
local TARGET_STATUS_DEFAULT = "Target defense: normal."
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

local function BuildCombatLogMessage(targetName, zoneLabel, intentLabel, weaponIntentLabel, result)
	local attackLabel = intentLabel

	if weaponIntentLabel and weaponIntentLabel ~= "" then
		if attackLabel and attackLabel ~= "" then
			attackLabel = string.format("%s (%s)", attackLabel, weaponIntentLabel)
		else
			attackLabel = weaponIntentLabel
		end
	end

	intentLabel = attackLabel

	if intentLabel and intentLabel ~= "" then
		if result == "HIT" then
			return string.format("You land %s on %s's %s.", intentLabel, targetName, zoneLabel)
		end

		return string.format("You miss %s at %s's %s.", intentLabel, targetName, zoneLabel)
	end

	if result == "HIT" then
		return string.format("You bonk %s in the %s.", targetName, zoneLabel)
	end

	return string.format("You whiff at %s's %s.", targetName, zoneLabel)
end

local function ToTitleCase(text)
	if not text or text == "" then
		return ""
	end

	return (text:gsub("(%a)([%w']*)", function(first, rest)
		return string.upper(first) .. string.lower(rest)
	end))
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
	local duration = self.cooldownDuration or BUTTON_COOLDOWN_DURATION
	return Clamp(1 - (remaining / duration), 0, 1)
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
		self.cooldownDuration = nil
		self:UpdateCooldownVisuals()
		if self.cooldownTicker then
			self.cooldownTicker:SetScript("OnUpdate", nil)
		end
		return
	end

	self:UpdateCooldownVisuals()
end

function SS13:StartCooldown()
	self.cooldownDuration = self:GetCurrentAttackCooldownDuration()
	self.cooldownEndTime = GetTime() + self.cooldownDuration
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

function SS13:GetCombatData()
	return Me and Me.CombatData
end

function SS13:GetCombatProfile(profileID)
	local combatData = self:GetCombatData()
	return combatData and combatData:GetWeaponProfile(profileID) or nil
end

function SS13:GetCombatIntent(intentID)
	local combatData = self:GetCombatData()
	return combatData and combatData:GetIntent(intentID) or nil
end

function SS13:GetWeaponIntentMode(modeID)
	local combatData = self:GetCombatData()
	return combatData and combatData:GetWeaponIntentMode(modeID) or nil
end

function SS13:ProfileSupportsGrip(profile)
	return profile and profile.grippedIntents and #profile.grippedIntents > 0
end

function SS13:ProfileHasAlternateIntents(profile)
	return profile and profile.alternateIntents and #profile.alternateIntents > 0
end

function SS13:IsAlternateIntentSetActive(profile)
	return self.selectedWeaponIntentModeID == "strong" and self:ProfileHasAlternateIntents(profile)
end

function SS13:IsGripActiveForProfile(profile)
	return self.gripActive == true and self:ProfileSupportsGrip(profile)
end

function SS13:GetPrimaryIntentBucket(profile)
	if not profile then
		return nil
	end

	if self:IsGripActiveForProfile(profile) then
		return { label = "Grip", intentIDs = profile.grippedIntents }
	end

	return { label = "Base", intentIDs = profile.defaultIntents }
end

function SS13:GetActiveIntentBuckets(profile)
	if not profile then
		return {}
	end

	local buckets = {}
	local primaryBucket = self:GetPrimaryIntentBucket(profile)

	if primaryBucket and primaryBucket.intentIDs and #primaryBucket.intentIDs > 0 then
		buckets[#buckets + 1] = primaryBucket
	end

	if self:IsAlternateIntentSetActive(profile) then
		buckets[#buckets + 1] = { label = "Alt", intentIDs = profile.alternateIntents }
	end

	return buckets
end

function SS13:GetFirstIntentForProfile(profile)
	for _, bucket in ipairs(self:GetActiveIntentBuckets(profile)) do
		if bucket.intentIDs and #bucket.intentIDs > 0 then
			return bucket.intentIDs[1]
		end
	end

	return nil
end

function SS13:ProfileHasIntent(profile, intentID)
	if not profile or not intentID then
		return false
	end

	for _, bucket in ipairs(self:GetActiveIntentBuckets(profile)) do
		for _, candidateIntentID in ipairs(bucket.intentIDs or {}) do
			if candidateIntentID == intentID then
				return true
			end
		end
	end

	return false
end

function SS13:GetSelectedIntentLabel()
	local intent = self:GetCombatIntent(self.selectedIntentID)
	return intent and ToTitleCase(intent.name) or nil
end

function SS13:GetSelectedWeaponIntentLabel()
	local mode = self:GetWeaponIntentMode(self.selectedWeaponIntentModeID)
	return mode and mode.label or nil
end

function SS13:GetAttackSelection()
	return {
		profileID = self.selectedProfileID,
		intentID = self.selectedIntentID,
		weaponIntentModeID = self.selectedWeaponIntentModeID,
	}
end

function SS13:BuildActionIntentContext(intentID, weaponIntentModeID)
	local intent = self:GetCombatIntent(intentID)
	local weaponIntentMode = self:GetWeaponIntentMode(weaponIntentModeID)

	if not intent or not weaponIntentMode then
		return nil
	end

	return {
		intentID = intentID,
		intent = intent,
		intentLabel = ToTitleCase(intent.name),
		weaponIntentModeID = weaponIntentModeID,
		weaponIntentMode = weaponIntentMode,
		weaponIntentLabel = weaponIntentMode.label,
		accuracyModifier = (intent.accuracyModifier or 0) + (weaponIntentMode.accuracyModifier or 0),
		cooldownMultiplier = weaponIntentMode.cooldownMultiplier or 1,
		cooldownModifier = weaponIntentMode.cooldownModifier or 0,
		damageMultiplier = weaponIntentMode.damageMultiplier or 1,
		strengthBonus = weaponIntentMode.strengthBonus or 0,
		staminaMultiplier = weaponIntentMode.staminaMultiplier or 1,
		dodgeBonus = weaponIntentMode.dodgeBonus or 0,
		parryCooldownMultiplier = weaponIntentMode.parryCooldownMultiplier or 1,
		futureAccuracyBonus = weaponIntentMode.futureAccuracyBonus or 0,
		rightClickAction = weaponIntentMode.rightClickAction,
	}
end

function SS13:GetSelectedActionIntentContext()
	local selection = self:GetAttackSelection()
	return self:BuildActionIntentContext(selection.intentID, selection.weaponIntentModeID)
end

function SS13:GetCurrentAttackCooldownDuration()
	local actionContext = self:GetSelectedActionIntentContext()
	local duration = BUTTON_COOLDOWN_DURATION

	if actionContext then
		duration = duration + (actionContext.cooldownModifier or 0)
		duration = duration * (actionContext.cooldownMultiplier or 1)
	end

	return math.max(0.1, duration)
end

function SS13:GetDefenseSelection()
	return {
		combatModeEnabled = self.combatModeEnabled == true,
		defenseMethod = self.selectedDefenseMethod or DEFAULT_DEFENSE_METHOD,
	}
end

function SS13:GetWeaponIntentSpecialAction(modeID)
	local mode = self:GetWeaponIntentMode(modeID)
	return mode and mode.rightClickAction or nil
end

function SS13:GetWeaponIntentRightClickAction(modeID)
	return self:GetWeaponIntentSpecialAction(modeID)
end

function SS13:HasWeaponIntentSpecialAction(modeID)
	return self:GetWeaponIntentSpecialAction(modeID) ~= nil
end

function SS13:SetFintQualificationResolver(resolver)
	self.fintQualificationResolver = resolver
end

function SS13:GetProfileBuffSkillValue(skillName)
	local profile = Me and Me.Profile

	if not profile or not profile.buffsActive or not skillName then
		return 0
	end

	local value = 0
	local normalizedName = string.lower(skillName)

	for index = 1, #profile.buffsActive do
		local buff = profile.buffsActive[index]

		if buff and buff.skill and string.lower(buff.skill) == normalizedName then
			value = value + ((tonumber(buff.skillRank) or 0) * (tonumber(buff.count) or 1))
		end
	end

	return value
end

function SS13:GetProfileSkillRank(skillName)
	local profile = Me and Me.Profile

	if not profile or not profile.skills or not skillName then
		return nil
	end

	local normalizedName = string.lower(skillName)

	for index = 1, #profile.skills do
		local skill = profile.skills[index]

		if skill and skill.name and string.lower(skill.name) == normalizedName then
			return (tonumber(skill.rank) or 0) + self:GetProfileBuffSkillValue(skill.name)
		end
	end

	return nil
end

function SS13:CanApplyFint(attackerName, mode)
	if not mode then
		return false, "Fint mode is unavailable."
	end

	if self.fintQualificationResolver then
		local ok, reason = self.fintQualificationResolver(attackerName, mode)
		if ok == nil then
			return true
		end
		return ok, reason
	end

	if Me and Me.GetSS13FintQualification then
		local ok, reason = Me.GetSS13FintQualification(attackerName, mode)
		if ok == nil then
			return true
		end
		return ok, reason
	end

	local masteryValue = self:GetProfileSkillRank("Mastery")
	local intelligenceValue = self:GetProfileSkillRank("Intelligence")
	local hasLocalRequirements = masteryValue ~= nil or intelligenceValue ~= nil

	if hasLocalRequirements then
		local requiredMastery = tonumber(mode.requiredMastery) or 0
		local requiredIntelligence = tonumber(mode.requiredIntelligence) or 0
		local resolvedMastery = masteryValue or 0
		local resolvedIntelligence = intelligenceValue or 0

		if resolvedMastery < requiredMastery or resolvedIntelligence < requiredIntelligence then
			return false, string.format(
				"Fint requires Mastery %d and Intelligence %d.",
				requiredMastery,
				requiredIntelligence
			)
		end
	end

	return true
end

function SS13:AddWeaponIntentTooltipDetails(tooltip, mode)
	if not tooltip or not mode then
		return
	end

	if mode.rightClickAction then
		tooltip:AddLine("Special: right-click the doll while this mode is selected.", 0.98, 0.88, 0.62, true)
	end

	if mode.liveSummary and mode.liveSummary ~= "" then
		tooltip:AddLine("Live: " .. mode.liveSummary, 0.74, 0.94, 0.78, true)
	end

	if mode.futureSummary and mode.futureSummary ~= "" then
		tooltip:AddLine("Future: " .. mode.futureSummary, 0.72, 0.84, 0.98, true)
	end

	if mode.requiredMastery or mode.requiredIntelligence then
		tooltip:AddLine(
			string.format(
				"Requirement: mastery %s, intelligence %s.",
				mode.requiredMastery or "?",
				mode.requiredIntelligence or "?"
			),
			0.94,
			0.84,
			0.70,
			true
		)
	end
end

function SS13:GetTargetState(guid)
	if not guid then
		return nil
	end

	self.targetStates = self.targetStates or {}
	local state = self.targetStates[guid]

	if not state then
		state = {}
		self.targetStates[guid] = state
	end

	return state
end

function SS13:PruneTargetStates()
	if not self.targetStates then
		return
	end

	local now = GetTime()

	for guid, state in pairs(self.targetStates) do
		if state.fintUntil and state.fintUntil <= now then
			state.fintUntil = nil
			state.fintBy = nil
		end

		if next(state) == nil then
			self.targetStates[guid] = nil
		end
	end
end

function SS13:HasActiveFint(guid)
	if not guid or not self.targetStates or not self.targetStates[guid] then
		return false
	end

	local state = self.targetStates[guid]

	if state.fintUntil and state.fintUntil > GetTime() then
		return true
	end

	return false
end

function SS13:GetFintRemaining(guid)
	if not self:HasActiveFint(guid) then
		return 0
	end

	return math.max(0, self.targetStates[guid].fintUntil - GetTime())
end

function SS13:ApplyFintState(targetGUID, attacker, duration)
	if not targetGUID then
		return
	end

	local state = self:GetTargetState(targetGUID)
	state.fintUntil = GetTime() + math.max(0, tonumber(duration) or 0)
	state.fintBy = attacker
	self:UpdateTargetStatusText()
end

function SS13:IsTargetActiveDefenseLocked(targetGUID)
	return self:HasActiveFint(targetGUID)
end

function SS13:GetTargetStatusText(guid)
	if self:HasActiveFint(guid) then
		local state = self.targetStates[guid]
		local secondsLeft = self:GetFintRemaining(guid)
		local attacker = state and state.fintBy or "Someone"
		return string.format("|cffc8a8ffFint lock|r by %s: no dodge/parry for %.1fs", attacker, secondsLeft)
	end

	return TARGET_STATUS_DEFAULT
end

function SS13:UpdateTargetStatusText()
	if not self.frame or not self.frame.TargetStatusText then
		return
	end

	if not self.currentTargetGUID then
		self.frame.TargetStatusText:SetText(TARGET_STATUS_DEFAULT)
		return
	end

	self.frame.TargetStatusText:SetText(self:GetTargetStatusText(self.currentTargetGUID))
end

function SS13:OnStateTickerUpdate(elapsed)
	self.stateTickerElapsed = (self.stateTickerElapsed or 0) + elapsed

	if self.stateTickerElapsed < 0.1 then
		return
	end

	self.stateTickerElapsed = 0
	self:PruneTargetStates()

	if self.frame and self.frame:IsShown() then
		self:UpdateTargetStatusText()
	end
end

function SS13:GetProfileDisplayLabel(profileID, profile)
	if not profile then
		return ToTitleCase(profileID)
	end

	local label = profile.label or ToTitleCase(profileID)

	if self:ProfileSupportsGrip(profile) then
		label = label .. " (D)"
	end

	return label
end

function SS13:GetProfileStateLabel(profile)
	if not profile then
		return nil
	end

	local labels = {}

	for _, bucket in ipairs(self:GetActiveIntentBuckets(profile)) do
		if bucket.label then
			labels[#labels + 1] = bucket.label
		end
	end

	if #labels > 0 then
		return table.concat(labels, " + ")
	end

	return nil
end

function SS13:SyncSelectedIntentForProfile(profile)
	if not profile then
		self.selectedIntentID = nil
		return
	end

	if not self:ProfileHasIntent(profile, self.selectedIntentID) then
		self.selectedIntentID = self:GetFirstIntentForProfile(profile)
	end
end

function SS13:UpdateActionRackButtonVisual(button)
	if not button or not button.SetBackdrop then
		return
	end

	local isSelected = self.selectedProfileID == button.profileID
	local isHovered = button.isHovered

	if isSelected then
		button:SetBackdropColor(0.30, 0.22, 0.10, 0.96)
		button:SetBackdropBorderColor(1.0, 0.86, 0.52, 1.0)
		button.Label:SetTextColor(1.0, 0.96, 0.90)
	elseif isHovered then
		button:SetBackdropColor(0.20, 0.16, 0.10, 0.95)
		button:SetBackdropBorderColor(0.92, 0.74, 0.48, 0.96)
		button.Label:SetTextColor(1.0, 0.93, 0.84)
	else
		button:SetBackdropColor(0.10, 0.10, 0.12, 0.94)
		button:SetBackdropBorderColor(0.46, 0.42, 0.34, 0.92)
		button.Label:SetTextColor(0.88, 0.84, 0.78)
	end
end

function SS13:RefreshActionRackVisuals()
	if self.actionRackButtons then
		for _, button in ipairs(self.actionRackButtons) do
			local profile = self:GetCombatProfile(button.profileID)
			button.Label:SetText(self:GetProfileDisplayLabel(button.profileID, profile))
			self:UpdateActionRackButtonVisual(button)
		end
	end

	if self.frame and self.frame.ActionPanel and self.frame.ActionPanel.Subtitle then
		local profile = self:GetCombatProfile(self.selectedProfileID)

		if profile then
			local stateLabel = self:GetProfileStateLabel(profile)
			local suffix = stateLabel and (" [" .. stateLabel .. "]") or ""
			self.frame.ActionPanel.Subtitle:SetText("Current: " .. self:GetProfileDisplayLabel(self.selectedProfileID, profile) .. suffix)
		else
			self.frame.ActionPanel.Subtitle:SetText(ACTION_PANEL_HINT)
		end
	end
end

function SS13:UpdateIntentButtonVisual(button)
	if not button or not button.SetBackdrop then
		return
	end

	local isSelected = self.selectedIntentID == button.intentID
	local isHovered = button.isHovered

	if isSelected then
		button:SetBackdropColor(0.46, 0.16, 0.18, 0.96)
		button:SetBackdropBorderColor(1.0, 0.80, 0.68, 1.0)
		button.Label:SetTextColor(1.0, 0.95, 0.92)
	elseif isHovered then
		button:SetBackdropColor(0.28, 0.14, 0.16, 0.95)
		button:SetBackdropBorderColor(0.92, 0.66, 0.62, 0.96)
		button.Label:SetTextColor(1.0, 0.90, 0.88)
	else
		button:SetBackdropColor(0.10, 0.10, 0.12, 0.94)
		button:SetBackdropBorderColor(0.40, 0.34, 0.34, 0.92)
		button.Label:SetTextColor(0.88, 0.84, 0.82)
	end
end

function SS13:RefreshIntentButtonVisuals()
	if not self.intentButtons then
		return
	end

	for _, button in ipairs(self.intentButtons) do
		if button:IsShown() then
			self:UpdateIntentButtonVisual(button)
		end
	end
end

function SS13:UpdateIntentPanelSubtitle()
	if not self.frame or not self.frame.IntentPanel or not self.frame.IntentPanel.Subtitle then
		return
	end

	local profile = self:GetCombatProfile(self.selectedProfileID)
	local selectedIntentLabel = self:GetSelectedIntentLabel()
	local bucketLabel

	for _, bucket in ipairs(self:GetActiveIntentBuckets(profile)) do
		for _, intentID in ipairs(bucket.intentIDs or {}) do
			if intentID == self.selectedIntentID then
				bucketLabel = bucket.label
				break
			end
		end

		if bucketLabel then
			break
		end
	end

	if not bucketLabel then
		local primaryBucket = self:GetPrimaryIntentBucket(profile)
		bucketLabel = primaryBucket and primaryBucket.label or nil
	end

	if not profile then
		self.frame.IntentPanel.Subtitle:SetText("Pick a profile in Action Rack.")
	elseif selectedIntentLabel then
		if bucketLabel then
			self.frame.IntentPanel.Subtitle:SetText("Current: " .. selectedIntentLabel .. " [" .. bucketLabel .. "]")
		else
			self.frame.IntentPanel.Subtitle:SetText("Current: " .. selectedIntentLabel)
		end
	else
		local stateLabel = self:GetProfileStateLabel(profile)
		local prefix = stateLabel and (stateLabel .. " sets") or "set"
		self.frame.IntentPanel.Subtitle:SetText("Pick an intent from the " .. prefix .. ".")
	end
end

function SS13:AcquireIntentHeader(index)
	self.intentPanelHeaders = self.intentPanelHeaders or {}
	local header = self.intentPanelHeaders[index]
	local content = self.frame and self.frame.IntentPanel and self.frame.IntentPanel.Content

	if not content then
		return nil
	end

	if not header then
		header = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		header:SetWidth(INTENT_PANEL_WIDTH - 24)
		header:SetJustifyH("LEFT")
		header:SetJustifyV("TOP")
		self.intentPanelHeaders[index] = header
	end

	return header
end

function SS13:AcquireIntentButton(index)
	self.intentButtons = self.intentButtons or {}
	local button = self.intentButtons[index]
	local content = self.frame and self.frame.IntentPanel and self.frame.IntentPanel.Content

	if not content then
		return nil
	end

	if not button then
		button = CreateFrame("Button", nil, content, BackdropTemplateType)
		button:SetSize(INTENT_PANEL_WIDTH - 24, 24)
		button:RegisterForClicks("LeftButtonUp")

		if button.SetBackdrop then
			button:SetBackdrop({
				bgFile = "Interface\\Buttons\\WHITE8x8",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
				edgeSize = 10,
				insets = { left = 2, right = 2, top = 2, bottom = 2 },
			})
		end

		local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		label:SetPoint("TOPLEFT", 6, -4)
		label:SetPoint("BOTTOMRIGHT", -6, 4)
		label:SetJustifyH("LEFT")
		label:SetJustifyV("MIDDLE")
		button.Label = label

		button:SetScript("OnEnter", function(intentButton)
			intentButton.isHovered = true
			SS13:UpdateIntentButtonVisual(intentButton)

			local intent = SS13:GetCombatIntent(intentButton.intentID)
			GameTooltip:SetOwner(intentButton, "ANCHOR_RIGHT")
			GameTooltip:SetText(intent and ToTitleCase(intent.name) or "Intent")

			if intent and intent.description and intent.description ~= "" then
				GameTooltip:AddLine(intent.description, 0.8, 0.8, 0.8, true)
			end

			GameTooltip:Show()
		end)

		button:SetScript("OnLeave", function(intentButton)
			intentButton.isHovered = nil
			SS13:UpdateIntentButtonVisual(intentButton)
			GameTooltip:Hide()
		end)

		button:SetScript("OnClick", function(intentButton)
			SS13:SetSelectedIntent(intentButton.intentID)
		end)

		self.intentButtons[index] = button
	end

	return button
end

function SS13:RefreshIntentPanel()
	if not self.frame or not self.frame.IntentPanel or not self.frame.IntentPanel.Content then
		return
	end

	local panel = self.frame.IntentPanel
	local content = panel.Content
	local profile = self:GetCombatProfile(self.selectedProfileID)
	local buckets = self:GetActiveIntentBuckets(profile)

	if panel.EmptyText then
		panel.EmptyText:Hide()
	end

	if self.intentPanelHeaders then
		for _, header in ipairs(self.intentPanelHeaders) do
			header:Hide()
		end
	end

	if self.intentButtons then
		for _, button in ipairs(self.intentButtons) do
			button:Hide()
		end
	end

	self:UpdateIntentPanelSubtitle()

	if not profile then
		panel.EmptyText = panel.EmptyText or content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		panel.EmptyText:ClearAllPoints()
		panel.EmptyText:SetPoint("TOPLEFT", 0, 0)
		panel.EmptyText:SetWidth(INTENT_PANEL_WIDTH - 24)
		panel.EmptyText:SetJustifyH("LEFT")
		panel.EmptyText:SetJustifyV("TOP")
		panel.EmptyText:SetText("No profile selected.")
		panel.EmptyText:Show()
		return
	end

	if #buckets == 0 then
		panel.EmptyText = panel.EmptyText or content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		panel.EmptyText:ClearAllPoints()
		panel.EmptyText:SetPoint("TOPLEFT", 0, 0)
		panel.EmptyText:SetWidth(INTENT_PANEL_WIDTH - 24)
		panel.EmptyText:SetJustifyH("LEFT")
		panel.EmptyText:SetJustifyV("TOP")
		panel.EmptyText:SetText("No intents are available for this state.")
		panel.EmptyText:Show()
		return
	end

	local anchorRegion
	local headerIndex = 1
	local buttonIndex = 1

	for _, bucket in ipairs(buckets) do
		if bucket.intentIDs and #bucket.intentIDs > 0 then
			local header = self:AcquireIntentHeader(headerIndex)

			if header then
				header:ClearAllPoints()
				if anchorRegion then
					header:SetPoint("TOPLEFT", anchorRegion, "BOTTOMLEFT", 0, -8)
				else
					header:SetPoint("TOPLEFT", 0, 0)
				end
				header:SetText(bucket.label)
				header:Show()
				anchorRegion = header
			end

			headerIndex = headerIndex + 1

			for _, intentID in ipairs(bucket.intentIDs) do
				local button = self:AcquireIntentButton(buttonIndex)
				local intent = self:GetCombatIntent(intentID)

				if button then
					button:ClearAllPoints()
					button:SetPoint("TOPLEFT", anchorRegion, "BOTTOMLEFT", 0, -2)
					button.intentID = intentID
					button.Label:SetText(intent and ToTitleCase(intent.name) or ToTitleCase(string.gsub(intentID, "_", " ")))
					button:Show()
					self:UpdateIntentButtonVisual(button)
					anchorRegion = button
				end

				buttonIndex = buttonIndex + 1
			end
		end
	end
end

function SS13:SetSelectedIntent(intentID)
	local profile = self:GetCombatProfile(self.selectedProfileID)

	if not self:ProfileHasIntent(profile, intentID) then
		return
	end

	self.selectedIntentID = intentID
	self:RefreshIntentButtonVisuals()
	self:UpdateIntentPanelSubtitle()
	self:RefreshWeaponIntentPanelVisuals()
end

function SS13:SetSelectedProfile(profileID)
	local profile = self:GetCombatProfile(profileID)

	if not profile then
		return
	end

	if self.selectedProfileID == profileID and self:ProfileSupportsGrip(profile) then
		self.gripActive = not self.gripActive
	else
		self.selectedProfileID = profileID
		self.gripActive = false
	end

	self:SyncSelectedIntentForProfile(profile)

	self:RefreshActionRackVisuals()
	self:RefreshIntentPanel()
	self:RefreshWeaponIntentPanelVisuals()
end

function SS13:UpdateWeaponIntentButtonVisual(button)
	if not button or not button.SetBackdrop then
		return
	end

	local isSelected = self.selectedWeaponIntentModeID == button.modeID
	local isHovered = button.isHovered

	if isSelected then
		button:SetBackdropColor(0.18, 0.24, 0.10, 0.96)
		button:SetBackdropBorderColor(0.86, 1.0, 0.56, 1.0)
		button.Label:SetTextColor(0.96, 1.0, 0.90)
	elseif isHovered then
		button:SetBackdropColor(0.12, 0.18, 0.10, 0.95)
		button:SetBackdropBorderColor(0.72, 0.90, 0.56, 0.96)
		button.Label:SetTextColor(0.92, 0.98, 0.86)
	else
		button:SetBackdropColor(0.10, 0.10, 0.12, 0.94)
		button:SetBackdropBorderColor(0.34, 0.42, 0.34, 0.92)
		button.Label:SetTextColor(0.82, 0.88, 0.82)
	end
end

function SS13:RefreshWeaponIntentPanelVisuals()
	if self.weaponIntentButtons then
		for _, button in ipairs(self.weaponIntentButtons) do
			self:UpdateWeaponIntentButtonVisual(button)
		end
	end

	if self.frame and self.frame.WeaponIntentPanel and self.frame.WeaponIntentPanel.Subtitle then
		local intentLabel = self:GetSelectedIntentLabel()
		local modeLabel = self:GetSelectedWeaponIntentLabel()

		if intentLabel and modeLabel then
			self.frame.WeaponIntentPanel.Subtitle:SetText(string.format("Current: %s for %s", modeLabel, intentLabel))
		elseif modeLabel then
			self.frame.WeaponIntentPanel.Subtitle:SetText("Current: " .. modeLabel)
		else
			self.frame.WeaponIntentPanel.Subtitle:SetText("Pick a weapon intent.")
		end
	end
end

function SS13:SetSelectedWeaponIntentMode(modeID)
	if not self:GetWeaponIntentMode(modeID) then
		return
	end

	self.selectedWeaponIntentModeID = modeID
	self:SyncSelectedIntentForProfile(self:GetCombatProfile(self.selectedProfileID))
	self:RefreshActionRackVisuals()
	self:RefreshIntentPanel()
	self:RefreshWeaponIntentPanelVisuals()
end

function SS13:RequestWeaponIntentFint(modeID, mode, zoneKey)
	if not self.currentTargetGUID then
		self:SetResultText("Target an NPC before using Fint.", "|cffffd166")
		return false
	end

	local canUse, reason = self:CanApplyFint(self:GetPlayerName(), mode)

	if not canUse then
		self:SetResultText(reason or "Not enough mastery or intelligence for Fint.", "|cffff6060")
		return false
	end

	if not self:CanUsePartyTransport() then
		self:HandleFintRequest({ "REQ_FINT", self.currentTargetGUID, modeID }, self:GetPlayerName())
	elseif SendAddon then
		local payload = PackMessage("REQ_FINT", self.currentTargetGUID, modeID)
		SendAddon(PREFIX, payload, CHANNEL)
		self:SetResultText("REQ_FINT: " .. (self.currentTargetName or "target"), "|cffc8c8ff")

		if self:IsAuthorityPlayer() then
			self:HandleFintRequest(UnpackMessage(payload), self:GetPlayerName())
		end
	else
		self:SetResultText("Addon transport is unavailable.", "|cffff6060")
		return false
	end

	return true
end

function SS13:ActivateWeaponIntentSpecial(modeID, zoneKey)
	local resolvedModeID = modeID or self.selectedWeaponIntentModeID
	local mode = self:GetWeaponIntentMode(resolvedModeID)
	local action = self:GetWeaponIntentSpecialAction(resolvedModeID)

	if not mode or not action then
		return false
	end

	if action == "apply_fint" then
		return self:RequestWeaponIntentFint(resolvedModeID, mode, zoneKey)
	end

	self:SetResultText("This weapon special is not wired yet.", "|cffffd166")
	return false
end

function SS13:UseWeaponIntentRightClickAction(modeID)
	return self:ActivateWeaponIntentSpecial(modeID)
end

function SS13:CreateWeaponIntentPanel(parent)
	if not parent or (self.frame and self.frame.WeaponIntentPanel) then
		return
	end

	local panel = CreateFrame("Frame", nil, parent, BackdropTemplateType)
	panel:SetSize(WEAPON_INTENT_PANEL_WIDTH, FRAME_HEIGHT)
	panel:SetPoint("TOPRIGHT", parent, "TOPLEFT", -WEAPON_INTENT_PANEL_GAP, 0)

	if panel.SetBackdrop then
		panel:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 14,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		panel:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
		panel:SetBackdropBorderColor(0.48, 0.62, 0.48, 0.96)
	end

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	title:SetPoint("TOP", 0, -14)
	title:SetText(WEAPON_INTENT_PANEL_TITLE)
	panel.Title = title

	local subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	subtitle:SetPoint("TOP", title, "BOTTOM", 0, -8)
	subtitle:SetWidth(WEAPON_INTENT_PANEL_WIDTH - 28)
	subtitle:SetJustifyH("CENTER")
	panel.Subtitle = subtitle

	self.weaponIntentButtons = self.weaponIntentButtons or {}
	local combatData = self:GetCombatData()

	if combatData and combatData.WeaponIntentModeOrder then
		for index, modeID in ipairs(combatData.WeaponIntentModeOrder) do
			local mode = combatData:GetWeaponIntentMode(modeID)

			if mode then
				local modeData = mode
				local button = CreateFrame("Button", nil, panel, BackdropTemplateType)
				button:SetSize(WEAPON_INTENT_PANEL_WIDTH - 24, 26)
				button:SetPoint("TOPLEFT", 12, -56 - ((index - 1) * 30))
				button:RegisterForClicks("LeftButtonUp")
				button.modeID = modeID

				if button.SetBackdrop then
					button:SetBackdrop({
						bgFile = "Interface\\Buttons\\WHITE8x8",
						edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
						edgeSize = 10,
						insets = { left = 2, right = 2, top = 2, bottom = 2 },
					})
				end

				local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				label:SetPoint("TOPLEFT", 6, -4)
				label:SetPoint("BOTTOMRIGHT", -6, 4)
				label:SetJustifyH("LEFT")
				label:SetJustifyV("MIDDLE")
				label:SetText(modeData.label)
				button.Label = label

				button:SetScript("OnEnter", function(modeButton)
					modeButton.isHovered = true
					SS13:UpdateWeaponIntentButtonVisual(modeButton)

					GameTooltip:SetOwner(modeButton, "ANCHOR_RIGHT")
					GameTooltip:SetText(modeData.label)
					GameTooltip:AddLine(modeData.description or "", 0.8, 0.8, 0.8, true)
					SS13:AddWeaponIntentTooltipDetails(GameTooltip, modeData)
					GameTooltip:Show()
				end)

				button:SetScript("OnLeave", function(modeButton)
					modeButton.isHovered = nil
					SS13:UpdateWeaponIntentButtonVisual(modeButton)
					GameTooltip:Hide()
				end)

				button:SetScript("OnClick", function(modeButton)
					SS13:SetSelectedWeaponIntentMode(modeButton.modeID)
				end)

				self.weaponIntentButtons[#self.weaponIntentButtons + 1] = button
			end
		end
	end

	self.frame.WeaponIntentPanel = panel

	if combatData and combatData.WeaponIntentModeOrder and combatData.WeaponIntentModeOrder[1] and not self.selectedWeaponIntentModeID then
		self:SetSelectedWeaponIntentMode(combatData.WeaponIntentModeOrder[1])
	else
		self:RefreshWeaponIntentPanelVisuals()
	end
end

function SS13:UpdateCombatStatePanelVisuals()
	local panel = self.frame and self.frame.CombatStatePanel

	if not panel then
		return
	end

	local modeLabel

	if self.combatModeEnabled then
		modeLabel = "Combat Mode: " .. ToTitleCase(self.selectedDefenseMethod or DEFAULT_DEFENSE_METHOD)
	else
		modeLabel = "Combat Mode: Body Hits"
	end

	panel.Subtitle:SetText(modeLabel)

	if panel.ModeButton and panel.ModeButton.SetBackdrop then
		if self.combatModeEnabled then
			panel.ModeButton:SetBackdropColor(0.22, 0.28, 0.14, 0.96)
			panel.ModeButton:SetBackdropBorderColor(0.82, 0.96, 0.58, 1.0)
			panel.ModeButton.Label:SetTextColor(0.96, 1.0, 0.90)
			panel.ModeButton.Label:SetText("Combat: On")
		else
			panel.ModeButton:SetBackdropColor(0.18, 0.10, 0.10, 0.96)
			panel.ModeButton:SetBackdropBorderColor(0.80, 0.52, 0.52, 1.0)
			panel.ModeButton.Label:SetTextColor(1.0, 0.90, 0.90)
			panel.ModeButton.Label:SetText("Combat: Off")
		end
	end

	for _, defenseButton in ipairs({ panel.ParryButton, panel.DodgeButton }) do
		if defenseButton and defenseButton.SetBackdrop then
			local isSelected = self.selectedDefenseMethod == defenseButton.defenseMode

			if not self.combatModeEnabled then
				defenseButton:SetBackdropColor(0.12, 0.12, 0.12, 0.94)
				defenseButton:SetBackdropBorderColor(isSelected and 0.72 or 0.38, isSelected and 0.72 or 0.38, isSelected and 0.72 or 0.38, 0.92)
				defenseButton.Label:SetTextColor(0.64, 0.64, 0.64)
			elseif isSelected then
				defenseButton:SetBackdropColor(0.18, 0.20, 0.34, 0.96)
				defenseButton:SetBackdropBorderColor(0.72, 0.84, 1.0, 1.0)
				defenseButton.Label:SetTextColor(0.92, 0.96, 1.0)
			else
				defenseButton:SetBackdropColor(0.10, 0.10, 0.12, 0.94)
				defenseButton:SetBackdropBorderColor(0.34, 0.34, 0.42, 0.92)
				defenseButton.Label:SetTextColor(0.82, 0.82, 0.88)
			end
		end
	end
end

function SS13:SetCombatModeEnabled(enabled)
	self.combatModeEnabled = enabled and true or false
	self:UpdateCombatStatePanelVisuals()
	self:UpdateTargetStatusText()
end

function SS13:SetDefenseMethod(defenseMethod)
	if defenseMethod ~= "parry" and defenseMethod ~= "dodge" then
		return
	end

	self.selectedDefenseMethod = defenseMethod
	self:UpdateCombatStatePanelVisuals()
	self:UpdateTargetStatusText()
end

function SS13:CreateCombatStateButton(parent, width, height, labelText)
	local button = CreateFrame("Button", nil, parent, BackdropTemplateType)
	button:SetSize(width, height)
	button:RegisterForClicks("LeftButtonUp")

	if button.SetBackdrop then
		button:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8x8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 10,
			insets = { left = 2, right = 2, top = 2, bottom = 2 },
		})
	end

	local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("TOPLEFT", 6, -4)
	label:SetPoint("BOTTOMRIGHT", -6, 4)
	label:SetJustifyH("CENTER")
	label:SetJustifyV("MIDDLE")
	label:SetText(labelText)
	button.Label = label

	return button
end

function SS13:CreateCombatStatePanel(parent)
	if not parent or (self.frame and self.frame.CombatStatePanel) then
		return
	end

	local panel = CreateFrame("Frame", nil, parent, BackdropTemplateType)
	panel:SetSize(ACTION_PANEL_WIDTH, COMBAT_STATE_PANEL_HEIGHT)
	panel:SetPoint("BOTTOMLEFT", parent, "TOPLEFT", 0, COMBAT_STATE_PANEL_GAP)

	if panel.SetBackdrop then
		panel:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 14,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		panel:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
		panel:SetBackdropBorderColor(0.58, 0.58, 0.74, 0.96)
	end

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	title:SetPoint("TOP", 0, -12)
	title:SetText(COMBAT_STATE_PANEL_TITLE)
	panel.Title = title

	local subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	subtitle:SetPoint("TOP", title, "BOTTOM", 0, -8)
	subtitle:SetWidth(ACTION_PANEL_WIDTH - 24)
	subtitle:SetJustifyH("CENTER")
	panel.Subtitle = subtitle

	local modeButton = self:CreateCombatStateButton(panel, ACTION_PANEL_WIDTH - 24, 26, "Combat: Off")
	modeButton:SetPoint("TOPLEFT", 12, -48)
	modeButton:SetScript("OnClick", function()
		SS13:SetCombatModeEnabled(not SS13.combatModeEnabled)
	end)
	modeButton:SetScript("OnEnter", function()
		GameTooltip:SetOwner(modeButton, "ANCHOR_RIGHT")
		GameTooltip:SetText("Combat Mode")
		GameTooltip:AddLine("When disabled, you take hits with the body instead of using active defense.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	modeButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	panel.ModeButton = modeButton

	local parryButton = self:CreateCombatStateButton(panel, (ACTION_PANEL_WIDTH - 30) / 2, 24, "Parry")
	parryButton:SetPoint("TOPLEFT", modeButton, "BOTTOMLEFT", 0, -6)
	parryButton.defenseMode = "parry"
	parryButton:SetScript("OnClick", function()
		SS13:SetDefenseMethod("parry")
	end)
	parryButton:SetScript("OnEnter", function()
		GameTooltip:SetOwner(parryButton, "ANCHOR_RIGHT")
		GameTooltip:SetText("Parry")
		GameTooltip:AddLine("Preferred active defense while combat mode is enabled.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	parryButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	panel.ParryButton = parryButton

	local dodgeButton = self:CreateCombatStateButton(panel, (ACTION_PANEL_WIDTH - 30) / 2, 24, "Dodge")
	dodgeButton:SetPoint("TOPRIGHT", modeButton, "BOTTOMRIGHT", 0, -6)
	dodgeButton.defenseMode = "dodge"
	dodgeButton:SetScript("OnClick", function()
		SS13:SetDefenseMethod("dodge")
	end)
	dodgeButton:SetScript("OnEnter", function()
		GameTooltip:SetOwner(dodgeButton, "ANCHOR_RIGHT")
		GameTooltip:SetText("Dodge")
		GameTooltip:AddLine("Preferred active defense while combat mode is enabled.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	dodgeButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	panel.DodgeButton = dodgeButton

	self.frame.CombatStatePanel = panel

	if self.selectedDefenseMethod == nil then
		self.selectedDefenseMethod = DEFAULT_DEFENSE_METHOD
	end

	if self.combatModeEnabled == nil then
		self.combatModeEnabled = true
	end

	self:UpdateCombatStatePanelVisuals()
end

function SS13:CreateIntentPanel(parent)
	if not parent or (self.frame and self.frame.IntentPanel) then
		return
	end

	local panel = CreateFrame("Frame", nil, parent, BackdropTemplateType)
	panel:SetSize(INTENT_PANEL_WIDTH, FRAME_HEIGHT)
	panel:SetPoint("TOPRIGHT", parent, "TOPLEFT", -INTENT_PANEL_GAP, 0)

	if panel.SetBackdrop then
		panel:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 14,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		panel:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
		panel:SetBackdropBorderColor(0.62, 0.48, 0.48, 0.96)
	end

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	title:SetPoint("TOP", 0, -14)
	title:SetText(INTENT_PANEL_TITLE)
	panel.Title = title

	local subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	subtitle:SetPoint("TOP", title, "BOTTOM", 0, -8)
	subtitle:SetWidth(INTENT_PANEL_WIDTH - 28)
	subtitle:SetJustifyH("CENTER")
	panel.Subtitle = subtitle

	local content = CreateFrame("Frame", nil, panel)
	content:SetPoint("TOPLEFT", 12, -62)
	content:SetPoint("BOTTOMRIGHT", -12, 12)
	panel.Content = content

	self.frame.IntentPanel = panel
	self:UpdateIntentPanelSubtitle()
end

function SS13:CreateActionPanel(parent)
	if not parent or parent.ActionPanel then
		return
	end

	local panel = CreateFrame("Frame", nil, parent, BackdropTemplateType)
	panel:SetSize(ACTION_PANEL_WIDTH, FRAME_HEIGHT)
	panel:SetPoint("TOPRIGHT", parent, "TOPLEFT", -ACTION_PANEL_GAP, 0)

	if panel.SetBackdrop then
		panel:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 14,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		panel:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
		panel:SetBackdropBorderColor(0.66, 0.58, 0.48, 0.96)
	end

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	title:SetPoint("TOP", 0, -14)
	title:SetText(ACTION_PANEL_TITLE)
	panel.Title = title

	local subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	subtitle:SetPoint("TOP", title, "BOTTOM", 0, -8)
	subtitle:SetWidth(ACTION_PANEL_WIDTH - 28)
	subtitle:SetJustifyH("CENTER")
	subtitle:SetText(ACTION_PANEL_HINT)
	panel.Subtitle = subtitle

	self.actionRackButtons = self.actionRackButtons or {}
	local combatData = self:GetCombatData()

	if combatData and combatData.WeaponProfileOrder then
		for index, profileID in ipairs(combatData.WeaponProfileOrder) do
			local profile = combatData:GetWeaponProfile(profileID)

			if profile then
				local profileData = profile
				local profileKey = profileID
				local button = CreateFrame("Button", nil, panel, BackdropTemplateType)
				button:SetSize(ACTION_PANEL_WIDTH - 24, 26)
				button:SetPoint("TOPLEFT", 12, -56 - ((index - 1) * 30))
				button:RegisterForClicks("LeftButtonUp")
				button.profileID = profileKey

				if button.SetBackdrop then
					button:SetBackdrop({
						bgFile = "Interface\\Buttons\\WHITE8x8",
						edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
						edgeSize = 10,
						insets = { left = 2, right = 2, top = 2, bottom = 2 },
					})
				end

				local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				label:SetPoint("TOPLEFT", 6, -4)
				label:SetPoint("BOTTOMRIGHT", -6, 4)
				label:SetJustifyH("LEFT")
				label:SetJustifyV("MIDDLE")
				label:SetText(SS13:GetProfileDisplayLabel(profileKey, profileData))
				button.Label = label

				button:SetScript("OnEnter", function(profileButton)
					profileButton.isHovered = true
					SS13:UpdateActionRackButtonVisual(profileButton)

					GameTooltip:SetOwner(profileButton, "ANCHOR_RIGHT")
					GameTooltip:SetText(SS13:GetProfileDisplayLabel(profileKey, profileData))

					if profileData.description and profileData.description ~= "" then
						GameTooltip:AddLine(profileData.description, 0.8, 0.8, 0.8, true)
					end

					if SS13:ProfileSupportsGrip(profileData) then
						GameTooltip:AddLine("Click the same weapon again to toggle Grip.", 0.98, 0.88, 0.62, true)
					end

					GameTooltip:Show()
				end)

				button:SetScript("OnLeave", function(profileButton)
					profileButton.isHovered = nil
					SS13:UpdateActionRackButtonVisual(profileButton)
					GameTooltip:Hide()
				end)

				button:SetScript("OnClick", function(profileButton)
					SS13:SetSelectedProfile(profileButton.profileID)
				end)

				self.actionRackButtons[#self.actionRackButtons + 1] = button
			end
		end
	end

	parent.ActionPanel = panel
	self:CreateCombatStatePanel(panel)
	self:CreateIntentPanel(panel)
	self:CreateWeaponIntentPanel(self.frame.IntentPanel)

	if combatData and combatData.WeaponProfileOrder and combatData.WeaponProfileOrder[1] and not self.selectedProfileID then
		self:SetSelectedProfile(combatData.WeaponProfileOrder[1])
	else
		self:RefreshActionRackVisuals()
		self:RefreshIntentPanel()
		self:RefreshWeaponIntentPanelVisuals()
		self:UpdateCombatStatePanelVisuals()
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
		button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
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
			local hasWeaponSpecial = SS13:GetWeaponIntentSpecialAction(SS13.selectedWeaponIntentModeID)

			GameTooltip:SetOwner(zoneButton, "ANCHOR_RIGHT")
			GameTooltip:SetText(zone.label)
			GameTooltip:AddLine("Left-click: attack this zone.", 0.8, 0.8, 0.8, true)
			if hasWeaponSpecial then
				GameTooltip:AddLine("Right-click: use the selected weapon special on the target.", 0.98, 0.88, 0.62, true)
			end
			GameTooltip:Show()
		end)

		button:SetScript("OnLeave", function(zoneButton)
			zoneButton.isHovered = nil
			SS13:UpdateZoneButtonVisual(zoneButton)
			GameTooltip:Hide()
		end)

		button:SetScript("OnClick", function(zoneButton, mouseButton)
			if mouseButton == "RightButton" then
				SS13:OnZoneButtonRightClick(zoneButton.zoneData)
			else
				SS13:OnZoneButtonClick(zoneButton.zoneData)
			end
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

	local targetStatusText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	targetStatusText:SetPoint("TOP", targetText, "BOTTOM", 0, -6)
	targetStatusText:SetWidth(FRAME_WIDTH - 36)
	targetStatusText:SetJustifyH("CENTER")
	targetStatusText:SetText(TARGET_STATUS_DEFAULT)
	frame.TargetStatusText = targetStatusText

	local board = CreateFrame("Frame", nil, frame, BackdropTemplateType)
	board:SetSize(BOARD_WIDTH, BOARD_HEIGHT)
	board:SetPoint("TOP", targetStatusText, "BOTTOM", 0, -10)

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
	self:CreateActionPanel(frame)
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
		self.frame.HintText:SetText("Pick a profile and intent, then LMB a zone to attack or RMB the doll for a weapon special.")
	elseif self:IsAuthorityPlayer() then
		self.frame.RoleText:SetText("|cff7dff7dMode: GM Server|r")
		self.frame.HintText:SetText("Pick a profile and intent, then LMB a zone to attack or RMB the doll for a weapon special.")
	else
		self.frame.RoleText:SetText("|cffffd166Mode: Client|r")
		self.frame.HintText:SetText("Pick a profile and intent, then LMB a zone to attack or RMB the doll for a weapon special.")
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
		self:UpdateTargetStatusText()
		self.frame:Show()
	else
		self.currentTargetGUID = nil
		self.currentTargetName = nil
		self:SetSelectedZone(nil)
		self.frame.TargetText:SetText("Target: none")
		self:UpdateTargetStatusText()
		self:SetResultText("Awaiting configured NPC target.")
		self.frame:Hide()
	end
end

function SS13:OnZoneButtonClick(zone)
	if not zone or not self.currentTargetGUID or self:IsOnCooldown() then
		return
	end

	if not self.selectedIntentID then
		self:SetResultText("Pick an intent in Intent Tray first.", "|cffffd166")
		return
	end

	if not self.selectedWeaponIntentModeID then
		self:SetResultText("Pick a weapon intent first.", "|cffffd166")
		return
	end

	self:SetSelectedZone(zone.key)
	if self:SendAttackRequest(self.currentTargetGUID, zone.key, self.selectedIntentID, self.selectedWeaponIntentModeID) then
		self:StartCooldown()
	end
end

function SS13:OnZoneButtonRightClick(zone)
	if not zone or not self.currentTargetGUID then
		return
	end

	if not self.selectedWeaponIntentModeID then
		self:SetResultText("Pick a weapon intent first.", "|cffffd166")
		return
	end

	if not self:GetWeaponIntentSpecialAction(self.selectedWeaponIntentModeID) then
		local modeLabel = self:GetSelectedWeaponIntentLabel() or "current mode"
		self:SetResultText("No special effect is available for " .. modeLabel .. ".", "|cffffd166")
		return
	end

	self:ActivateWeaponIntentSpecial(self.selectedWeaponIntentModeID, zone.key)
end

-------------------------------------------------------------------------------
-- Protocol block.
-- Requests are now zone-based rather than raw click coordinates.
-------------------------------------------------------------------------------

function SS13:SendAttackRequest(targetGUID, zoneKey, intentID, weaponIntentModeID)
	local zone = self.ZonesByKey[zoneKey]
	local actionContext = self:BuildActionIntentContext(intentID, weaponIntentModeID)
	local intentLabel = actionContext and actionContext.intentLabel or "Intent"
	local weaponIntentLabel = actionContext and actionContext.weaponIntentLabel or "Weapon Intent"

	if not zone or not actionContext then
		return false
	end

	if not self:CanUsePartyTransport() then
		self:SetResultText("Resolving " .. intentLabel .. " (" .. weaponIntentLabel .. ") -> " .. zone.label .. " locally.", "|cffc8c8ff")
		self:HandleAttackRequest({ "REQ_ATTACK", targetGUID, zoneKey, intentID, weaponIntentModeID }, self:GetPlayerName())
		return true
	end

	if not SendAddon then
		self:SetResultText("Addon transport is unavailable.", "|cffff6060")
		return false
	end

	local payload = PackMessage("REQ_ATTACK", targetGUID, zoneKey, intentID, weaponIntentModeID)
	SendAddon(PREFIX, payload, CHANNEL)
	self:SetResultText("REQ_ATTACK: " .. intentLabel .. " (" .. weaponIntentLabel .. ") -> " .. zone.label, "|cffc8c8ff")

	-- Party leaders may not receive their own PARTY addon messages.
	if self:IsAuthorityPlayer() then
		self:HandleAttackRequest(UnpackMessage(payload), self:GetPlayerName())
	end

	return true
end

-------------------------------------------------------------------------------
-- GM / server block.
-------------------------------------------------------------------------------

function SS13:ResolveAttackResult(zone, actionContext)
	if not zone then
		return "MISS", "Miss"
	end

	local hitChance = zone.hitChance or 100

	if actionContext and actionContext.accuracyModifier then
		hitChance = Clamp(hitChance + actionContext.accuracyModifier, 1, 100)
	end

	if math.random(1, 100) <= hitChance then
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
	local intentID = fields[4]
	local weaponIntentModeID = fields[5]
	local zone = self.ZonesByKey[zoneKey]
	local actionContext = self:BuildActionIntentContext(intentID, weaponIntentModeID)

	if not targetGUID or not zone or not actionContext then
		return
	end

	if not UnitExists("target") or not self:IsConfiguredTarget("target") then
		return
	end

	if UnitGUID("target") ~= targetGUID then
		return
	end

	local result, zoneLabel = self:ResolveAttackResult(zone, actionContext)

	if self:CanUsePartyTransport() then
		local payload = PackMessage("EXEC_HIT", targetGUID, zoneKey, zoneLabel, sender, result, intentID, weaponIntentModeID)
		SendAddon(PREFIX, payload, CHANNEL)
		self:HandleExecutionBroadcast(UnpackMessage(payload), self:GetPlayerName())
	else
		self:HandleExecutionBroadcast({ "EXEC_HIT", targetGUID, zoneKey, zoneLabel, sender, result, intentID, weaponIntentModeID }, self:GetPlayerName())
	end
end

function SS13:HandleFintRequest(fields, sender)
	if not self:IsAuthorityPlayer() then
		return
	end

	if self:CanUsePartyTransport() and not self:IsGroupMemberName(sender) then
		return
	end

	local targetGUID = fields[2]
	local modeID = fields[3]
	local mode = self:GetWeaponIntentMode(modeID)

	if not targetGUID or not mode or mode.rightClickAction ~= "apply_fint" then
		return
	end

	if not UnitExists("target") or not self:IsConfiguredTarget("target") or UnitGUID("target") ~= targetGUID then
		return
	end

	local canUse, reason = self:CanApplyFint(sender, mode)

	if not canUse then
		if sender == self:GetPlayerName() then
			self:SetResultText(reason or "Fint failed qualification.", "|cffff6060")
		end
		return
	end

	local duration = mode.fintDuration or 6

	if self:CanUsePartyTransport() then
		local payload = PackMessage("EXEC_FINT", targetGUID, sender, duration)
		SendAddon(PREFIX, payload, CHANNEL)
		self:HandleFintBroadcast(UnpackMessage(payload), self:GetPlayerName())
	else
		self:HandleFintBroadcast({ "EXEC_FINT", targetGUID, sender, duration }, self:GetPlayerName())
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
	local intentID = fields[7]
	local weaponIntentModeID = fields[8]
	local zone = self.ZonesByKey[zoneKey]
	local actionContext = self:BuildActionIntentContext(intentID, weaponIntentModeID)
	local intentLabel = actionContext and actionContext.intentLabel or nil
	local weaponIntentLabel = actionContext and actionContext.weaponIntentLabel or nil

	if not targetGUID or not zone then
		return
	end

	if self.currentTargetGUID == targetGUID then
		self:SetSelectedZone(zoneKey)
		self:PlayFencingAnimation(zone.centerX, zone.centerY)
	end

	local targetLabel = self.currentTargetGUID == targetGUID and self.currentTargetName or "target"

	if attacker == self:GetPlayerName() then
		self:LogToAddonChat(BuildCombatLogMessage(targetLabel, zoneLabel, intentLabel, weaponIntentLabel, result))
	end

	if result == "HIT" then
		if intentLabel then
			if weaponIntentLabel then
				self:SetResultText(string.format("%s hit %s: %s via %s (%s)", attacker, targetLabel, zoneLabel, intentLabel, weaponIntentLabel), "|cff7dff7d")
			else
				self:SetResultText(string.format("%s hit %s: %s via %s", attacker, targetLabel, zoneLabel, intentLabel), "|cff7dff7d")
			end
		else
			self:SetResultText(string.format("%s hit %s: %s", attacker, targetLabel, zoneLabel), "|cff7dff7d")
		end
	else
		if intentLabel then
			if weaponIntentLabel then
				self:SetResultText(string.format("%s missed %s at %s with %s (%s)", attacker, targetLabel, zoneLabel, intentLabel, weaponIntentLabel), "|cffff6060")
			else
				self:SetResultText(string.format("%s missed %s at %s with %s", attacker, targetLabel, zoneLabel, intentLabel), "|cffff6060")
			end
		else
			self:SetResultText(string.format("%s missed %s at %s", attacker, targetLabel, zoneLabel), "|cffff6060")
		end
	end
end

function SS13:HandleFintBroadcast(fields, sender)
	if self:CanUsePartyTransport() and not self:IsSenderAuthority(sender) and sender ~= self:GetPlayerName() then
		return
	end

	local targetGUID = fields[2]
	local attacker = fields[3] or sender
	local duration = tonumber(fields[4]) or 6

	if not targetGUID then
		return
	end

	self:ApplyFintState(targetGUID, attacker, duration)

	if self.currentTargetGUID == targetGUID then
		self:UpdateTargetStatusText()
	end

	if attacker == self:GetPlayerName() then
		self:LogToAddonChat(string.format("You apply a Fint lock for %.1fs.", duration))
		self:SetResultText(string.format("%s applies Fint: no dodge/parry for %.1fs", attacker, duration), "|cffc8a8ff")
	elseif self.currentTargetGUID == targetGUID then
		self:SetResultText(string.format("%s applies Fint to %s.", attacker, self.currentTargetName or "target"), "|cffc8a8ff")
	end
end

function SS13:ApplyConfig()
	self:UpdateRoleText()
	self:RefreshTargetFrame()
	self:UpdateCooldownVisuals()
	self:RefreshActionRackVisuals()
	self:RefreshIntentPanel()
	self:RefreshWeaponIntentPanelVisuals()
	self:UpdateCombatStatePanelVisuals()
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
	elseif messageType == "REQ_FINT" then
		if senderName == self:GetPlayerName() then
			return
		end

		self:HandleFintRequest(fields, senderName)
	elseif messageType == "EXEC_HIT" then
		if senderName == self:GetPlayerName() then
			return
		end

		self:HandleExecutionBroadcast(fields, senderName)
	elseif messageType == "EXEC_FINT" then
		if senderName == self:GetPlayerName() then
			return
		end

		self:HandleFintBroadcast(fields, senderName)
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
	self.stateTicker = CreateFrame("Frame")
	self.stateTicker:SetScript("OnUpdate", function(_, elapsed)
		self:OnStateTickerUpdate(elapsed)
	end)

	self:UpdateRoleText()
	self:RefreshTargetFrame()
	self:UpdateCooldownVisuals()
end

SS13:Initialize()
