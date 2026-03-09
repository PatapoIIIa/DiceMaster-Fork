local Me = DiceMaster4

Me.localeTranslations = Me.localeTranslations or {
	enUS = {};
}
Me.localeStyles = Me.localeStyles or {
	enUS = {
		fontScale = 1;
		fullscreenFont = "Interface/AddOns/DiceMaster/Fonts/Belwe_Medium.ttf";
		fullscreenFontSize = 20;
	};
}
Me.localizableFrames = Me.localizableFrames or {};

local DEFAULT_FRAME_LAYOUT = {
	paddingX = 32;
	paddingY = 24;
	maxWidth = 1200;
	maxHeight = 1100;
}

local FRAME_LAYOUT_OVERRIDES = {
	DiceMasterActionBar = { paddingX = 48; paddingY = 24; maxWidth = 1400; maxHeight = 400; };
	DiceMasterItemEditor = { paddingX = 48; paddingY = 32; maxWidth = 980; maxHeight = 1000; };
	DiceMasterLearnPetEditor = { paddingX = 40; paddingY = 32; maxWidth = 980; maxHeight = 1000; };
	DiceMasterMerchantEditor = { paddingX = 40; paddingY = 32; maxWidth = 980; maxHeight = 1000; };
	DiceMasterRangeRadar = { paddingX = 24; paddingY = 24; maxWidth = 900; maxHeight = 900; };
	DiceMasterRollFrame = { paddingX = 48; paddingY = 32; maxWidth = 1280; maxHeight = 1100; };
	DiceMasterShopEditor = { paddingX = 48; paddingY = 32; maxWidth = 980; maxHeight = 1000; };
	DiceMasterStatInspector = { paddingX = 40; paddingY = 32; maxWidth = 980; maxHeight = 1040; };
	DiceMasterTradeSkillFrame = { paddingX = 48; paddingY = 32; maxWidth = 980; maxHeight = 1040; };
	DiceMasterTraitEditor = { paddingX = 56; paddingY = 40; maxWidth = 1300; maxHeight = 1300; };
}

local FONT_OBJECT_NAMES = {
	"DiceMasterFontExtraThicc",
	"DiceMasterFontLight",
	"DiceMasterFontThicc",
	"DiceMasterFontReg",
	"DiceMasterFontFullscreen",
}

local CONFIG_REGISTRY_KEYS = {
	"DiceMaster",
	"Health/Resource Bars",
	"Progress Bar",
	"Dungeon Manager",
}

local CONFIG_DISPLAY_NAMES = {
	config = "DiceMaster",
	configCharges = "Health/Resource Bars",
	configProgressBar = "Progress Bar",
	configManager = "Dungeon Manager",
	configProfiles = "Profiles",
}

local LOCALIZED_STRING_FIELDS = {
	"tooltipTitle",
	"tooltipText",
	"tooltipDetail",
	"tooltipTip",
}

local function CopyShallowTable(source)
	local clone = {}
	for key, value in pairs(source) do
		clone[key] = value
	end
	return clone
end

function Me.RegisterLocale(locale, translations, style)
	Me.localeTranslations[locale] = translations or {}
	if style then
		Me.localeStyles[locale] = style
	end
end

function Me.GetConfiguredLocale()
	local requestedLocale = "system"
	if Me.db and Me.db.global and Me.db.global.language then
		requestedLocale = Me.db.global.language
	end
	if requestedLocale == "system" then
		local gameLocale = GetLocale()
		if Me.localeTranslations[gameLocale] then
			return gameLocale
		end
		return "enUS"
	end
	if Me.localeTranslations[requestedLocale] then
		return requestedLocale
	end
	return "enUS"
end

