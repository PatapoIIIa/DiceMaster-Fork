-------------------------------------------------------------------------------
-- Battle Core parallel session scaffold.
-------------------------------------------------------------------------------

local Me = DiceMaster4

if not Me then
	return
end

local SS13 = Me.SS13Combat or {}
Me.SS13Combat = SS13

local SessionManager = SS13.SessionManager or {}
SS13.SessionManager = SessionManager

local function CopyFields(source, target)
	if not source or not target then
		return
	end

	for key, value in pairs(source) do
		target[key] = value
	end
end

local function ShallowCopy(value)
	if type(value) ~= "table" then
		return value
	end

	local copy = {}

	for key, nestedValue in pairs(value) do
		copy[key] = nestedValue
	end

	return copy
end

local function BuildPairKey(playerGUID, npcGUID)
	return tostring(playerGUID) .. "::" .. tostring(npcGUID)
end

local function ResolveSession(manager, sessionOrID)
	if type(sessionOrID) == "table" then
		return sessionOrID
	end

	return manager.sessionsByID and manager.sessionsByID[sessionOrID] or nil
end

function SessionManager:EnsureStorage()
	self.sessionsByID = self.sessionsByID or {}
	self.activeSessionIDsByPair = self.activeSessionIDsByPair or {}
	self.activeSessionIDsByNPCGUID = self.activeSessionIDsByNPCGUID or {}
	self.callbacks = self.callbacks or {}
	self.sessionSerial = self.sessionSerial or 0
	self.actionSerial = self.actionSerial or 0
end

function SessionManager:Dispatch(eventName, ...)
	if not self.callbacks or not self.callbacks[eventName] then
		return
	end

	for owner, callback in pairs(self.callbacks[eventName]) do
		local ok, err = pcall(callback, owner, eventName, ...)

		if not ok and geterrorhandler then
			geterrorhandler()(err)
		end
	end
end

function SessionManager:RegisterCallback(eventName, owner, callback)
	self:EnsureStorage()

	if type(owner) == "function" and callback == nil then
		callback = owner
		owner = callback
	end

	if type(callback) ~= "function" then
		return
	end

	self.callbacks[eventName] = self.callbacks[eventName] or {}
	self.callbacks[eventName][owner or callback] = callback
end

function SessionManager:UnregisterCallback(eventName, owner)
	if not self.callbacks or not self.callbacks[eventName] then
		return
	end

	self.callbacks[eventName][owner] = nil
end

function SessionManager:GetPlayerGUID()
	return UnitGUID("player")
end

function SessionManager:GetSession(sessionID)
	self:EnsureStorage()
	return self.sessionsByID[sessionID]
end

function SessionManager:GetOpenSession(playerGUID, npcGUID)
	self:EnsureStorage()

	if not playerGUID or not npcGUID then
		return nil
	end

	local sessionID = self.activeSessionIDsByPair[BuildPairKey(playerGUID, npcGUID)]

	if not sessionID then
		return nil
	end

	local session = self.sessionsByID[sessionID]

	if not session or session.closedAt then
		return nil
	end

	return session
end

function SessionManager:GetOpenSessionForNPC(npcGUID, playerGUID)
	return self:GetOpenSession(playerGUID or self:GetPlayerGUID(), npcGUID)
end

function SessionManager:CreateSession(playerGUID, npcGUID, context)
	self:EnsureStorage()

	if not playerGUID or not npcGUID then
		return nil
	end

	local pairKey = BuildPairKey(playerGUID, npcGUID)
	local existing = self:GetOpenSession(playerGUID, npcGUID)

	if existing then
		if context then
			CopyFields(context, existing.context)
		end

		return existing, false
	end

	self.sessionSerial = self.sessionSerial + 1

	-- A session is a closed async box for one player GUID and one NPC GUID.
	local session = {
		sessionID = "battlecore-session:" .. tostring(self.sessionSerial),
		playerGUID = playerGUID,
		npcGUID = npcGUID,
		pairKey = pairKey,
		status = "open",
		openedAt = GetTime(),
		lastActivityAt = GetTime(),
		context = {},
		state = {},
		actionLog = {},
		actionsByID = {},
	}

	if context then
		CopyFields(context, session.context)
	end

	self.sessionsByID[session.sessionID] = session
	self.activeSessionIDsByPair[pairKey] = session.sessionID
	self.activeSessionIDsByNPCGUID[npcGUID] = self.activeSessionIDsByNPCGUID[npcGUID] or {}
	self.activeSessionIDsByNPCGUID[npcGUID][session.sessionID] = true

	self:Dispatch("SESSION_OPENED", session)
	return session, true
end

function SessionManager:OpenSessionForNPC(npcGUID, context)
	return self:CreateSession(self:GetPlayerGUID(), npcGUID, context)
end

