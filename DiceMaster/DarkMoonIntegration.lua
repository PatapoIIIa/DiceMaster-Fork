-------------------------------------------------------------------------------
-- Dice Master (C) 2026 <The League of Lordaeron> - Moon Guard
-------------------------------------------------------------------------------

-- DarkMoon server integration.
-- Keeps a standalone tracker for server-spawned NPCs inside Dungeon Manager.

local Me = DiceMaster4

if not Me then
	return
end

local BackdropTemplateType = BackdropTemplateMixin and "BackdropTemplate" or nil
local SecureBackdropTemplate = BackdropTemplateType and "SecureActionButtonTemplate,BackdropTemplate" or "SecureActionButtonTemplate"

local ROW_HEIGHT = 30
local ROW_GAP = 4
local MIN_VISIBLE_ROWS = 4
local MAX_VISIBLE_ROWS = 12
local MAX_NAMEPLATES = 40
local LOST_TRACK_TTL = 5
local MANUAL_CAPTURE_TIMEOUT = 30
local ADD_PROBE_TIMEOUT = 8
local DELETE_RECONCILE_TIMEOUT = 8
local AUTO_DISCOVERY_TIMEOUT = 2
local AUTO_ASSIGN_RADIUS = 4
local MAX_PROBE_LINES = 6
local DEFAULT_FRAME_WIDTH = 338
local DEFAULT_FRAME_HEIGHT = 384

local RADAR_NAMEPLATE_CVARS = {
	"nameplateShowFriends",
	"nameplateShowFriendlyNPCs",
	"nameplateShowEnemies",
	"nameplateShowEnemyNPCs",
}

local SOURCE_PRIORITY = {
	focus = 100,
	target = 90,
	mouseover = 80,
}

for index = 1, 5 do
	SOURCE_PRIORITY["boss" .. index] = 70 - index
end

for index = 1, MAX_NAMEPLATES do
	SOURCE_PRIORITY["nameplate" .. index] = 40
end

local Integration = Me.DarkMoonIntegration or {}
Me.DarkMoonIntegration = Integration

-------------------------------------------------------------------------------
-- Helpers.
-------------------------------------------------------------------------------

local function TranslateText(text)
	if type(text) ~= "string" or text == "" then
		return text
	end

	if Me and Me.TranslateText then
		return Me.TranslateText(text)
	end

	return text
end

local function L(key, ...)
	local translated = TranslateText(key)

	if select("#", ...) > 0 then
		return translated:format(...)
	end

	return translated
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

local function Clamp(value, minValue, maxValue)
	if value < minValue then
		return minValue
	end

	if value > maxValue then
		return maxValue
	end

	return value
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

local function GetGUIDLowFromGUID(guid)
	if not guid then
		return nil
	end

	local _, _, _, _, _, _, guidLow = strsplit("-", guid)

	return guidLow
end

local function GetSpawnIDFromGUID(guid)
	local guidLow = GetGUIDLowFromGUID(guid)

	if not guidLow then
		return nil
	end

	return tonumber(guidLow, 16)
end