local function LocalizePattern(text)
	local translatedText = text

	translatedText = translatedText:gsub("^Roll (.+)%.|r$", function(rollText)
		return Me.L("Roll %s.|r", rollText)
	end)

	translatedText = translatedText:gsub("^Set maximum (.+) value:$", function(resourceName)
		return Me.L("Set maximum %s value:", Me.TranslateText(resourceName))
	end)

	translatedText = translatedText:gsub("^Set (.+) value:$", function(resourceName)
		return Me.L("Set %s value:", Me.TranslateText(resourceName))
	end)

	translatedText = translatedText:gsub("^|n|cFF00ADEFTip:|r (.+)$", function(tipText)
		return Me.L("|n|cFF00ADEFTip:|r %s", Me.TranslateText(tipText))
	end)

	translatedText = translatedText:gsub("^|cFF707070<Left/Right Click to Add/Remove (.+)>$", function(resourceName)
		return Me.L("|cFF707070<Left/Right Click to Add/Remove %s>", Me.TranslateText(resourceName))
	end)

	return translatedText
end

function Me.TranslateText(text)
	if type(text) ~= "string" or text == "" then
		return text
	end

	local locale = Me.GetConfiguredLocale()
	local localeTable = Me.localeTranslations[locale] or Me.localeTranslations.enUS or {}
	local enUSTable = Me.localeTranslations.enUS or {}

	if localeTable[text] ~= nil then
		return localeTable[text]
	end

	if enUSTable[text] ~= nil then
		return enUSTable[text]
	end

	return LocalizePattern(text)
end

function Me.L(key, ...)
	local localizedText = Me.TranslateText(key)
	if select("#", ...) > 0 then
		return localizedText:format(...)
	end
	return localizedText
end

Me.LocaleTable = Me.LocaleTable or setmetatable({}, {
	__index = function(_, key)
		return Me.L(key)
	end;
})

local function RestoreBaseFont(fontObject)
	if not fontObject.GetFont or not fontObject.SetFont then
		return
	end
	local fontPath, fontSize, fontFlags = fontObject:GetFont()
	if not fontObject.__dmBaseFont and fontPath and fontSize then
		fontObject.__dmBaseFont = {
			path = fontPath;
			size = fontSize;
			flags = fontFlags;
		}
	end
	if fontObject.__dmBaseFont then
		fontObject:SetFont(fontObject.__dmBaseFont.path, fontObject.__dmBaseFont.size, fontObject.__dmBaseFont.flags)
	end
end

function Me.FitTextObject(fontObject)
	if not fontObject.GetFont or not fontObject.GetStringWidth or not fontObject.GetWidth or not fontObject.SetFont then
		return
	end

	RestoreBaseFont(fontObject)

	local availableWidth = fontObject:GetWidth()
	if not availableWidth or availableWidth <= 0 then
		return
	end

	local stringWidth = fontObject:GetStringWidth()
	if not stringWidth or stringWidth <= availableWidth + 1 then
		return
	end

	local baseFont = fontObject.__dmBaseFont
	if not baseFont or not baseFont.size then
		return
	end

	local ratio = availableWidth / stringWidth
	local minimumSize = math.max(8, math.floor(baseFont.size * 0.82))
	local adjustedSize = math.max(minimumSize, math.floor(baseFont.size * ratio))
	if adjustedSize < baseFont.size then
		fontObject:SetFont(baseFont.path, adjustedSize, baseFont.flags)
	end
end

local function LocalizeStringField(container, fieldName)
	local currentValue = container[fieldName]
	if type(currentValue) ~= "string" or currentValue == "" then
		return
	end

	local baseKey = "__dmBase_" .. fieldName
	if Me.GetConfiguredLocale() == "enUS" or not container[baseKey] then
		container[baseKey] = currentValue
	end

	container[fieldName] = Me.TranslateText(container[baseKey])
end

local function LocalizeTextObject(textObject)
	if not textObject or not textObject.GetText or not textObject.SetText then
		return
	end
	if textObject.IsObjectType and textObject:IsObjectType("EditBox") then
		return
	end

	local currentText = textObject:GetText()
	if type(currentText) ~= "string" or currentText == "" then
		return
	end

	if Me.GetConfiguredLocale() == "enUS" or not textObject.__dmBaseText then
		textObject.__dmBaseText = currentText
	end

	local localizedText = Me.TranslateText(textObject.__dmBaseText)
	if localizedText ~= currentText then
		textObject:SetText(localizedText)
	end

	Me.FitTextObject(textObject)
end