function SessionManager:GetSessionsForNPCGUID(npcGUID, openOnly)
	self:EnsureStorage()

	local results = {}
	local seen = {}
	local indexedSessions = self.activeSessionIDsByNPCGUID[npcGUID]

	if indexedSessions then
		for sessionID in pairs(indexedSessions) do
			local session = self.sessionsByID[sessionID]

			if session and (not openOnly or not session.closedAt) then
				results[#results + 1] = session
				seen[sessionID] = true
			end
		end
	end

	if not openOnly then
		for _, session in pairs(self.sessionsByID) do
			if session.npcGUID == npcGUID and not seen[session.sessionID] then
				results[#results + 1] = session
			end
		end
	end

	table.sort(results, function(left, right)
		return (left.openedAt or 0) < (right.openedAt or 0)
	end)

	return results
end

function SessionManager:GetOpenSessions()
	self:EnsureStorage()

	local results = {}

	for _, session in pairs(self.sessionsByID) do
		if not session.closedAt then
			results[#results + 1] = session
		end
	end

	table.sort(results, function(left, right)
		return (left.openedAt or 0) < (right.openedAt or 0)
	end)

	return results
end

function SessionManager:SetSessionState(sessionOrID, key, value)
	local session = ResolveSession(self, sessionOrID)

	if not session or not key then
		return nil
	end

	session.state[key] = value
	session.lastActivityAt = GetTime()
	self:Dispatch("SESSION_UPDATED", session, key, value)

	return session
end

function SessionManager:MergeSessionState(sessionOrID, patch)
	local session = ResolveSession(self, sessionOrID)

	if not session or type(patch) ~= "table" then
		return nil
	end

	CopyFields(patch, session.state)
	session.lastActivityAt = GetTime()
	self:Dispatch("SESSION_UPDATED", session, patch)

	return session
end

function SessionManager:CloseSession(sessionOrID, reason, closeContext)
	local session = ResolveSession(self, sessionOrID)

	if not session or session.closedAt then
		return false
	end

	session.closedAt = GetTime()
	session.lastActivityAt = session.closedAt
	session.status = "closed"
	session.closeReason = reason
	session.closeContext = session.closeContext or {}

	if closeContext then
		CopyFields(closeContext, session.closeContext)
	end

	self.activeSessionIDsByPair[session.pairKey] = nil

	if self.activeSessionIDsByNPCGUID[session.npcGUID] then
		self.activeSessionIDsByNPCGUID[session.npcGUID][session.sessionID] = nil

		if next(self.activeSessionIDsByNPCGUID[session.npcGUID]) == nil then
			self.activeSessionIDsByNPCGUID[session.npcGUID] = nil
		end
	end

	self:Dispatch("SESSION_CLOSED", session)
	return true
end

function SessionManager:CloseSessionsForNPC(npcGUID, reason, closeContext)
	local closedCount = 0

	for _, session in ipairs(self:GetSessionsForNPCGUID(npcGUID, true)) do
		if self:CloseSession(session, reason, closeContext) then
			closedCount = closedCount + 1
		end
	end

	return closedCount
end

function SessionManager:CreateActionEnvelope(session, direction, sourceGUID, targetGUID, actionType, payload, metadata)
	self.actionSerial = self.actionSerial + 1

	-- Action envelopes stay transport-agnostic on purpose.
	return {
		actionID = "battlecore-action:" .. tostring(self.actionSerial),
		sessionID = session.sessionID,
		direction = direction,
		sourceGUID = sourceGUID,
		targetGUID = targetGUID,
		actionType = actionType or "unknown",
		status = "queued",
		createdAt = GetTime(),
		updatedAt = GetTime(),
		payload = ShallowCopy(payload),
		metadata = ShallowCopy(metadata) or {},
	}
end

function SessionManager:AppendAction(sessionOrID, direction, sourceGUID, targetGUID, actionType, payload, metadata)
	local session = ResolveSession(self, sessionOrID)

	if not session or session.closedAt then
		return nil
	end

	local action = self:CreateActionEnvelope(session, direction, sourceGUID, targetGUID, actionType, payload, metadata)

	session.actionLog[#session.actionLog + 1] = action
	session.actionsByID[action.actionID] = action
	session.lastActivityAt = action.createdAt

	self:Dispatch("ACTION_ADDED", session, action)
	return action
end

function SessionManager:QueuePlayerAction(sessionOrID, actionType, payload, metadata)
	local session = ResolveSession(self, sessionOrID)

	if not session then
		return nil
	end

	return self:AppendAction(
		session,
		"player_to_npc",
		session.playerGUID,
		session.npcGUID,
		actionType,
		payload,
		metadata
	)
end

function SessionManager:QueueNpcAction(sessionOrID, actionType, payload, metadata)
	local session = ResolveSession(self, sessionOrID)

	if not session then
		return nil
	end

	return self:AppendAction(
		session,
		"npc_to_player",
		session.npcGUID,
		session.playerGUID,
		actionType,
		payload,
		metadata
	)
end

function SessionManager:QueuePlayerActionForNPC(npcGUID, actionType, payload, metadata, context)
	local session = self:OpenSessionForNPC(npcGUID, context)

	if not session then
		return nil, nil
	end

	return session, self:QueuePlayerAction(session, actionType, payload, metadata)
end

function SessionManager:QueueNpcActionForNPC(npcGUID, actionType, payload, metadata, context)
	local session = self:OpenSessionForNPC(npcGUID, context)

	if not session then
		return nil, nil
	end

	return session, self:QueueNpcAction(session, actionType, payload, metadata)
end

function SessionManager:UpdateAction(sessionOrID, actionID, patch)
	local session = ResolveSession(self, sessionOrID)

	if not session or not actionID or type(patch) ~= "table" then
		return nil
	end

	local action = session.actionsByID[actionID]

	if not action then
		return nil
	end

	CopyFields(patch, action)
	action.updatedAt = GetTime()
	session.lastActivityAt = action.updatedAt

	self:Dispatch("ACTION_UPDATED", session, action)
	return action
end

function SessionManager:ResolveAction(sessionOrID, actionID, result)
	return self:UpdateAction(sessionOrID, actionID, {
		status = "resolved",
		result = ShallowCopy(result),
		resolvedAt = GetTime(),
	})
end

function SessionManager:Reset()
	self.sessionsByID = {}
	self.activeSessionIDsByPair = {}
	self.activeSessionIDsByNPCGUID = {}
	self.callbacks = self.callbacks or {}
	self.sessionSerial = 0
	self.actionSerial = 0
end

function SessionManager:Initialize()
	if self.initialized then
		return
	end

	self.initialized = true
	self:EnsureStorage()
end

SessionManager:Initialize()