local function GetMapIDFromGUID(guid)
	if not guid then
		return nil
	end

	local parts = { strsplit("-", guid) }

	if #parts < 5 then
		return nil
	end

	return tonumber(parts[#parts - 4])
end

local function GetZoneIDFromGUID(guid)
	if not guid then
		return nil
	end

	local parts = { strsplit("-", guid) }

	if #parts < 3 then
		return nil
	end

	return tonumber(parts[#parts - 2])
end

local function CaptureUnitMetadata(unit, target)
	if not unit or not UnitExists(unit) then
		return
	end

	target.displayID = target.displayID or (UnitDisplayID and UnitDisplayID(unit) or nil)
	target.creatureType = target.creatureType or UnitCreatureType(unit)

	local getPosition = GetUnitPosition or UnitPosition

	if getPosition then
		local y, x, _, z = getPosition(unit)

		if x and y then
			target.positionX = x
			target.positionY = y
			target.positionZ = z
		end
	end
end

local function BuildSelectionKey(prefix, value)
	if value == nil then
		return nil
	end

	return tostring(prefix) .. ":" .. tostring(value)
end

local function GetUnitTypeFromGUID(guid)
	if not guid then
		return nil
	end

	return strsplit("-", guid)
end

local function CopyFields(source, target)
	if not source then
		return
	end

	for key, value in pairs(source) do
		target[key] = value
	end
end

local function ShallowCopyValue(value)
	if type(value) ~= "table" then
		return value
	end

	local copy = {}

	for key, nestedValue in pairs(value) do
		copy[key] = nestedValue
	end

	return copy
end

local function CopyMissingFields(source, target, ignoredKeys)
	if not source then
		return
	end

	for key, value in pairs(source) do
		if not (ignoredKeys and ignoredKeys[key]) and target[key] == nil then
			target[key] = ShallowCopyValue(value)
		end
	end
end

local function NormalizeSystemMessage(text)
	if type(text) ~= "string" or text == "" then
		return ""
	end

	text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
	text = text:gsub("|r", "")
	text = text:gsub("|H.-|h(.-)|h", "%1")
	text = text:gsub("|T.-|t", "")
	text = text:gsub("|n", "\n")
	text = text:gsub("%s+$", "")

	return text
end

local function NormalizeOutgoingCommand(text)
	if type(text) ~= "string" then
		return ""
	end

	text = text:gsub("^%s+", "")
	text = text:gsub("%s+$", "")
	text = text:gsub("%s+", " ")

	return text
end

local function ParseNpcCountLine(line)
	if type(line) ~= "string" then
		return nil, nil
	end

	local count, limit = line:match("^NPC:%s*(%d+)%s*/%s*(%d+)$")

	if not count then
		return nil, nil
	end

	return tonumber(count), tonumber(limit)
end

local function GetUnitDistanceFromPlayer(unit)
	local playerY, playerX, _, playerInstance = UnitPosition("player")
	local unitY, unitX, _, unitInstance = UnitPosition(unit)

	if not playerInstance or not unitInstance or playerInstance ~= unitInstance then
		return nil
	end

	local deltaX = unitX - playerX
	local deltaY = unitY - playerY

	return math.sqrt((deltaX * deltaX) + (deltaY * deltaY))
end

local PENDING_TRANSFER_IGNORED_KEYS = {
	guid = true,
	pendingID = true,
	isPending = true,
	isRegistered = true,
	isStale = true,
	canTarget = true,
	isCurrentTarget = true,
	displayToken = true,
	targetToken = true,
	sourceLabel = true,
	statusText = true,
	reasonText = true,
}

local EXCLUDED_DEBUG_FIELDS = {
	mapID = true,
	zoneID = true,
}

-------------------------------------------------------------------------------
-- Public registration API for future DarkMoon server command bindings.
-------------------------------------------------------------------------------

function Integration:EnsureCallbacks()
	self.callbacks = self.callbacks or {}
end

function Integration:Dispatch(eventName, ...)
	if not eventName then
		return
	end

	self:EnsureCallbacks()

	local callbackBucket = self.callbacks[eventName]

	if not callbackBucket then
		return
	end

	for owner, callback in pairs(callbackBucket) do
		local ok, err = pcall(callback, owner, eventName, ...)

		if not ok and geterrorhandler then
			geterrorhandler()(err)
		end
	end
end

function Integration:RegisterCallback(eventName, owner, callback)
	if type(owner) == "function" and callback == nil then
		callback = owner
		owner = callback
	end

	if type(callback) ~= "function" then
		return
	end

	self:EnsureCallbacks()
	self.callbacks[eventName] = self.callbacks[eventName] or {}
	self.callbacks[eventName][owner or callback] = callback
end

function Integration:UnregisterCallback(eventName, owner)
	if not self.callbacks or not self.callbacks[eventName] then
		return
	end

	self.callbacks[eventName][owner] = nil
end

function Integration:BuildSpawnIdentityPayload(entry)
	if not entry then
		return nil
	end

	return {
		guid = entry.isPending and nil or entry.guid,
		guidLow = entry.guidLow,
		pendingID = entry.pendingID,
		spawnID = entry.spawnID,
		npcID = entry.npcID,
		name = entry.name,
		fullName = entry.fullName,
		displayID = entry.displayID,
		creatureType = entry.creatureType,
		avatarID = entry.avatarID,
		avatarName = entry.avatarName,
		avatarType = entry.avatarType,
		avatarBindingSource = entry.avatarBindingSource,
		sourceCommand = entry.sourceCommand,
		resolvedBy = entry.resolvedBy,
		isPending = entry.isPending == true,
		isRegistered = entry.isRegistered == true,
	}
end

function Integration:GetSpawnIdentity(entryOrGUID)
	local entry = nil

	if type(entryOrGUID) == "table" then
		entry = entryOrGUID
	elseif entryOrGUID then
		entry = self:GetRegisteredSpawn(entryOrGUID) or self:GetTrackedEntry(entryOrGUID)
	end

	return self:BuildSpawnIdentityPayload(entry)
end

function Integration:GetSpawnIdentityBySpawnID(spawnID)
	if not spawnID then
		return nil
	end

	return self:BuildSpawnIdentityPayload(self:GetRegisteredSpawnBySpawnID(spawnID) or { spawnID = spawnID })
end

function Integration:EnsureAvatarBindings()
	self.avatarBindingsByGUID = self.avatarBindingsByGUID or {}
	self.avatarBindingsBySpawnID = self.avatarBindingsBySpawnID or {}
end

function Integration:BuildAvatarBindingRecord(avatarID, avatarData, bindingSource)
	local binding = {
		avatarID = avatarID,
		bindingSource = bindingSource,
	}

	if avatarData then
		CopyFields(avatarData, binding)
	end

	return binding
end

function Integration:ApplyAvatarBinding(entry)
	if not entry then
		return
	end

	self:EnsureAvatarBindings()

	local binding = nil

	if entry.spawnID then
		binding = self.avatarBindingsBySpawnID[tostring(entry.spawnID)]
	end

	if not binding and entry.guid then
		binding = self.avatarBindingsByGUID[entry.guid]
	end

	entry.avatarID = binding and binding.avatarID or nil
	entry.avatarName = binding and binding.avatarName or nil
	entry.avatarType = binding and binding.avatarType or nil
	entry.avatarData = binding and ShallowCopyValue(binding.avatarData) or nil
	entry.avatarBindingSource = binding and binding.bindingSource or nil
end

function Integration:BindSpawnToAvatarByGUID(guid, avatarID, avatarData)
	if not guid or not avatarID then
		return nil
	end

	self:EnsureAvatarBindings()
	self.avatarBindingsByGUID[guid] = self:BuildAvatarBindingRecord(avatarID, avatarData, "guid")
	self:RequestRebuild()
	self:Dispatch("SPAWN_AVATAR_BOUND", self:GetSpawnIdentity(guid) or self:BuildSpawnIdentityPayload({ guid = guid }), ShallowCopyValue(self.avatarBindingsByGUID[guid]))

	return self.avatarBindingsByGUID[guid]
end

function Integration:BindSpawnToAvatarBySpawnID(spawnID, avatarID, avatarData)
	if not spawnID or not avatarID then
		return nil
	end

	self:EnsureAvatarBindings()
	self.avatarBindingsBySpawnID[tostring(spawnID)] = self:BuildAvatarBindingRecord(avatarID, avatarData, "spawnID")
	self:RequestRebuild()
	self:Dispatch("SPAWN_AVATAR_BOUND", self:GetSpawnIdentityBySpawnID(spawnID), ShallowCopyValue(self.avatarBindingsBySpawnID[tostring(spawnID)]))

	return self.avatarBindingsBySpawnID[tostring(spawnID)]
end

function Integration:BindSpawnToAvatar(entryOrGUID, avatarID, avatarData)
	if type(entryOrGUID) == "table" then
		if entryOrGUID.spawnID then
			return self:BindSpawnToAvatarBySpawnID(entryOrGUID.spawnID, avatarID, avatarData)
		end

		return self:BindSpawnToAvatarByGUID(entryOrGUID.guid, avatarID, avatarData)
	end

	return self:BindSpawnToAvatarByGUID(entryOrGUID, avatarID, avatarData)
end

function Integration:GetAvatarBindingForSpawn(entryOrGUID, spawnID)
	self:EnsureAvatarBindings()

	local guid = nil
	local resolvedSpawnID = spawnID

	if type(entryOrGUID) == "table" then
		guid = entryOrGUID.guid
		resolvedSpawnID = resolvedSpawnID or entryOrGUID.spawnID
	else
		guid = entryOrGUID
	end

	if resolvedSpawnID then
		local binding = self.avatarBindingsBySpawnID[tostring(resolvedSpawnID)]

		if binding then
			return binding
		end
	end

	if guid then
		return self.avatarBindingsByGUID[guid]
	end

	return nil
end

function Integration:UnbindSpawnAvatarByGUID(guid)
	if not guid or not self.avatarBindingsByGUID then
		return
	end

	local removedBinding = self.avatarBindingsByGUID[guid]
	self.avatarBindingsByGUID[guid] = nil
	self:RequestRebuild()
	self:Dispatch("SPAWN_AVATAR_UNBOUND", self:GetSpawnIdentity(guid) or self:BuildSpawnIdentityPayload({ guid = guid }), ShallowCopyValue(removedBinding))
end

function Integration:UnbindSpawnAvatarBySpawnID(spawnID)
	if not spawnID or not self.avatarBindingsBySpawnID then
		return
	end

	local removedBinding = self.avatarBindingsBySpawnID[tostring(spawnID)]
	self.avatarBindingsBySpawnID[tostring(spawnID)] = nil
	self:RequestRebuild()
	self:Dispatch("SPAWN_AVATAR_UNBOUND", self:GetSpawnIdentityBySpawnID(spawnID), ShallowCopyValue(removedBinding))
end

function Integration:RegisterServerSpawn(guid, data)
	if not guid then
		return
	end

	self.serverSpawnsByGUID = self.serverSpawnsByGUID or {}
	self.serverSpawnsBySpawnID = self.serverSpawnsBySpawnID or {}
	local isNewEntry = self.serverSpawnsByGUID[guid] == nil
	local pendingContext = nil
	local previousSelectionKey = self.selectedEntryKey

	if isNewEntry then
		if data and data.pendingID then
			pendingContext = self:TakePendingSpawnByPredicate(function(entry)
				return entry.pendingID == data.pendingID
			end)
		end

		if not pendingContext then
			pendingContext = self:ConsumePendingSpawn((data and data.npcID) or GetNPCIDFromGUID(guid))
		end
	end

	local entry = self.serverSpawnsByGUID[guid] or {}
	CopyMissingFields(pendingContext, entry, PENDING_TRANSFER_IGNORED_KEYS)
	CopyFields(data, entry)
	entry.guid = guid
	entry.npcID = entry.npcID or GetNPCIDFromGUID(guid)
	entry.guidLow = entry.guidLow or entry.spawnUID or GetGUIDLowFromGUID(guid)
	entry.spawnID = entry.spawnID or GetSpawnIDFromGUID(guid)
	entry.mapID = nil
	entry.zoneID = nil
	entry.spawnUID = nil
	entry.registeredAt = entry.registeredAt or GetTime()
	self:ApplyAvatarBinding(entry)

	if entry.spawnID then
		local existingGUID = self.serverSpawnsBySpawnID[tostring(entry.spawnID)]

		if existingGUID and existingGUID ~= guid then
			self.serverSpawnsByGUID[existingGUID] = nil
		end
	end

	self.serverSpawnsByGUID[guid] = entry

	if entry.spawnID then
		self.serverSpawnsBySpawnID[tostring(entry.spawnID)] = guid
	end

	if pendingContext and pendingContext.pendingID and previousSelectionKey == BuildSelectionKey("pending", pendingContext.pendingID) then
		self.selectedEntryKey = BuildSelectionKey("guid", guid)
	end

	self:Dispatch(isNewEntry and "SPAWN_REGISTERED" or "SPAWN_UPDATED", self:BuildSpawnIdentityPayload(entry), ShallowCopyValue(entry), pendingContext and self:BuildSpawnIdentityPayload(pendingContext) or nil)
	self:RequestRebuild()
end

function Integration:GetRegisteredSpawn(guid)
	if not guid or not self.serverSpawnsByGUID then
		return nil
	end

	return self.serverSpawnsByGUID[guid]
end

function Integration:IsRegisteredSpawn(guid)
	return self:GetRegisteredSpawn(guid) ~= nil
end

function Integration:GetRegisteredSpawnBySpawnID(spawnID)
	if not spawnID or not self.serverSpawnsByGUID or not self.serverSpawnsBySpawnID then
		return nil
	end

	local guid = self.serverSpawnsBySpawnID[tostring(spawnID)]

	if not guid then
		return nil
	end

	return self.serverSpawnsByGUID[guid]
end

function Integration:GetTrackedEntry(guid)
	if not guid or not self.entriesByGUID then
		return nil
	end

	return self.entriesByGUID[guid]
end

function Integration:IsTrackedSpawnVisible(guid)
	local entry = self:GetTrackedEntry(guid)

	if not entry then
		return false, nil
	end

	return not entry.isStale, entry
end

function Integration:UnregisterServerSpawn(guid)
	if not guid or not self.serverSpawnsByGUID or not self.serverSpawnsByGUID[guid] then
		return
	end

	local entry = self.serverSpawnsByGUID[guid]
	local payload = self:BuildSpawnIdentityPayload(entry)

	if entry and entry.spawnID and self.serverSpawnsBySpawnID then
		self.serverSpawnsBySpawnID[tostring(entry.spawnID)] = nil
	end

	self.serverSpawnsByGUID[guid] = nil
	if self.selectedEntryKey == BuildSelectionKey("guid", guid) then
		self.selectedEntryKey = nil
	end
	self:Dispatch("SPAWN_UNREGISTERED", payload, ShallowCopyValue(entry))
	self:RequestRebuild()
end

function Integration:ClearServerSpawns()
	self.serverSpawnsByGUID = {}
	self.serverSpawnsBySpawnID = {}
	self.entriesByGUID = {}
	self.pendingSpawns = {}
	self.selectedEntryKey = nil
	self.deleteReconcile = nil
	self:RefreshDungeonManager()
end

function Integration:ResetTrackedState(statusMessage)
	if self.autoDiscovery and self.autoDiscovery.savedNameplateCVars then
		self:RestoreRadarNameplates()
	end

	self.serverSpawnsByGUID = {}
	self.serverSpawnsBySpawnID = {}
	self.entriesByGUID = {}
	self.pendingSpawns = {}
	self.selectedEntryKey = nil
	self.addCommandProbe = nil
	self.autoDiscovery = nil
	self.pendingNpcInfo = nil
	self.manualCaptureExpiresAt = nil
	self.deleteReconcile = nil
	self.observedNpcCount = nil
	self.observedNpcLimit = nil
	self.observedNpcCountAt = nil

	if statusMessage then
		self:SetStatusMessage(statusMessage, 4)
	end

	self:RefreshDungeonManager()
end

function Integration:SetUnitFilter(filterFunc)
	self.unitFilter = filterFunc
	self:RequestRebuild()
end

function Integration:HasRegisteredSpawns()
	return self.serverSpawnsByGUID and next(self.serverSpawnsByGUID) ~= nil
end

function Integration:GetRegisteredSpawnCount()
	if not self.serverSpawnsByGUID then
		return 0
	end

	local count = 0

	for _ in pairs(self.serverSpawnsByGUID) do
		count = count + 1
	end

	return count
end

function Integration:GetIgnoredGUIDs()
	self.ignoredGUIDs = self.ignoredGUIDs or {}

	return self.ignoredGUIDs
end

function Integration:GetPendingSpawns()
	self.pendingSpawns = self.pendingSpawns or {}

	return self.pendingSpawns
end

function Integration:GetPendingSpawnCount()
	return #self:GetPendingSpawns()
end

function Integration:GetNextPendingSpawnID()
	self.pendingSpawnSerial = (self.pendingSpawnSerial or 0) + 1

	return "pending:" .. tostring(self.pendingSpawnSerial)
end

function Integration:AddPendingSpawns(count, data)
	if not count or count <= 0 then
		return
	end

	local pendingSpawns = self:GetPendingSpawns()
	local lastAdded = nil

	for _ = 1, count do
		local entry = {}
		CopyFields(data, entry)
		entry.pendingID = self:GetNextPendingSpawnID()
		entry.guid = entry.pendingID
		entry.isPending = true
		entry.createdAt = GetTime()
		entry.name = entry.name or (entry.npcID and L("NPC %s", entry.npcID) or L("Pending spawn"))
		entry.fullName = entry.fullName or entry.name

		pendingSpawns[#pendingSpawns + 1] = entry
		lastAdded = entry
		self:Dispatch("PENDING_SPAWN_ADDED", self:BuildSpawnIdentityPayload(entry), ShallowCopyValue(entry))
	end

	if lastAdded and not self.selectedEntryKey then
		self:SelectEntry(lastAdded)
	end
end

function Integration:ConsumePendingSpawn(npcID)
	local pendingSpawns = self:GetPendingSpawns()
	local fallbackIndex = nil

	for index, entry in ipairs(pendingSpawns) do
		if not fallbackIndex then
			fallbackIndex = index
		end

		if npcID and entry.npcID == npcID then
			return table.remove(pendingSpawns, index)
		end
	end

	if fallbackIndex then
		return table.remove(pendingSpawns, fallbackIndex)
	end

	return nil
end

function Integration:RemovePendingSpawn(pendingID)
	if not pendingID then
		return
	end

	local pendingSpawns = self:GetPendingSpawns()

	for index, entry in ipairs(pendingSpawns) do
		if entry.pendingID == pendingID then
			table.remove(pendingSpawns, index)
			if self.selectedEntryKey == BuildSelectionKey("pending", pendingID) then
				self.selectedEntryKey = nil
			end
			self:Dispatch("PENDING_SPAWN_REMOVED", self:BuildSpawnIdentityPayload(entry), ShallowCopyValue(entry))
			self:SetStatusMessage(L("Removed unresolved spawn placeholder."), 4)
			self:RefreshDungeonManagerView()
			return
		end
	end
end

function Integration:RemovePendingSpawnsBySpawnID(spawnID)
	if not spawnID then
		return false
	end

	local removed = false
	local pendingSpawns = self:GetPendingSpawns()

	for index = #pendingSpawns, 1, -1 do
		if pendingSpawns[index].spawnID == spawnID then
			local entry = pendingSpawns[index]
			table.remove(pendingSpawns, index)
			if self.selectedEntryKey == BuildSelectionKey("pending", entry.pendingID) then
				self.selectedEntryKey = nil
			end
			self:Dispatch("PENDING_SPAWN_REMOVED", self:BuildSpawnIdentityPayload(entry), ShallowCopyValue(entry))
			removed = true
		end
	end

	if removed then
		self:RefreshDungeonManagerView()
	end

	return removed
end

function Integration:RemoveTrackedSpawnBySpawnID(spawnID)
	if not spawnID then
		return false
	end

	local removed = false
	local trackedEntry = self:GetRegisteredSpawnBySpawnID(spawnID)

	if trackedEntry then
		self:UnregisterServerSpawn(trackedEntry.guid)
		removed = true
	end

	if self:RemovePendingSpawnsBySpawnID(spawnID) then
		removed = true
	end

	return removed
end

function Integration:RemoveTrackedTargetSpawn()
	local targetGUID = UnitGUID("target")

	if targetGUID and self:IsRegisteredSpawn(targetGUID) then
		self:UnregisterServerSpawn(targetGUID)
		return true
	end

	local targetEntry = targetGUID and self:GetTrackedEntry(targetGUID) or nil

	if targetEntry and targetEntry.spawnID then
		return self:RemoveTrackedSpawnBySpawnID(targetEntry.spawnID)
	end

	return false
end

function Integration:GetEntrySelectionKey(entry)
	if not entry then
		return nil
	end

	if entry.pendingID then
		return BuildSelectionKey("pending", entry.pendingID)
	end

	if entry.guid then
		return BuildSelectionKey("guid", entry.guid)
	end

	return nil
end

function Integration:IsSelectedEntry(entry)
	return self.selectedEntryKey ~= nil and self.selectedEntryKey == self:GetEntrySelectionKey(entry)
end

function Integration:SelectEntry(entry)
	self.selectedEntryKey = self:GetEntrySelectionKey(entry)
	self:Dispatch("SPAWN_SELECTED", self:BuildSpawnIdentityPayload(entry), ShallowCopyValue(entry))
end

function Integration:GetSelectedEntry()
	if not self.selectedEntryKey then
		return nil
	end

	for _, entry in ipairs(self:GetTrackedEntries()) do
		if self:IsSelectedEntry(entry) then
			return entry
		end
	end

	return nil
end

function Integration:FindPendingResolutionEntry(npcID)
	local selectedEntry = self:GetSelectedEntry()

	if selectedEntry and selectedEntry.isPending and selectedEntry.npcID == npcID then
		return selectedEntry
	end

	local matchingEntries = {}

	for _, entry in ipairs(self:GetPendingSpawns()) do
		if not npcID or entry.npcID == npcID then
			matchingEntries[#matchingEntries + 1] = entry
		end
	end

	if #matchingEntries == 1 then
		return matchingEntries[1]
	end

	return nil
end

function Integration:TryResolvePendingFromGUID(guid, fullName, sourceLabel)
	if not guid or self:GetPendingSpawnCount() <= 0 then
		return false
	end

	local unitType = GetUnitTypeFromGUID(guid)

	if (unitType ~= "Creature" and unitType ~= "Vehicle") or self:IsIgnoredGUID(guid) or self:IsRegisteredSpawn(guid) then
		return false
	end

	local npcID = GetNPCIDFromGUID(guid)
	local pendingEntry = self:FindPendingResolutionEntry(npcID)

	if not pendingEntry then
		return false
	end

	self:RegisterServerSpawn(guid, {
		pendingID = pendingEntry.pendingID,
		npcID = npcID,
		name = ShortName(fullName) or pendingEntry.name,
		fullName = fullName or pendingEntry.fullName,
		resolvedBy = sourceLabel,
		resolvedAt = GetTime(),
		resolvedFromPending = true,
	})
	self:SetStatusMessage(L("Resolved a pending spawn GUID from %s.", sourceLabel), 4)
	return true
end

function Integration:TryResolvePendingFromUnit(unit, sourceLabel)
	if not unit or not UnitExists(unit) or self:GetPendingSpawnCount() <= 0 then
		return false
	end

	local guid = UnitGUID(unit)
	local fullName = GetUnitName(unit, true) or UnitName(unit)
	local resolvedData = {}
	CaptureUnitMetadata(unit, resolvedData)

	if not guid then
		return false
	end

	resolvedData.name = ShortName(fullName)
	resolvedData.fullName = fullName
	resolvedData.resolvedBy = sourceLabel
	resolvedData.resolvedAt = GetTime()
	resolvedData.resolvedFromPending = true

	local pendingEntry = self:FindPendingResolutionEntry(GetNPCIDFromGUID(guid))

	if not pendingEntry then
		return false
	end

	resolvedData.pendingID = pendingEntry.pendingID
	resolvedData.npcID = GetNPCIDFromGUID(guid)
	self:RegisterServerSpawn(guid, resolvedData)
	self:SetStatusMessage(L("Resolved a pending spawn GUID from %s.", sourceLabel), 4)
	return true
end

function Integration:HandleCombatLogEvent()
	if self:GetPendingSpawnCount() <= 0 or not CombatLogGetCurrentEventInfo then
		return
	end

	local _, _, _, sourceGUID, sourceName, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()

	if self:TryResolvePendingFromGUID(sourceGUID, sourceName, "combat log source") then
		return
	end

	self:TryResolvePendingFromGUID(destGUID, destName, "combat log target")
end

function Integration:TryTargetEntry(entry)
	if not entry then
		return false
	end

	if entry.isCurrentTarget then
		self:SetStatusMessage(L("This spawn is already your current target."), 3)
		return true
	end

	local token = entry.targetToken

	if not token and entry.displayToken and entry.displayToken ~= "mouseover" and entry.displayToken ~= "target" then
		token = entry.displayToken
	end

	if token and UnitExists(token) then
		TargetUnit(token)
		return true
	end

	self:SetStatusMessage(L("Cannot target this spawn: WoW exposed no reusable live unit token."), 4)
	return false
end

function Integration:TakePendingSpawnByPredicate(predicate)
	if type(predicate) ~= "function" then
		return nil
	end

	local pendingSpawns = self:GetPendingSpawns()

	for index, entry in ipairs(pendingSpawns) do
		if predicate(entry) then
			table.remove(pendingSpawns, index)
			if self.selectedEntryKey == BuildSelectionKey("pending", entry.pendingID) then
				self.selectedEntryKey = nil
			end
			self:Dispatch("PENDING_SPAWN_CONSUMED", self:BuildSpawnIdentityPayload(entry), ShallowCopyValue(entry))
			return entry
		end
	end

	return nil
end

function Integration:BeginDeleteReconcile(commandText)
	local targetGUID = UnitGUID("target")
	local selectedEntry = self:GetSelectedEntry()

	self.deleteReconcile = {
		command = commandText,
		startedAt = GetTime(),
		expiresAt = GetTime() + DELETE_RECONCILE_TIMEOUT,
		baselineObservedCount = self.observedNpcCount,
		targetGUID = targetGUID,
		targetNPCID = GetNPCIDFromGUID(targetGUID),
		targetName = targetGUID and (GetUnitName("target", true) or UnitName("target")) or nil,
		selectedEntryKey = self.selectedEntryKey,
		selectedPendingID = selectedEntry and selectedEntry.isPending and selectedEntry.pendingID or nil,
		selectedNPCID = selectedEntry and selectedEntry.npcID or nil,
	}
end

function Integration:IsDeleteReconcileActive()
	return self.deleteReconcile and self.deleteReconcile.expiresAt and self.deleteReconcile.expiresAt > GetTime()
end

function Integration:FinalizeDeleteReconcile(message)
	self.deleteReconcile = nil

	if message then
		self:SetStatusMessage(message, 4)
	end

	self:RefreshDungeonManagerView()
end

function Integration:ApplyDeleteReconcileRemoval(toRemove, finalizeMessage)
	local state = self.deleteReconcile

	if not state or not toRemove or toRemove <= 0 then
		return 0
	end

	local removed = 0

	if state.targetGUID and self:IsRegisteredSpawn(state.targetGUID) and removed < toRemove then
		self:UnregisterServerSpawn(state.targetGUID)
		state.targetGUID = nil
		removed = removed + 1
	end

	if state.selectedPendingID and removed < toRemove then
		local removedEntry = self:TakePendingSpawnByPredicate(function(entry)
			return entry.pendingID == state.selectedPendingID
		end)

		if removedEntry then
			state.selectedPendingID = nil
			removed = removed + 1
		end
	end

	local preferredNPCID = state.targetNPCID or state.selectedNPCID

	while preferredNPCID and removed < toRemove do
		local removedEntry = self:TakePendingSpawnByPredicate(function(entry)
			return entry.npcID == preferredNPCID
		end)

		if not removedEntry then
			break
		end

		removed = removed + 1
	end

	while removed < toRemove do
		local removedEntry = self:TakePendingSpawnByPredicate(function()
			return true
		end)

		if not removedEntry then
			break
		end

		removed = removed + 1
	end

	if removed > 0 then
		if finalizeMessage then
			self:FinalizeDeleteReconcile(finalizeMessage(toRemove, removed))
		else
			self:RefreshDungeonManagerView()
		end
	end

	return removed
end

function Integration:ReconcileDeleteCountDrop(count)
	local state = self.deleteReconcile

	if not state then
		return false
	end

	local baselineCount = state.baselineObservedCount

	if baselineCount == nil or count >= baselineCount then
		return false
	end

	local toRemove = baselineCount - count
	local removed = self:ApplyDeleteReconcileRemoval(toRemove, function(expected, actual)
		return L("NPC count dropped by %d. Reconciled %d tracked spawn(s).", expected, actual)
	end)

	return removed > 0
end

function Integration:ConsumeServerRemovalLine(line)
	if line ~= "Creature Removed" and line ~= "Creature Removed." then
		return false
	end

	if not self:IsDeleteReconcileActive() then
		return false
	end

	local removed = self:ApplyDeleteReconcileRemoval(1, function(_, actual)
		return L("Server confirmed creature removal. Reconciled %d tracked spawn.", actual)
	end)

	return removed > 0
end

function Integration:IsIgnoredGUID(guid)
	return guid and self:GetIgnoredGUIDs()[guid] == true
end

function Integration:IgnoreSpawn(entryOrGUID)
	local guid = type(entryOrGUID) == "table" and entryOrGUID.guid or entryOrGUID

	if not guid then
		return
	end

	local ignoredGUIDs = self:GetIgnoredGUIDs()
	ignoredGUIDs[guid] = true

	if self.autoDiscovery and self.autoDiscovery.assignedGUIDs then
		self.autoDiscovery.assignedGUIDs[guid] = nil
	end

	self:UnregisterServerSpawn(guid)
	self:SetStatusMessage(L("Added spawn to ignore list."), 4)
end

-------------------------------------------------------------------------------
-- Tracking.
-------------------------------------------------------------------------------

function Integration:IsPotentialNpcUnit(unit)
	if not unit or not UnitExists(unit) or UnitIsPlayer(unit) or UnitPlayerControlled(unit) then
		return false
	end

	local guid = UnitGUID(unit)
	local unitType = GetUnitTypeFromGUID(guid)

	if self:IsIgnoredGUID(guid) then
		return false
	end

	if unitType ~= "Creature" and unitType ~= "Vehicle" and unitType ~= "Pet" then
		return false
	end

	if self.unitFilter and not self.unitFilter(unit) then
		return false
	end

	return true
end

function Integration:GetScanTokens()
	local tokens = {
		"target",
		"focus",
		"mouseover",
	}

	for index = 1, 5 do
		tokens[#tokens + 1] = "boss" .. index
	end

	for index = 1, MAX_NAMEPLATES do
		tokens[#tokens + 1] = "nameplate" .. index
	end

	return tokens
end

function Integration:GetTokenPriority(token)
	return SOURCE_PRIORITY[token] or 0
end

function Integration:IsSecureTargetToken(token)
	if not token then
		return false
	end

	if token == "focus" then
		return true
	end

	if token:match("^boss%d+$") then
		return true
	end

	if token:match("^nameplate%d+$") then
		return true
	end

	return false
end

function Integration:GetTokenLabel(token)
	if not token then
		return L("unavailable")
	end

	if token == "focus" then
		return L("focus")
	end

	if token == "target" then
		return L("target")
	end

	if token == "mouseover" then
		return L("mouseover")
	end

	if token:match("^boss%d+$") then
		return L("boss frame")
	end

	if token:match("^nameplate%d+$") then
		return L("nameplate")
	end

	return token
end

function Integration:IsTrackableUnit(unit)
	if not self:IsPotentialNpcUnit(unit) then
		return false
	end

	if not self:HasRegisteredSpawns() then
		return false
	end

	local guid = UnitGUID(unit)

	return self.serverSpawnsByGUID[guid] ~= nil
end

function Integration:BuildEntry(guid, unit, previousEntry, now, seedData)
	local entry = previousEntry or {}

	if seedData then
		CopyFields(seedData, entry)
	end

	entry.guid = guid
	entry.npcID = entry.npcID or GetNPCIDFromGUID(guid)
	entry.guidLow = entry.guidLow or entry.spawnUID or GetGUIDLowFromGUID(guid)
	entry.spawnID = entry.spawnID or GetSpawnIDFromGUID(guid)
	entry.mapID = nil
	entry.zoneID = nil
	entry.spawnUID = nil
	entry.firstSeen = entry.firstSeen or now
	entry.lastSeen = previousEntry and previousEntry.lastSeen or nil
	entry.displayToken = nil
	entry.targetToken = nil
	entry.sourceLabel = nil
	entry.isRegistered = seedData ~= nil
	entry.isStale = false
	entry.canTarget = false
	entry.isCurrentTarget = false
	entry.statusText = nil
	entry.reasonText = nil

	if unit then
		entry.name = ShortName(GetUnitName(unit, true) or UnitName(unit)) or entry.name or L("Unknown")
		entry.fullName = GetUnitName(unit, true) or UnitName(unit) or entry.fullName or entry.name
		CaptureUnitMetadata(unit, entry)
		entry.lastSeen = now
	else
		entry.name = entry.name or L("Unknown")
		entry.fullName = entry.fullName or entry.name
	end

	self:ApplyAvatarBinding(entry)

	return entry
end

function Integration:AssignUnitToken(entry, unit)
	local token = tostring(unit)

	if not entry.displayToken or self:GetTokenPriority(token) > self:GetTokenPriority(entry.displayToken) then
		entry.displayToken = token
		entry.sourceLabel = self:GetTokenLabel(token)
	end

	if self:IsSecureTargetToken(token) and (not entry.targetToken or self:GetTokenPriority(token) > self:GetTokenPriority(entry.targetToken)) then
		entry.targetToken = token
	end
end

function Integration:FinalizeEntry(entry)
	entry.isCurrentTarget = UnitGUID("target") == entry.guid
	entry.canTarget = entry.targetToken ~= nil

	if entry.isCurrentTarget then
		entry.statusText = L("Current target")
		entry.reasonText = L("This spawn is already your current target.")
	elseif entry.canTarget then
		entry.statusText = L("Click to target (%s)", entry.sourceLabel or self:GetTokenLabel(entry.targetToken))
		entry.reasonText = L("This spawn has a live %s token, so the tracker can target it.", entry.sourceLabel or self:GetTokenLabel(entry.targetToken))
	elseif entry.displayToken == "mouseover" then
		entry.statusText = L("Cannot target from tracker")
		entry.reasonText = L("The spawn is only known through mouseover. WoW secure targeting cannot reuse mouseover from this tracker.")
	elseif entry.displayToken == "target" then
		entry.statusText = L("Current target only")
		entry.reasonText = L("The spawn is only available as the current target token.")
	elseif entry.isRegistered then
		entry.statusText = L("GUID stored only")
		entry.reasonText = L("The spawn is confirmed and stored by GUID, but WoW is not exposing a reusable live unit token for it right now. The tracker cannot target it from the list.")
	elseif entry.isStale then
		entry.statusText = L("Cannot target: no live unit token")
		entry.reasonText = L("WoW does not allow addons to target remembered NPCs by GUID or name without a live unit token.")
	else
		entry.statusText = L("Cannot target from tracker")
		entry.reasonText = L("WoW does not expose a secure unit token for this spawn right now.")
	end
end

function Integration:FinalizePendingEntry(entry)
	entry.isPending = true
	entry.isRegistered = false
	entry.isStale = false
	entry.canTarget = false
	entry.isCurrentTarget = false
	entry.displayToken = nil
	entry.targetToken = nil
	entry.statusText = L("Server-confirmed spawn")
	entry.reasonText = L("The DarkMoon server count increased after .min npc add, so this spawn is tracked as yours. WoW has not exposed a GUID or reusable live unit token for it yet.")
end

function Integration:GetTrackedEntries()
	self.sortedEntries = self.sortedEntries or {}
	wipe(self.sortedEntries)

	if self.entriesByGUID then
		for _, entry in pairs(self.entriesByGUID) do
			self.sortedEntries[#self.sortedEntries + 1] = entry
		end
	end

	for _, pendingEntry in ipairs(self:GetPendingSpawns()) do
		self:FinalizePendingEntry(pendingEntry)
		self.sortedEntries[#self.sortedEntries + 1] = pendingEntry
	end

	table.sort(self.sortedEntries, function(left, right)
		if left.isCurrentTarget ~= right.isCurrentTarget then
			return left.isCurrentTarget
		end

		if left.canTarget ~= right.canTarget then
			return left.canTarget
		end

		if left.isPending ~= right.isPending then
			return not left.isPending
		end

		if left.isRegistered ~= right.isRegistered then
			return left.isRegistered
		end

		if left.isStale ~= right.isStale then
			return not left.isStale
		end

		local leftSeen = left.lastSeen or 0
		local rightSeen = right.lastSeen or 0

		if leftSeen ~= rightSeen then
			return leftSeen > rightSeen
		end

		local leftCreated = left.createdAt or left.registeredAt or 0
		local rightCreated = right.createdAt or right.registeredAt or 0

		if leftCreated ~= rightCreated then
			return leftCreated < rightCreated
		end

		return (left.name or "") < (right.name or "")
	end)

	return self.sortedEntries
end

-------------------------------------------------------------------------------
-- Dungeon Manager UI.
-------------------------------------------------------------------------------

function Integration:EnsureDungeonManagerAttached()
	if self.ui and self.ui.container then
		return true
	end

	if not DiceMasterDarkMoonTracker then
		return false
	end

	self:AttachToDungeonManager(DiceMasterDarkMoonTracker)
	return self.ui and self.ui.container ~= nil
end

function Integration:RefreshRow(button, entry)
	if not button then
		return
	end

	button.entry = entry

	if not entry then
		button:Hide()
		return
	end

	button:Show()
	button.NameText:SetText(entry.name or L("Unknown"))
	button.IgnoreButton:Show()

	local leftDetail = entry.npcID and ("NPC " .. tostring(entry.npcID)) or L("Unknown NPC")

	if entry.isPending then
		leftDetail = leftDetail .. "  |  " .. L("Pending GUID")
	end

	if entry.spawnID then
		leftDetail = leftDetail .. "  |  " .. L("SpawnID %s", entry.spawnID)
	elseif entry.guidLow then
		leftDetail = leftDetail .. "  |  " .. L("LowGUID %s", entry.guidLow)
	end
	button.DetailText:SetText(leftDetail .. "  |  " .. (entry.statusText or ""))

	if entry.isCurrentTarget then
		button.Status:SetVertexColor(0.95, 0.80, 0.24)
		button:SetBackdropColor(0.28, 0.20, 0.08, 0.92)
		button:SetBackdropBorderColor(0.95, 0.80, 0.24, 0.95)
	elseif entry.canTarget then
		button.Status:SetVertexColor(0.24, 0.85, 0.42)
		button:SetBackdropColor(0.08, 0.20, 0.12, 0.92)
		button:SetBackdropBorderColor(0.24, 0.85, 0.42, 0.95)
	elseif entry.isPending then
		button.Status:SetVertexColor(0.74, 0.64, 0.95)
		button:SetBackdropColor(0.14, 0.10, 0.22, 0.92)
		button:SetBackdropBorderColor(0.74, 0.64, 0.95, 0.95)
	elseif entry.isRegistered then
		button.Status:SetVertexColor(0.32, 0.64, 0.95)
		button:SetBackdropColor(0.08, 0.12, 0.22, 0.92)
		button:SetBackdropBorderColor(0.32, 0.64, 0.95, 0.95)
	elseif entry.isStale then
		button.Status:SetVertexColor(0.85, 0.28, 0.20)
		button:SetBackdropColor(0.20, 0.08, 0.08, 0.92)
		button:SetBackdropBorderColor(0.85, 0.28, 0.20, 0.95)
	else
		button.Status:SetVertexColor(0.90, 0.68, 0.20)
		button:SetBackdropColor(0.18, 0.15, 0.08, 0.92)
		button:SetBackdropBorderColor(0.90, 0.68, 0.20, 0.95)
	end

	if self:IsSelectedEntry(entry) then
		button.SelectionGlow:Show()
	else
		button.SelectionGlow:Hide()
	end

	if not InCombatLockdown() then
		button:SetAttribute("type1", nil)
		button:SetAttribute("unit", nil)

		if entry.canTarget and entry.targetToken then
			button:SetAttribute("type1", "target")
			button:SetAttribute("unit", entry.targetToken)
		end
	end
end

function Integration:IsManualCaptureActive()
	return self.manualCaptureExpiresAt and self.manualCaptureExpiresAt > GetTime()
end

function Integration:IsAddCommandProbeActive()
	return self.addCommandProbe and self.addCommandProbe.expiresAt and self.addCommandProbe.expiresAt > GetTime()
end

function Integration:SetStatusMessage(text, duration)
	self.statusMessage = text

	if duration and duration > 0 then
		self.statusMessageExpiresAt = GetTime() + duration
	else
		self.statusMessageExpiresAt = nil
	end
end

function Integration:StampProbeLines(commandText, lines)
	if not commandText or not lines then
		return
	end

	local snapshot = ShallowCopyValue(lines)

	for _, entry in ipairs(self:GetPendingSpawns()) do
		if entry.sourceCommand == commandText then
			entry.probeLines = ShallowCopyValue(snapshot)
			entry.probeSummary = table.concat(snapshot, " || ")
		end
	end

	if self.serverSpawnsByGUID then
		for _, entry in pairs(self.serverSpawnsByGUID) do
			if entry.sourceCommand == commandText then
				entry.probeLines = ShallowCopyValue(snapshot)
				entry.probeSummary = table.concat(snapshot, " || ")
			end
		end
	end
end

local DEBUG_FIELD_ORDER = {
	"name",
	"fullName",
	"guid",
	"guidLow",
	"pendingID",
	"npcID",
	"spawnID",
	"displayID",
	"creatureType",
	"positionX",
	"positionY",
	"positionZ",
	"avatarID",
	"avatarName",
	"avatarType",
	"avatarBindingSource",
	"avatarData",
	"level",
	"sourceCommand",
	"rawServerCountLine",
	"observedNpcCount",
	"observedNpcLimit",
	"probeSummary",
	"probeLines",
	"displayToken",
	"targetToken",
	"sourceLabel",
	"statusText",
	"reasonText",
	"autoDetected",
	"detectedBy",
	"distance",
	"isPending",
	"isRegistered",
	"isStale",
	"canTarget",
	"isCurrentTarget",
	"createdAt",
	"serverConfirmedAt",
	"registeredAt",
	"detectedAt",
	"firstSeen",
	"lastSeen",
}

local DEBUG_LABELS = {
	name = "name",
	fullName = "fullName",
	guid = "guid",
	guidLow = "guidLow",
	pendingID = "pendingID",
	npcID = "npcID",
	spawnID = "spawnID",
	displayID = "displayID",
	creatureType = "creatureType",
	positionX = "positionX",
	positionY = "positionY",
	positionZ = "positionZ",
	avatarID = "avatarID",
	avatarName = "avatarName",
	avatarType = "avatarType",
	avatarBindingSource = "avatarBindingSource",
	avatarData = "avatarData",
	level = "level",
	sourceCommand = "sourceCommand",
	rawServerCountLine = "rawServerCountLine",
	observedNpcCount = "observedNpcCount",
	observedNpcLimit = "observedNpcLimit",
	probeSummary = "probeSummary",
	probeLines = "probeLines",
	displayToken = "displayToken",
	targetToken = "targetToken",
	sourceLabel = "sourceLabel",
	statusText = "statusText",
	reasonText = "reasonText",
	autoDetected = "autoDetected",
	detectedBy = "detectedBy",
	distance = "distance",
	isPending = "isPending",
	isRegistered = "isRegistered",
	isStale = "isStale",
	canTarget = "canTarget",
	isCurrentTarget = "isCurrentTarget",
	createdAt = "createdAt",
	serverConfirmedAt = "serverConfirmedAt",
	registeredAt = "registeredAt",
	detectedAt = "detectedAt",
	firstSeen = "firstSeen",
	lastSeen = "lastSeen",
}

local function FormatDebugValue(value)
	local valueType = type(value)

	if valueType == "boolean" then
		return value and "true" or "false"
	end

	if valueType == "number" then
		return string.format("%.2f", value)
	end

	if valueType == "table" then
		local parts = {}

		for index, nestedValue in ipairs(value) do
			parts[#parts + 1] = tostring(nestedValue)
		end

		if #parts > 0 then
			return table.concat(parts, " || ")
		end

		local keyedParts = {}

		for key, nestedValue in pairs(value) do
			keyedParts[#keyedParts + 1] = tostring(key) .. "=" .. tostring(nestedValue)
		end

		table.sort(keyedParts)
		return table.concat(keyedParts, ", ")
	end

	return tostring(value)
end

function Integration:BuildEntryDebugText(entry)
	if not entry then
		return L("Select a tracked spawn to inspect all collected fields.")
	end

	local lines = {}
	local seen = {}

	for _, key in ipairs(DEBUG_FIELD_ORDER) do
		local value = entry[key]

		if value ~= nil then
			lines[#lines + 1] = (DEBUG_LABELS[key] or key) .. ": " .. FormatDebugValue(value)
			seen[key] = true
		end
	end

	local extraKeys = {}

	for key, value in pairs(entry) do
		if not seen[key] and not EXCLUDED_DEBUG_FIELDS[key] and type(value) ~= "function" then
			extraKeys[#extraKeys + 1] = key
		end
	end

	table.sort(extraKeys, function(left, right)
		return tostring(left) < tostring(right)
	end)

	for _, key in ipairs(extraKeys) do
		lines[#lines + 1] = tostring(key) .. ": " .. FormatDebugValue(entry[key])
	end

	return table.concat(lines, "|n")
end

function Integration:RefreshDetailsText(entry)
	if not self.ui or not self.ui.DetailsText then
		return
	end

	if entry then
		self.ui.DetailsTitle:SetText(L("Selected spawn details"))
	else
		self.ui.DetailsTitle:SetText(L("Spawn details"))
	end

	self.ui.DetailsText:SetText(self:BuildEntryDebugText(entry))
end

function Integration:RefreshStatusText()
	if not self.ui or not self.ui.StatusText then
		return
	end

	if self.statusMessageExpiresAt and self.statusMessageExpiresAt <= GetTime() then
		self.statusMessage = nil
		self.statusMessageExpiresAt = nil
	end

	local statusParts = {}
	local registeredCount = self:GetRegisteredSpawnCount()
	local pendingCount = self:GetPendingSpawnCount()

	statusParts[#statusParts + 1] = L("%d known GUIDs", registeredCount)

	if pendingCount > 0 then
		statusParts[#statusParts + 1] = L("%d unresolved spawn(s)", pendingCount)
	end

	if self.observedNpcCount and self.observedNpcLimit then
		statusParts[#statusParts + 1] = L("Observed NPCs %d/%d", self.observedNpcCount, self.observedNpcLimit)
	end

	if self:IsManualCaptureActive() then
		statusParts[#statusParts + 1] = L("Import armed: run .min npc info")
	end

	if self:IsAddCommandProbeActive() then
		statusParts[#statusParts + 1] = L("Probing .min npc add")
	end

	if self:IsDeleteReconcileActive() then
		statusParts[#statusParts + 1] = L("Reconciling .min npc del")
	end

	if self.autoDiscovery and self.autoDiscovery.expiresAt and self.autoDiscovery.expiresAt > GetTime() then
		statusParts[#statusParts + 1] = L("Auto-detecting nearby spawn")
	end

	if self.statusMessage then
		statusParts[#statusParts + 1] = self.statusMessage
	elseif registeredCount == 0 and self:GetPendingSpawnCount() == 0 then
		statusParts[#statusParts + 1] = L("Nearby NPCs are ignored until .min npc add confirms a new spawn.")
	end

	self.ui.StatusText:SetText(table.concat(statusParts, "  |  "))
end

function Integration:TrackServerConfirmedIncrease(state, previousCount, count)
	if not state then
		return
	end

	local baselineCount = state.baselineObservedCount

	if baselineCount == nil then
		baselineCount = previousCount

		if baselineCount == nil then
			baselineCount = math.max(count - 1, 0)
		end

		state.baselineObservedCount = baselineCount
	end

	if count <= baselineCount then
		return
	end

	state.expectedIncrease = count - baselineCount
	state.placeholdersCreated = state.placeholdersCreated or 0

	if self.autoDiscovery and self.autoDiscovery.command == state.command then
		self.autoDiscovery.expectedIncrease = state.expectedIncrease
	end

	local missingPlaceholders = state.expectedIncrease - state.placeholdersCreated

	if missingPlaceholders <= 0 then
		return
	end

	self:AddPendingSpawns(missingPlaceholders, {
		npcID = state.requestedNPCID,
		name = state.requestedNPCID and L("NPC %s", state.requestedNPCID) or L("Server-confirmed spawn"),
		fullName = state.requestedNPCID and L("NPC %s", state.requestedNPCID) or L("Server-confirmed spawn"),
		sourceCommand = state.command,
		rawServerCountLine = state.rawServerCountLine,
		observedNpcCount = count,
		observedNpcLimit = self.observedNpcLimit,
		serverConfirmedAt = GetTime(),
		probeLines = state.lines and ShallowCopyValue(state.lines) or nil,
		probeSummary = state.lines and table.concat(state.lines, " || ") or nil,
	})

	state.placeholdersCreated = state.placeholdersCreated + missingPlaceholders
	self:SetStatusMessage(L("Server confirmed %d new spawn(s).", state.expectedIncrease), 4)
	self:RefreshDungeonManagerView()
end

function Integration:ConsumeServerCountLine(line)
	local count, limit = ParseNpcCountLine(line)

	if not count then
		return false
	end

	local previousCount = self.observedNpcCount
	self.observedNpcCount = count
	self.observedNpcLimit = limit
	self.observedNpcCountAt = GetTime()

	if self:IsDeleteReconcileActive() and self:ReconcileDeleteCountDrop(count) then
		return true
	end

	if self:IsAddCommandProbeActive() and self.addCommandProbe and self.addCommandProbe.command then
		self.addCommandProbe.rawServerCountLine = line
		self:TrackServerConfirmedIncrease(self.addCommandProbe, previousCount, count)
	elseif self.autoDiscovery and self.autoDiscovery.expiresAt and self.autoDiscovery.command then
		self.autoDiscovery.rawServerCountLine = line
		self:TrackServerConfirmedIncrease(self.autoDiscovery, previousCount, count)
	end

	return true
end

function Integration:IsUnitNearPlayer(unit)
	local distance = GetUnitDistanceFromPlayer(unit)

	if distance then
		return distance <= AUTO_ASSIGN_RADIUS
	end

	local token = tostring(unit)

	return token:match("^nameplate%d+$") ~= nil or token == "mouseover" or token == "target"
end

function Integration:CaptureNearbyGUIDSnapshot()
	local snapshot = {}

	for _, unit in ipairs(self:GetScanTokens()) do
		if self:IsPotentialNpcUnit(unit) and self:IsUnitNearPlayer(unit) then
			local guid = UnitGUID(unit)

			if guid then
				snapshot[guid] = true
			end
		end
	end

	return snapshot
end

function Integration:GetAutoDiscoveryAssignedCount()
	if not self.autoDiscovery or not self.autoDiscovery.assignedGUIDs then
		return 0
	end

	local count = 0

	for _ in pairs(self.autoDiscovery.assignedGUIDs) do
		count = count + 1
	end

	return count
end

function Integration:BeginAutoDiscovery(commandText)
	self.autoDiscovery = {
		command = commandText,
		startedAt = GetTime(),
		expiresAt = GetTime() + AUTO_DISCOVERY_TIMEOUT,
		baselineGUIDs = self:CaptureNearbyGUIDSnapshot(),
		assignedGUIDs = {},
		baselineObservedCount = self.observedNpcCount,
		requestedNPCID = tonumber(commandText:match("^%.min npc add%s+(%d+)")),
		placeholdersCreated = 0,
	}

	self:EnableRadarNameplates()
end

function Integration:FinishAutoDiscovery(message)
	if not self.autoDiscovery then
		return
	end

	self:RestoreRadarNameplates()
	self.autoDiscovery.expiresAt = nil
	self.autoDiscovery.completedAt = GetTime()

	if message then
		self:SetStatusMessage(message, 4)
	end

	self:RefreshDungeonManagerView()
end

function Integration:EnableRadarNameplates()
	if not self.autoDiscovery or not GetCVar or not SetCVar then
		return
	end

	if self.autoDiscovery.savedNameplateCVars then
		return
	end

	self.autoDiscovery.savedNameplateCVars = {}

	for _, cvarName in ipairs(RADAR_NAMEPLATE_CVARS) do
		local currentValue = GetCVar(cvarName)

		if currentValue ~= nil and currentValue ~= "" then
			self.autoDiscovery.savedNameplateCVars[cvarName] = currentValue

			if currentValue ~= "1" then
				SetCVar(cvarName, "1")
			end
		end
	end
end

function Integration:RestoreRadarNameplates()
	if not self.autoDiscovery or not self.autoDiscovery.savedNameplateCVars or not SetCVar then
		return
	end

	for cvarName, value in pairs(self.autoDiscovery.savedNameplateCVars) do
		SetCVar(cvarName, value)
	end

	self.autoDiscovery.savedNameplateCVars = nil
end

function Integration:TryAutoRegisterNearbySpawns()
	if not self.autoDiscovery or not self.autoDiscovery.expiresAt or self.autoDiscovery.expiresAt <= GetTime() then
		return
	end

	local discoveredNow = 0
	local candidatesByGUID = {}

	for _, unit in ipairs(self:GetScanTokens()) do
		if self:IsPotentialNpcUnit(unit) and self:IsUnitNearPlayer(unit) then
			local guid = UnitGUID(unit)

			if guid and not self.autoDiscovery.baselineGUIDs[guid] and not self.autoDiscovery.assignedGUIDs[guid] and not self:IsRegisteredSpawn(guid) then
				local distance = GetUnitDistanceFromPlayer(unit) or 0
				local fullName = GetUnitName(unit, true) or UnitName(unit)
				local existingCandidate = candidatesByGUID[guid]

				if (not existingCandidate) or distance < existingCandidate.distance then
					candidatesByGUID[guid] = {
						guid = guid,
						unit = unit,
						distance = distance,
						fullName = fullName,
					}
				end
			end
		end
	end

	local candidates = {}

	for _, candidate in pairs(candidatesByGUID) do
		candidates[#candidates + 1] = candidate
	end

	table.sort(candidates, function(left, right)
		if left.distance ~= right.distance then
			return left.distance < right.distance
		end

		return (left.fullName or "") < (right.fullName or "")
	end)

	local remainingNeeded = nil
	local assignedCount = self:GetAutoDiscoveryAssignedCount()

	if self.autoDiscovery.expectedIncrease then
		remainingNeeded = math.max(self.autoDiscovery.expectedIncrease - assignedCount, 0)

		if remainingNeeded <= 0 then
			return
		end
	end

	for _, candidate in ipairs(candidates) do
		if remainingNeeded and remainingNeeded <= 0 then
			break
		end

		self:RegisterServerSpawn(candidate.guid, {
			name = ShortName(candidate.fullName),
			fullName = candidate.fullName,
			autoDetected = true,
			detectedBy = "spawn-under-player",
			detectedAt = GetTime(),
			distance = candidate.distance,
		})

		self.autoDiscovery.assignedGUIDs[candidate.guid] = true
		discoveredNow = discoveredNow + 1

		if remainingNeeded then
			remainingNeeded = remainingNeeded - 1
		end
	end

	if discoveredNow <= 0 then
		return
	end

	assignedCount = self:GetAutoDiscoveryAssignedCount()

	if self.autoDiscovery.expectedIncrease and assignedCount < self.autoDiscovery.expectedIncrease then
		self:SetStatusMessage(L("Auto-detected %d/%d nearby spawn(s).", assignedCount, self.autoDiscovery.expectedIncrease), 4)
		return
	end

	self:FinishAutoDiscovery(L("Auto-detected %d nearby spawn(s).", assignedCount))
end

function Integration:RefreshProbeText()
	if not self.ui or not self.ui.ProbeText then
		return
	end

	local probe = self.addCommandProbe

	if not probe or not probe.command then
		self.ui.ProbeText:SetText("")
		self.ui.ProbeText:Hide()
		return
	end

	local lines = {
		L("Last .min npc add probe: %s", probe.command),
	}

	if probe.lines and #probe.lines > 0 then
		for _, line in ipairs(probe.lines) do
			lines[#lines + 1] = line
		end
	elseif probe.completedAt then
		lines[#lines + 1] = L("No system response captured.")
	else
		lines[#lines + 1] = L("Waiting for server response...")
	end

	self.ui.ProbeText:SetText(table.concat(lines, "|n"))
	self.ui.ProbeText:Show()
end

function Integration:BeginAddCommandProbe(commandText)
	self.addCommandProbe = {
		command = commandText,
		startedAt = GetTime(),
		expiresAt = GetTime() + ADD_PROBE_TIMEOUT,
		lines = {},
		baselineObservedCount = self.observedNpcCount,
		requestedNPCID = tonumber(commandText:match("^%.min npc add%s+(%d+)")),
		placeholdersCreated = 0,
	}

	self:BeginAutoDiscovery(commandText)
	self:SetStatusMessage(L("Watching server response for .min npc add."), 4)
	self:RefreshDungeonManagerView()
end

function Integration:CompleteAddCommandProbe(message)
	if not self.addCommandProbe then
		return
	end

	self.addCommandProbe.expiresAt = nil
	self.addCommandProbe.completedAt = GetTime()

	if message then
		self:SetStatusMessage(message, 4)
	end

	self:RefreshDungeonManagerView()
end

function Integration:AppendProbeLine(line)
	if not self.addCommandProbe then
		return
	end

	local probeLines = self.addCommandProbe.lines

	if #probeLines >= MAX_PROBE_LINES then
		table.remove(probeLines, 1)
	end

	probeLines[#probeLines + 1] = line
	self.addCommandProbe.completedAt = GetTime()
	self:StampProbeLines(self.addCommandProbe.command, probeLines)
	self:RefreshDungeonManagerView()
end

function Integration:HandleResetCommand(commandText)
	if commandText ~= ".min reset creature" and commandText ~= ".min reset all" then
		return false
	end

	self:ResetTrackedState(L("Reset command sent. Cleared tracked DarkMoon spawns."))
	return true
end

function Integration:HandleDeleteCommand(commandText)
	local spawnID = commandText:match("^%.min npc del%s+(%d+)$") or commandText:match("^%.min npc delete%s+(%d+)$")

	if spawnID then
		spawnID = tonumber(spawnID)

		if self:RemoveTrackedSpawnBySpawnID(spawnID) then
			self:SetStatusMessage(L("Delete command sent for SpawnID %s.", tostring(spawnID)), 4)
		else
			self:SetStatusMessage(L("Delete command sent, but SpawnID %s is not tracked yet.", tostring(spawnID)), 4)
		end

		return true
	end

	if commandText == ".min npc del" or commandText == ".min npc delete" then
		if self:RemoveTrackedTargetSpawn() then
			self:SetStatusMessage(L("Delete command sent for the current target."), 4)
		else
			self:BeginDeleteReconcile(commandText)
			self:SetStatusMessage(L("Delete command sent. Waiting for NPC count drop to reconcile the unresolved spawn."), 4)
		end

		return true
	end

	return false
end

function Integration:HandleOutgoingChatMessage(text, chatType)
	local normalized = NormalizeOutgoingCommand(text)

	if normalized == "" then
		return
	end

	if self:HandleResetCommand(normalized) then
		return
	end

	if self:HandleDeleteCommand(normalized) then
		return
	end

	if normalized:match("^%.min npc add[%s%-%d]") or normalized == ".min npc add" then
		self:BeginAddCommandProbe(normalized)
	end
end

function Integration:BeginManualCapture()
	self.manualCaptureExpiresAt = GetTime() + MANUAL_CAPTURE_TIMEOUT
	self.pendingNpcInfo = nil
	self:SetStatusMessage(L("Capture armed for %d sec.", MANUAL_CAPTURE_TIMEOUT))
	self:RefreshDungeonManagerView()
end

function Integration:EndManualCapture(message)
	self.manualCaptureExpiresAt = nil
	self.pendingNpcInfo = nil

	if message then
		self:SetStatusMessage(message, 4)
	end

	self:RefreshDungeonManagerView()
end

function Integration:CommitPendingNpcInfo()
	local info = self.pendingNpcInfo

	if not info or not info.guid then
		return false
	end

	self:RegisterServerSpawn(info.guid, info)
	self.pendingNpcInfo = nil

	local importLabel = info.spawnID or info.guidLow or info.guid
	self:SetStatusMessage(L("Imported spawn %s.", tostring(importLabel)), 4)

	return true
end

function Integration:ConsumeNpcInfoLine(line)
	if line:find("^NPC currently selected by player:") then
		self.pendingNpcInfo = {}
		return
	end

	if not self.pendingNpcInfo then
		return
	end

	local info = self.pendingNpcInfo
	local name = line:match("^Name:%s*(.+)$")

	if name and name ~= "" then
		info.name = name:gsub("%.$", "")
	end

	local spawnID = line:match("^SpawnID:%s*(%d+)")

	if spawnID then
		info.spawnID = tonumber(spawnID)
	end

	local guid = line:match("^GUID:%s*([%w%-]+)%.?$")

	if guid then
		info.guid = guid
		info.guidLow = info.guidLow or GetGUIDLowFromGUID(guid)
	end

	local entryID = line:match("^Entry:%s*(%d+)")

	if entryID then
		info.npcID = tonumber(entryID)
	end

	local level = line:match("^Level:%s*(%d+)")

	if level then
		info.level = tonumber(level)
	end

	self:CommitPendingNpcInfo()
end

function Integration:HandleSystemMessage(message)
	local normalized = NormalizeSystemMessage(message)

	if normalized == "" then
		return
	end

	for line in normalized:gmatch("[^\r\n]+") do
		self:ConsumeServerCountLine(line)
		self:ConsumeServerRemovalLine(line)

		if self:IsAddCommandProbeActive() then
			self:AppendProbeLine(line)
		end

		if self:IsManualCaptureActive() then
			self:ConsumeNpcInfoLine(line)
		end
	end

	self:TryAutoRegisterNearbySpawns()
end

function Integration:RefreshDungeonManagerView()
	if not self.ui or not self.ui.container then
		return
	end

	local entries = self:GetTrackedEntries()
	local selectedEntry = nil

	for _, entry in ipairs(entries) do
		if self:IsSelectedEntry(entry) then
			selectedEntry = entry
			break
		end
	end

	if not selectedEntry then
		selectedEntry = entries[1]
		self:SelectEntry(selectedEntry)
	end

	self.ui.CountText:SetText(L("%d tracked spawns", #entries))
	self:RefreshStatusText()
	self:RefreshProbeText()
	self:RefreshDetailsText(selectedEntry)

	if #entries == 0 then
		self.ui.EmptyText:Show()
	else
		self.ui.EmptyText:Hide()
	end

	self:AdjustDungeonManagerLayout(#entries)

	local visibleRows = self:GetVisibleRowCount(#entries)

	for index = 1, #self.ui.Rows do
		local entry = index <= visibleRows and entries[index] or nil
		self:RefreshRow(self.ui.Rows[index], entry)
	end
end

function Integration:CreateRow(parent, index)
	local button = CreateFrame("Button", nil, parent, SecureBackdropTemplate)
	button:SetHeight(ROW_HEIGHT)
	button:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -8 - ((index - 1) * (ROW_HEIGHT + ROW_GAP)))
	button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, -8 - ((index - 1) * (ROW_HEIGHT + ROW_GAP)))
	button:RegisterForClicks("LeftButtonUp")

	if button.SetBackdrop then
		button:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8x8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 10,
			insets = { left = 2, right = 2, top = 2, bottom = 2 },
		})
	end

	local status = button:CreateTexture(nil, "ARTWORK")
	status:SetSize(12, 12)
	status:SetTexture("Interface\\Buttons\\WHITE8x8")
	status:SetPoint("LEFT", 10, 0)
	button.Status = status

	local selectionGlow = button:CreateTexture(nil, "OVERLAY")
	selectionGlow:SetTexture("Interface\\Buttons\\WHITE8x8")
	selectionGlow:SetPoint("TOPLEFT", 2, -2)
	selectionGlow:SetPoint("BOTTOMRIGHT", -2, 2)
	selectionGlow:SetVertexColor(1.0, 0.92, 0.50, 0.14)
	selectionGlow:Hide()
	button.SelectionGlow = selectionGlow

	local nameText = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	nameText:SetPoint("TOPLEFT", status, "TOPRIGHT", 8, -1)
	nameText:SetPoint("TOPRIGHT", -30, -4)
	nameText:SetJustifyH("LEFT")
	button.NameText = nameText

	local detailText = button:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	detailText:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -2)
	detailText:SetPoint("TOPRIGHT", -30, -4)
	detailText:SetJustifyH("LEFT")
	button.DetailText = detailText

	local ignoreButton = CreateFrame("Button", nil, button, "UIPanelButtonTemplate")
	ignoreButton:SetSize(18, 18)
	ignoreButton:SetPoint("RIGHT", -6, 0)
	ignoreButton:SetText("x")
	ignoreButton:SetScript("OnClick", function(selfButton)
		local parentButton = selfButton:GetParent()

		if parentButton and parentButton.entry then
			if parentButton.entry.isPending then
				Integration:RemovePendingSpawn(parentButton.entry.pendingID)
			else
				Integration:IgnoreSpawn(parentButton.entry)
			end
		end
	end)
	ignoreButton:SetScript("OnEnter", function(selfButton)
		local parentButton = selfButton:GetParent()
		local entry = parentButton and parentButton.entry

		GameTooltip:SetOwner(selfButton, "ANCHOR_RIGHT")

		if entry and entry.isPending then
			GameTooltip:SetText(L("Remove placeholder"))
			GameTooltip:AddLine(L("Removes this unresolved server-confirmed spawn placeholder from the list."), 1, 1, 1, true)
		else
			GameTooltip:SetText(L("Ignore this spawn"))
			GameTooltip:AddLine(L("Removes the entry and adds its GUID to the ignore list for this session."), 1, 1, 1, true)
		end

		GameTooltip:Show()
	end)
	ignoreButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	button.IgnoreButton = ignoreButton

	button:SetScript("OnEnter", function(selfButton)
		local entry = selfButton.entry

		if not entry then
			return
		end

		GameTooltip:SetOwner(selfButton, "ANCHOR_RIGHT")
		GameTooltip:SetText(entry.fullName or entry.name or L("Unknown"))

		if not entry.isPending then
			GameTooltip:AddLine("GUID: " .. (entry.guid or "n/a"), 0.7, 0.7, 0.7, true)
		end

		if entry.npcID then
			GameTooltip:AddLine("NPC ID: " .. tostring(entry.npcID), 0.7, 0.7, 0.7, true)
		end

		if entry.isPending then
			GameTooltip:AddLine("Placeholder: server-confirmed spawn slot", 0.7, 0.7, 0.7, true)
		end

		if entry.spawnID then
			GameTooltip:AddLine("SpawnID: " .. tostring(entry.spawnID), 0.7, 0.7, 0.7, true)
		end

		if entry.guidLow then
			GameTooltip:AddLine("LowGUID: " .. tostring(entry.guidLow), 0.7, 0.7, 0.7, true)
		end

		if entry.autoDetected then
			GameTooltip:AddLine(L("Auto-detected near the player after .min npc add."), 0.7, 0.85, 1.0, true)
		end

		GameTooltip:AddLine(entry.reasonText or "", 1, 1, 1, true)

		if entry.canTarget then
			GameTooltip:AddLine(L("Left-click selects and targets this spawn."), 0.6, 1.0, 0.6, true)
		else
			GameTooltip:AddLine(L("Left-click selects this entry. Targeting is unavailable without a reusable live token."), 1.0, 0.82, 0.4, true)
		end

		GameTooltip:Show()
	end)

	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	button:SetScript("OnClick", function(selfButton, mouseButton)
		if mouseButton ~= "LeftButton" then
			return
		end

		local entry = selfButton.entry

		if not entry then
			return
		end

		Integration:SelectEntry(entry)
		Integration:RefreshDetailsText(entry)

		if not entry.canTarget and not entry.isCurrentTarget then
			Integration:SetStatusMessage(L("Trying to target failed: WoW has no reusable live token for this entry."), 4)
			Integration:RefreshDungeonManagerView()
			return
		end

		Integration:TryTargetEntry(entry)
		Integration:RefreshDungeonManagerView()
	end)

	button.IgnoreButton:Hide()
	button:Hide()
	return button
end

function Integration:GetVisibleRowCount(entryCount)
	if entryCount <= 0 then
		return 0
	end

	return Clamp(entryCount, MIN_VISIBLE_ROWS, MAX_VISIBLE_ROWS)
end

function Integration:GetWrappedTextHeight(fontString, minimumHeight)
	if not fontString or not fontString.GetStringHeight then
		return minimumHeight or 0
	end

	local height = fontString:GetStringHeight() or 0

	if height <= 0 then
		height = minimumHeight or 0
	end

	return math.max(math.ceil(height), minimumHeight or 0)
end

function Integration:EnsureRowCount(requiredCount)
	if not self.ui or not self.ui.ListInset then
		return
	end

	for index = #self.ui.Rows + 1, requiredCount do
		self.ui.Rows[index] = self:CreateRow(self.ui.ListInset, index)
	end
end

function Integration:AdjustDungeonManagerLayout(entryCount)
	if not self.ui or not self.ui.container then
		return
	end

	local container = self.ui.container
	local frame = container:GetParent()

	if not frame or not container:IsShown() then
		return
	end

	self.baseFrameWidth = self.baseFrameWidth or frame:GetWidth() or DEFAULT_FRAME_WIDTH
	self.baseFrameHeight = self.baseFrameHeight or frame:GetHeight() or DEFAULT_FRAME_HEIGHT

	local helpHeight = self:GetWrappedTextHeight(self.ui.HelpText, 16)
	local listTopOffset = 44 + helpHeight
	local probeHeight = 0
	local detailsHeight = 0

	if self.ui.ProbeText and self.ui.ProbeText:IsShown() then
		probeHeight = self:GetWrappedTextHeight(self.ui.ProbeText, 28) + 6
	end

	if self.ui.DetailsText then
		detailsHeight = self:GetWrappedTextHeight(self.ui.DetailsText, 86) + 28
	end

	self.ui.DetailsInset:ClearAllPoints()
	self.ui.DetailsInset:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 5, 26 + probeHeight)
	self.ui.DetailsInset:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -5, 26 + probeHeight)
	self.ui.DetailsInset:SetHeight(detailsHeight)

	self.ui.ListInset:ClearAllPoints()
	self.ui.ListInset:SetPoint("TOPLEFT", container, "TOPLEFT", 5, -listTopOffset)
	self.ui.ListInset:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -5, 34 + probeHeight + detailsHeight)

	local visibleRows = self:GetVisibleRowCount(entryCount)
	local listHeight

	if visibleRows > 0 then
		self:EnsureRowCount(visibleRows)
		listHeight = (visibleRows * ROW_HEIGHT) + (math.max(visibleRows - 1, 0) * ROW_GAP) + 44
	else
		listHeight = self:GetWrappedTextHeight(self.ui.EmptyText, 72) + 36
	end

	local desiredHeight = math.max(self.baseFrameHeight, listTopOffset + listHeight + detailsHeight + 42 + probeHeight)
	frame:SetSize(self.baseFrameWidth, desiredHeight)
end

function Integration:RestoreDungeonManagerFrameSize()
	if not self.ui or not self.ui.container then
		return
	end

	local frame = self.ui.container:GetParent()

	if not frame or not self.baseFrameWidth or not self.baseFrameHeight then
		return
	end

	frame:SetSize(self.baseFrameWidth, self.baseFrameHeight)
end

function Integration:AttachToDungeonManager(container)
	if not container or (self.ui and self.ui.container == container) then
		return
	end

	self.ui = {
		container = container,
		rows = {},
	}

	local helpText = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	helpText:SetPoint("TOPLEFT", 12, -24)
	helpText:SetPoint("TOPRIGHT", -12, -24)
	helpText:SetJustifyH("LEFT")
	helpText:SetText(L("After .min npc add, the tracker first records a server-confirmed spawn placeholder from the NPC counter, then runs a very short close-range radar under the player to try resolving that placeholder into a real GUID. You can also select a placeholder row and resolve it manually by mouseover, target, or combat log activity. If the guess is wrong, use the x button to remove or ignore it."))
	self.ui.HelpText = helpText

	local listInset = CreateFrame("Frame", nil, container, "InsetFrameTemplate")
	self.ui.ListInset = listInset

	local countText = listInset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	countText:SetPoint("BOTTOM", 0, 5)
	countText:SetText(L("0 tracked spawns"))
	self.ui.CountText = countText

	local statusText = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	statusText:SetPoint("BOTTOMLEFT", 104, 10)
	statusText:SetPoint("BOTTOMRIGHT", -8, 10)
	statusText:SetJustifyH("LEFT")
	statusText:SetText(L("0 known GUIDs"))
	self.ui.StatusText = statusText

	local probeText = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	probeText:SetPoint("BOTTOMLEFT", 8, 30)
	probeText:SetPoint("BOTTOMRIGHT", -8, 30)
	probeText:SetJustifyH("LEFT")
	probeText:SetJustifyV("BOTTOM")
	probeText:SetText("")
	probeText:Hide()
	self.ui.ProbeText = probeText

	local detailsInset = CreateFrame("Frame", nil, container, "InsetFrameTemplate")
	self.ui.DetailsInset = detailsInset

	local detailsTitle = detailsInset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	detailsTitle:SetPoint("TOPLEFT", 10, -10)
	detailsTitle:SetPoint("TOPRIGHT", -10, -10)
	detailsTitle:SetJustifyH("LEFT")
	detailsTitle:SetText(L("Spawn details"))
	self.ui.DetailsTitle = detailsTitle

	local detailsText = detailsInset:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	detailsText:SetPoint("TOPLEFT", detailsTitle, "BOTTOMLEFT", 0, -6)
	detailsText:SetPoint("TOPRIGHT", -10, -28)
	detailsText:SetPoint("BOTTOMLEFT", 10, 10)
	detailsText:SetJustifyH("LEFT")
	detailsText:SetJustifyV("TOP")
	detailsText:SetText(L("Select a tracked spawn to inspect all collected fields."))
	self.ui.DetailsText = detailsText

	local emptyText = listInset:CreateFontString(nil, "OVERLAY", "GameFontWhite")
	emptyText:SetPoint("TOPLEFT", 14, -18)
	emptyText:SetPoint("BOTTOMRIGHT", -14, 18)
	emptyText:SetJustifyH("LEFT")
	emptyText:SetJustifyV("TOP")
	emptyText:SetText(L("No tracked DarkMoon spawns yet.|n|nWhen you use .min npc add, the tracker records a server-confirmed spawn slot from the NPC counter immediately, then runs a very short radar directly under your character to try capturing the real GUID.|n|nIf radar misses a spawn, the placeholder stays in the list. You can then select that row and resolve it by mouseover, target, combat log activity, or later by clicking Refresh and running .min npc info. If radar catches the wrong NPC, click the x button to remove or ignore it."))
	self.ui.EmptyText = emptyText

	self.ui.Rows = self.ui.rows

	local refreshButton = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
	refreshButton:SetSize(92, 22)
	refreshButton:SetPoint("BOTTOMLEFT", 6, 4)
	refreshButton:SetText(L("Refresh"))
	refreshButton:SetScript("OnClick", function()
		Integration:BeginManualCapture()
		Integration:RequestRebuild()
	end)
	self.ui.RefreshButton = refreshButton

	container:HookScript("OnShow", function()
		Integration:RefreshDungeonManager()
	end)
	container:HookScript("OnHide", function()
		Integration:RestoreDungeonManagerFrameSize()
	end)

	self:RefreshDungeonManager()
end

function Integration:RefreshDungeonManager()
	self:EnsureDungeonManagerAttached()
	self:RequestRebuild()
end

-------------------------------------------------------------------------------
-- Rebuild.
-------------------------------------------------------------------------------

function Integration:RebuildTrackedUnits()
	local now = GetTime()
	local previousEntries = self.entriesByGUID or {}
	local nextEntries = {}

	self.serverSpawnsByGUID = self.serverSpawnsByGUID or {}

	for guid, seedData in pairs(self.serverSpawnsByGUID) do
		nextEntries[guid] = self:BuildEntry(guid, nil, previousEntries[guid], now, seedData)
	end

	for _, unit in ipairs(self:GetScanTokens()) do
		if self:IsTrackableUnit(unit) then
			local guid = UnitGUID(unit)
			local entry = nextEntries[guid] or self:BuildEntry(guid, unit, previousEntries[guid], now, self.serverSpawnsByGUID[guid])

			nextEntries[guid] = entry
			self:AssignUnitToken(entry, unit)
			entry.lastSeen = now
			entry.isStale = false
		end
	end

	for guid, oldEntry in pairs(previousEntries) do
		if not nextEntries[guid] and oldEntry.lastSeen and (now - oldEntry.lastSeen) <= LOST_TRACK_TTL then
			local entry = {}

			CopyFields(oldEntry, entry)
			entry.displayToken = nil
			entry.targetToken = nil
			entry.sourceLabel = nil
			entry.canTarget = false
			entry.isStale = true
			nextEntries[guid] = entry
		end
	end

	for guid, entry in pairs(nextEntries) do
		if entry.lastSeen and (now - entry.lastSeen) > LOST_TRACK_TTL and not entry.isRegistered then
			nextEntries[guid] = nil
		else
			self:FinalizeEntry(entry)
		end
	end

	self.entriesByGUID = nextEntries
	self:RefreshDungeonManagerView()
end

function Integration:RequestRebuild()
	self:EnsureDungeonManagerAttached()

	if InCombatLockdown and InCombatLockdown() then
		self.pendingRebuild = true
		return
	end

	self.pendingRebuild = nil
	self:RebuildTrackedUnits()
end

-------------------------------------------------------------------------------
-- Events.
-------------------------------------------------------------------------------

function Integration:OnEvent(event, ...)
	if event == "CHAT_MSG_SYSTEM" then
		local message = ...
		self:HandleSystemMessage(message)
		return
	end

	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		self:HandleCombatLogEvent()
		return
	end

	if event == "PLAYER_REGEN_ENABLED" and self.pendingRebuild then
		self:RequestRebuild()
		return
	end

	if event == "UPDATE_MOUSEOVER_UNIT" then
		self:TryResolvePendingFromUnit("mouseover", "mouseover")
	elseif event == "PLAYER_TARGET_CHANGED" then
		self:TryResolvePendingFromUnit("target", "target")
	end

	self:TryAutoRegisterNearbySpawns()

	self:RequestRebuild()
end

function Integration:Initialize()
	if self.initialized then
		return
	end

	self.initialized = true
	hooksecurefunc("SendChatMessage", function(text, chatType, language, channel)
		self:HandleOutgoingChatMessage(text, chatType, language, channel)
	end)

	self.eventFrame = CreateFrame("Frame")
	self.eventFrame:SetScript("OnEvent", function(_, event, ...)
		self:OnEvent(event, ...)
	end)

	self.eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	self.eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
	self.eventFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
	self.eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
	self.eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	self.eventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
	self.eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
	self.eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	self.eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

	self.updateFrame = CreateFrame("Frame")
	self.updateFrame.elapsed = 0
	self.updateFrame.fastElapsed = 0
	self.updateFrame:SetScript("OnUpdate", function(frame, elapsed)
		frame.elapsed = frame.elapsed + elapsed
		frame.fastElapsed = frame.fastElapsed + elapsed

		if frame.fastElapsed >= 0.2 then
			frame.fastElapsed = 0

			if self.autoDiscovery and self.autoDiscovery.expiresAt and self.autoDiscovery.expiresAt > GetTime() then
				self:TryAutoRegisterNearbySpawns()
			end
		end

		if frame.elapsed < 1 then
			return
		end

		frame.elapsed = 0

		self:TryAutoRegisterNearbySpawns()

		if self.manualCaptureExpiresAt and self.manualCaptureExpiresAt <= GetTime() then
			self:EndManualCapture(L("Manual import window expired."))
		end

		if self.autoDiscovery and self.autoDiscovery.expiresAt and self.autoDiscovery.expiresAt <= GetTime() then
			local assignedCount = self:GetAutoDiscoveryAssignedCount()

			if assignedCount > 0 then
				self:FinishAutoDiscovery(L("Auto-detected %d nearby spawn(s).", assignedCount))
			elseif self.autoDiscovery.expectedIncrease and self.autoDiscovery.expectedIncrease > 0 then
				self:FinishAutoDiscovery(L("Server count changed. Added unresolved spawn placeholder(s); import GUID later with .min npc info if needed."))
			else
				self:FinishAutoDiscovery(L("No new nearby NPC detected after .min npc add."))
			end
		end

		if self.deleteReconcile and self.deleteReconcile.expiresAt and self.deleteReconcile.expiresAt <= GetTime() then
			self:FinalizeDeleteReconcile(L("Delete reconcile expired: NPC count did not drop, so no tracked spawn was removed."))
		end

		if self.addCommandProbe and self.addCommandProbe.expiresAt and self.addCommandProbe.expiresAt <= GetTime() then
			if self.addCommandProbe.lines and #self.addCommandProbe.lines > 0 then
				self:CompleteAddCommandProbe(L("Probe finished."))
			else
				self:CompleteAddCommandProbe(L(".min npc add produced no visible system response."))
			end
		elseif self.ui and self.ui.container and self.ui.container:IsShown() then
			self:RefreshStatusText()
			self:RefreshProbeText()
		end

		if self.pendingRebuild or self:HasRegisteredSpawns() or (self.entriesByGUID and next(self.entriesByGUID)) then
			self:RequestRebuild()
		end
	end)
end

Integration:Initialize()