local function VisitUiObject(rootObject, visitor, visited)
	if not rootObject or visited[rootObject] then
		return
	end
	visited[rootObject] = true

	visitor(rootObject)

	if rootObject.GetRegions then
		local regions = { rootObject:GetRegions() }
		for _, region in ipairs(regions) do
			VisitUiObject(region, visitor, visited)
		end
	end

	if rootObject.GetChildren then
		local children = { rootObject:GetChildren() }
		for _, child in ipairs(children) do
			VisitUiObject(child, visitor, visited)
		end
	end
end

function Me.LocalizeFrame(frame)
	if not frame then
		return
	end

	local visited = {}
	VisitUiObject(frame, function(uiObject)
		LocalizeTextObject(uiObject)
		for _, fieldName in ipairs(LOCALIZED_STRING_FIELDS) do
			LocalizeStringField(uiObject, fieldName)
		end
	end, visited)
end

function Me.RefreshLocalizedFrameLayout(frame)
	if not frame or not frame.GetWidth or not frame.SetSize or (frame.IsShown and not frame:IsShown()) then
		return
	end

	frame.__dmBaseWidth = frame.__dmBaseWidth or frame:GetWidth()
	frame.__dmBaseHeight = frame.__dmBaseHeight or frame:GetHeight()

	local frameLeft = frame:GetLeft()
	local frameTop = frame:GetTop()
	local frameBottom = frame:GetBottom()
	if not frameLeft or not frameTop or not frameBottom then
		return
	end

	local options = FRAME_LAYOUT_OVERRIDES[frame:GetName() or ""] or DEFAULT_FRAME_LAYOUT
	local maxRight = frameLeft + frame.__dmBaseWidth
	local minBottom = frameBottom
	local visited = {}

	VisitUiObject(frame, function(uiObject)
		if uiObject == frame or not uiObject.IsShown or not uiObject:IsShown() then
			return
		end
		local objectLeft = uiObject:GetLeft()
		local objectRight = uiObject:GetRight()
		local objectBottom = uiObject:GetBottom()
		if objectLeft and objectRight and objectBottom then
			maxRight = math.max(maxRight, objectRight)
			minBottom = math.min(minBottom, objectBottom)
		end
	end, visited)

	local requestedWidth = math.max(frame.__dmBaseWidth, math.ceil(maxRight - frameLeft + options.paddingX))
	local requestedHeight = math.max(frame.__dmBaseHeight, math.ceil(frameTop - minBottom + options.paddingY))

	if options.maxWidth then
		requestedWidth = math.min(requestedWidth, options.maxWidth)
	end
	if options.maxHeight then
		requestedHeight = math.min(requestedHeight, options.maxHeight)
	end

	frame:SetSize(requestedWidth, requestedHeight)
end

local function IsLocalizableRoot(name, object)
	if type(name) ~= "string" or not name:match("^DiceMaster") then
		return false
	end
	if type(object) ~= "table" or not object.GetObjectType then
		return false
	end

	local objectType = object:GetObjectType()
	if objectType == "Font" or objectType == "FontString" or objectType == "Texture" or objectType == "AnimationGroup" then
		return false
	end

	local parent = object.GetParent and object:GetParent()
	if parent == UIParent then
		return true
	end
	if object.IsToplevel and object:IsToplevel() then
		return true
	end

	return false
end

function Me.DiscoverLocalizableFrames()
	wipe(Me.localizableFrames)

	for name, object in pairs(_G) do
		if IsLocalizableRoot(name, object) then
			Me.localizableFrames[name] = object
			if object.HookScript and not object.__dmLocalizationOnShowHook then
				object:HookScript("OnShow", function(shownFrame)
					Me.LocalizeFrame(shownFrame)
					Me.RefreshLocalizedFrameLayout(shownFrame)
				end)
				object.__dmLocalizationOnShowHook = true
			end
		end
	end
end

local function LocalizeConfigNode(node)
	if type(node) ~= "table" then
		return
	end

	if type(node.name) == "string" then
		node.__dmBaseName = node.__dmBaseName or node.name
		node.name = Me.TranslateText(node.__dmBaseName)
	end

	if type(node.desc) == "string" then
		node.__dmBaseDesc = node.__dmBaseDesc or node.desc
		node.desc = Me.TranslateText(node.__dmBaseDesc)
	end

	if type(node.values) == "table" then
		node.__dmBaseValues = node.__dmBaseValues or CopyShallowTable(node.values)
		for key, value in pairs(node.__dmBaseValues) do
			if type(value) == "string" then
				node.values[key] = Me.TranslateText(value)
			else
				node.values[key] = value
			end
		end
	end

	if type(node.args) == "table" then
		for _, childNode in pairs(node.args) do
			LocalizeConfigNode(childNode)
		end
	end
end

function Me.LocalizeConfigTables()
	local configTables = {
		Me.configOptions,
		Me.configOptionsCharges,
		Me.configOptionsProgressBar,
		Me.configOptionsManager,
	}

	for _, configTable in ipairs(configTables) do
		LocalizeConfigNode(configTable)
	end
end

function Me.LocalizeStaticPopups()
	for dialogName, dialog in pairs(StaticPopupDialogs) do
		if dialogName:match("^DICEMASTER") then
			for _, fieldName in ipairs({ "text", "button1", "button2", "button3" }) do
				if type(dialog[fieldName]) == "string" then
					local baseKey = "__dmBase_" .. fieldName
					dialog[baseKey] = dialog[baseKey] or dialog[fieldName]
					dialog[fieldName] = Me.TranslateText(dialog[baseKey])
				end
			end
		end
	end
end

function Me.ApplyLocaleFonts()
	local locale = Me.GetConfiguredLocale()
	local style = Me.localeStyles[locale] or Me.localeStyles.enUS or {}

	for _, fontObjectName in ipairs(FONT_OBJECT_NAMES) do
		local fontObject = _G[fontObjectName]
		if fontObject and fontObject.GetFont and fontObject.SetFont then
			local fontPath, fontSize, fontFlags = fontObject:GetFont()
			if not fontObject.__dmBaseFont and fontPath and fontSize then
				fontObject.__dmBaseFont = {
					path = fontPath;
					size = fontSize;
					flags = fontFlags;
				}
			end

			local baseFont = fontObject.__dmBaseFont
			if baseFont then
				local nextPath = baseFont.path
				local nextSize = baseFont.size
				if fontObjectName == "DiceMasterFontFullscreen" then
					nextPath = style.fullscreenFont or baseFont.path
					nextSize = style.fullscreenFontSize or baseFont.size
				else
					nextSize = math.max(8, math.floor(baseFont.size * (style.fontScale or 1)))
				end
				fontObject:SetFont(nextPath, nextSize, baseFont.flags)
			end
		end
	end
end

local function RefreshConfigFrames()
	for frameKey, englishName in pairs(CONFIG_DISPLAY_NAMES) do
		local frame = Me[frameKey]
		if frame then
			frame.name = Me.TranslateText(englishName)
		end
	end
end

local function NotifyConfigChange()
	local registry = LibStub and LibStub("AceConfigRegistry-3.0", true)
	if not registry then
		return
	end

	for _, registryKey in ipairs(CONFIG_REGISTRY_KEYS) do
		registry:NotifyChange(registryKey)
	end
end

local tooltipHooksInstalled = false
local dropdownHooksInstalled = false
local localizationRefreshPending = false

local function ShouldTranslateTooltip(tooltip)
	if not tooltip or not tooltip.GetOwner then
		return false
	end
	local owner = tooltip:GetOwner()
	if not owner or not owner.GetName then
		return false
	end
	local ownerName = owner:GetName()
	return type(ownerName) == "string" and ownerName:match("^DiceMaster")
end

local function LocalizeTooltipFontString(tooltip, lineNumber, side)
	local textObject = _G[tooltip:GetName() .. "Text" .. side .. lineNumber]
	if not textObject or not textObject.GetText then
		return
	end

	local currentText = textObject:GetText()
	if type(currentText) ~= "string" or currentText == "" then
		return
	end

	if Me.GetConfiguredLocale() == "enUS" or not textObject.__dmBaseText then
		textObject.__dmBaseText = currentText
	end

	local localizedText = Me.TranslateText(textObject.__dmBaseText)
	if localizedText ~= currentText then
		textObject:SetText(localizedText)
	end

	Me.FitTextObject(textObject)
end

local function InstallTooltipHooks()
	if tooltipHooksInstalled then
		return
	end
	tooltipHooksInstalled = true

	hooksecurefunc(GameTooltip, "SetText", function(tooltip)
		if ShouldTranslateTooltip(tooltip) then
			LocalizeTooltipFontString(tooltip, 1, "Left")
		end
	end)

	hooksecurefunc(GameTooltip, "AddLine", function(tooltip)
		if ShouldTranslateTooltip(tooltip) then
			LocalizeTooltipFontString(tooltip, tooltip:NumLines(), "Left")
		end
	end)

	hooksecurefunc(GameTooltip, "AddDoubleLine", function(tooltip)
		if ShouldTranslateTooltip(tooltip) then
			local lineNumber = tooltip:NumLines()
			LocalizeTooltipFontString(tooltip, lineNumber, "Left")
			LocalizeTooltipFontString(tooltip, lineNumber, "Right")
		end
	end)
end

local function ShouldTranslateDropdown()
	if not UIDROPDOWNMENU_OPEN_MENU or not UIDROPDOWNMENU_OPEN_MENU.GetName then
		return false
	end
	local menuName = UIDROPDOWNMENU_OPEN_MENU:GetName()
	return type(menuName) == "string" and menuName:match("^DiceMaster")
end

local function LocalizeDropdownList(listFrame)
	if not ShouldTranslateDropdown() then
		return
	end

	local maxButtons = UIDROPDOWNMENU_MAXBUTTONS or 32
	for buttonIndex = 1, maxButtons do
		local button = _G[listFrame:GetName() .. "Button" .. buttonIndex]
		if button and button.IsShown and button:IsShown() then
			LocalizeTextObject(button)
			for _, fieldName in ipairs(LOCALIZED_STRING_FIELDS) do
				LocalizeStringField(button, fieldName)
			end
			local fontString = button.GetFontString and button:GetFontString()
			if fontString then
				Me.FitTextObject(fontString)
			end
		end
	end
end

local function InstallDropdownHooks()
	if dropdownHooksInstalled then
		return
	end
	dropdownHooksInstalled = true

	local maxLevels = UIDROPDOWNMENU_MAXLEVELS or 2
	for level = 1, maxLevels do
		local listFrame = _G["DropDownList" .. level]
		if listFrame and listFrame.HookScript then
			listFrame:HookScript("OnShow", function(self)
				LocalizeDropdownList(self)
			end)
		end
	end
end

function Me.ScheduleLocalizationRefresh()
	if localizationRefreshPending then
		return
	end

	if not C_Timer or not C_Timer.After then
		Me.ApplyLocalization()
		return
	end

	localizationRefreshPending = true
	C_Timer.After(0.01, function()
		localizationRefreshPending = false
		Me.ApplyLocalization()
	end)
end

function Me.ApplyLocalization()
	Me.ApplyLocaleFonts()
	Me.LocalizeStaticPopups()
	Me.LocalizeConfigTables()
	Me.DiscoverLocalizableFrames()
	InstallTooltipHooks()
	InstallDropdownHooks()
	RefreshConfigFrames()
	NotifyConfigChange()

	for _, frame in pairs(Me.localizableFrames) do
		Me.LocalizeFrame(frame)
		Me.RefreshLocalizedFrameLayout(frame)
	end

	if Me.UpdatePanelTraits then
		Me.UpdatePanelTraits()
	end
	if Me.RefreshChargesFrame and DiceMasterChargesFrame then
		Me.RefreshChargesFrame(true, true)
	end
	if Me.RefreshPetFrame then
		Me.RefreshPetFrame()
	end
	if Me.RefreshMoraleFrame and Me.db and Me.db.profile and Me.db.profile.morale then
		Me.RefreshMoraleFrame(Me.db.profile.morale.count)
	end
end
