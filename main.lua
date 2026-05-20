local api = require("api")
--local debug = require("AAFreeTranslation/debug_dump")
local settingsPage = require("AAFreeTranslation/settings_page")

local AAFree_Translation_addon = {
	name = "AAFreeTranslation",
	author = "",
	version = "1.0",
	desc = "Need Run AAFREE Translation Service First"
}

-- ============================================================
-- 变量
-- ============================================================
local TranslationWindow          -- 聊天事件监听
local GameUIScale = 0
-- 自动翻译

-- 玩家名（用于手动翻译分区）
local playerName = ""

-- 翻译方向: 0=待启动, 1=zh→en, 2=zh→ru, 3=ru→zh, 4=ru→en, 5=en→zh, 6=en→ru
local translateType = 0

-- 翻译设置
local trSettings 

-- 手动翻译 UI
local trMainWindow
local trMainBg
local trInputEdit
local trOutputEdit
local addonPath     = "AAFreeTranslation/"
local InRequestFile  = addonPath .. "cache/manual_request"
local OutResponseFile = addonPath .. "cache/manual_response"
local chatSourceFile = addonPath .. "cache/chat_source"
local chatResultFile = addonPath .. "cache/chat_result"
local sendResultFile = addonPath .. "cache/send_result"
local dumpFile       = addonPath .. "dump.lua"

-- 翻译方向 → UI 文本映射
local typeLabels = {
	"ZH - EN",
	"ZH - RU",
	"EN - ZH",
	"EN - RU",
	"RU - ZH",
	"RU - EN"
}

-- 共用轮询
local checkTimer = 0
local checkMs = 100
local trRequestTimestamp=""  --请求时间戳（字符串类型）
local trTimeoutSec = 5.0

-- Base64 字母表
local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

-- ============================================================
-- 工具函数
-- ============================================================

local function split(s, sep)
	local fields = {}
	local sep = sep or " "
	local pattern = string.format("([^%s]+)", sep)
	string.gsub(s, pattern, function(c) fields[#fields + 1] = c end)
	return fields
end

local function base64Encode(data)
	return ((data:gsub('.', function(x)
		local r,b='',x:byte()
		for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
		return r;
	end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
		if (#x < 6) then return '' end
		local c=0
		for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
		return b:sub(c+1,c+1)
	end)..({ '', '==', '=' })[#data%3+1])
end

local function base64Decode(data)
	data = string.gsub(data, '[^'..b..'=]', '')
	return (data:gsub('.', function(x)
		if (x == '=') then return '' end
		local r,f='',(b:find(x)-1)
		for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
		return r;
	end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
		if (#x ~= 8) then return '' end
		local c=0
		for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
		return string.char(c)
	end))
end
--生成13位文本时间戳
local function GetTimestamp()
    local sec = api.Time:GetLocalTime()
    local msec = math.floor(api.Time:GetUiMsec() % 1000)	
    
    local secStr = tostring(sec)
    local msecStr = tostring(msec)
	-- 我也不想这么写那逼string.format有毛病!!!!
    -- 毫秒补零到3位 
    while #msecStr < 3 do
        msecStr = "0" .. msecStr
    end
    -- 秒补零到10位
    while #secStr < 10 do
        secStr = "0" .. secStr
    end
    result = secStr .. msecStr
    return result
end
-- ============================================================
-- 自动聊天捕获 → chat_source
-- ============================================================
local function writeChatToTranslatingFile(channel, unit, isHostile, name, message, speakerInChatBound, specifyName, factionName, trialPosition)
	if name ~= nil and #message > 1 then
		--if tostring(channel) == "3" then return end--屏蔽频道
		--if tostring(channel) ~= "0" then return end--屏蔽其他频道进行测试
		if name == playerName then return end--屏蔽自己发送
		api.File:Write(chatSourceFile, tostring( "||||" .. channel .. "||||" .. name .. "||||" .. message .. "||||"..settingsPage.GetLang() .. "||||" .. GetTimestamp() .. "||||"))
	end
end

-- 聊天框显示自动翻译结果
local function sendDecoratedChatByChannel(message, sender, channel)

	local playerName = api.Unit:GetUnitNameById(api.Unit:GetUnitId("player"))
	if tostring(sender):lower() == tostring(playerName):lower():gsub("^%s*(.-)%s*$", "%1") then
		return
	end
	local prefix = " "
	if tostring(channel) == "-3" then
		-- 悄悄话 CMF_WHISPER
		X2Chat:DispatchChatMessage(3, prefix .. "[" .. sender .. "]: 对你: " .. message)
	elseif tostring(channel) == "0" then
		-- 附近 CMF_SAY
		X2Chat:DispatchChatMessage(56, "|cFFfbfbfb" .. prefix .. "[" .. sender .. "]: " .. message)
	elseif tostring(channel) == "1" then
		-- 呐喊 CMF_ZONE
		X2Chat:DispatchChatMessage(56, "|cFFee6890" .. prefix .. "[" .. sender .. "]: " .. message)
	elseif tostring(channel) == "2" then
		-- 交易 CMF_TRADE
		X2Chat:DispatchChatMessage(56, "|cFF35edc8" .. prefix .. "[" .. sender .. "]: " .. message)
	elseif tostring(channel) == "3" then
		-- 寻找队伍 CMF_FIND_PARTY
		X2Chat:DispatchChatMessage(56, prefix .. "[" .. sender .. "]: " .. message)
	elseif tostring(channel) == "4" then
		-- 队伍 CMF_PARTY
		X2Chat:DispatchChatMessage(4, prefix .. "[" .. sender .. "]: " .. message)
	elseif tostring(channel) == "5" then
		-- 团队 CMF_RAID
		X2Chat:DispatchChatMessage(5, prefix .. "[" .. sender .. "]: " .. message)
	elseif tostring(channel) == "6" then
		-- 种族 CMF_RACE
		X2Chat:DispatchChatMessage(56, "|cFF8eb131" .. prefix .. "[" .. sender .. "]: " .. message)
	elseif tostring(channel) == "7" then
		-- 远征队 CMF_EXPEDITION
		X2Chat:DispatchChatMessage(6, prefix .. "[" .. sender .. "]: " .. message)
	elseif tostring(channel) == "9" then
		-- 家族 CMF_FAMILY
		X2Chat:DispatchChatMessage(57, prefix .. "[" .. sender .. "]: " .. message)
	elseif tostring(channel) == "10" then
		-- 指挥 CMF_RAID_COMMAND
		X2Chat:DispatchChatMessage(58, prefix .. "[" .. sender .. "]: " .. message)
	elseif tostring(channel) == "11" then
		-- 审判 CMF_TRIAL
		X2Chat:DispatchChatMessage(59, prefix .. "[" .. sender .. "]: " .. message)
	elseif tostring(channel) == "14" then
		-- 势力 CMF_FACTION
		X2Chat:DispatchChatMessage(56, "|cFFfcfc01" .. prefix .. "[" .. sender .. "]: " .. message)
	end
end

-- 读取自动翻译结果
local lastMsgTime = ""
local function readLatestTranslatedMessage()
	local data = api.File:Read(chatResultFile)
	if not data or not data.chatMsg then return end
	local msg = data.chatMsg
	local info = split(msg, "||||")
	if not info[4] then return end -- 无时间戳返回
	if lastMsgTime == "" then -- 初始化时间
		lastMsgTime = info[4]
		return
	end
	if lastMsgTime ~= info[4] then -- 时间戳不同 更新时间然后显示到消息里面
		lastMsgTime = info[4]
	else
		return
	end
	if info[1] and info[2] and info[3] then
		sendDecoratedChatByChannel(base64Decode(info[3]), info[2], info[1])
	end
end

-- 手动翻译：发送请求 / 读取响应
local IsSendInputMsg = false
local function trSendRequest(text,KeyState)
	trRequestTimestamp = GetTimestamp()
	if KeyState then
		IsSendInputMsg = true
	end
	api.File:Write(InRequestFile, tostring("||||" .. translateType .. "||||" .. playerName .. "||||" .. text .. "||||" .. trRequestTimestamp .. "||||"))


end
-- 手动翻译：读取响应

local trOriginalMsg = "" --原文（解码后，供其他函数读取）
local trResponseMsg = "" --翻译结果（解码后，供其他函数读取）
local function trReadResponseRaw()
	if not trRequestTimestamp then return end -- 无请求戳返回
	local data = api.File:Read(OutResponseFile)
	if not data or not data.chatMsg then return end -- 无数据返回
	local info = split(data.chatMsg, "||||")
	if not info[4] then return end -- 无时间戳返回
	if info[4] == trRequestTimestamp then
		trRequestTimestamp = ""
		trResponseMsg = base64Decode(info[2])
		trOriginalMsg = base64Decode(info[3])
		trOutputEdit:SetOutputText(trResponseMsg)
		if IsSendInputMsg then
			IsSendInputMsg = false
			local InputBoxState = X2Chat:IsActivatedChatInput() and 1 or 0 --是否激活聊天输入框
			api.File:Write(sendResultFile, tostring("||||" .. info[2] .. "||||" .. tostring(InputBoxState) .. "||||" .. settingsPage.GetLang() .. "||||" .. info[4] .. "||||"))

		end
		api.File:Write(OutResponseFile, "")--情况1：翻译结果已写入文件，清空文件内容
		return true
	end
	return nil
end



local function trDoTranslate()

	local x, y = TranslationWindow:GetOffset()

	if trRequestTimestamp and trRequestTimestamp ~= "" then
		local ntime = GetTimestamp()
		local ntimeSuffix = tonumber(ntime:sub(7))
		local trRequestTimestampSuffix = tonumber(trRequestTimestamp:sub(7))
		local timeDiff = ntimeSuffix - trRequestTimestampSuffix
		if timeDiff <= 1000 then
		trMainWindow:Show(false)	-- 丢失当前输入焦点
		trMainWindow:Show(true)
			return
		end
	end
	local input = trInputEdit:GetText()
	if not input or input == "" then
		trOutputEdit:SetOutputText("输入为空")
		return
	end
	local ShiftState= api.Input:IsShiftKeyDown()
	if ShiftState then
	trMainWindow:Show(false)	-- 丢失当前输入焦点
	trMainWindow:Show(true)
	end
	trSendRequest(input, ShiftState)
	trOutputEdit:SetOutputText("翻译中...")
end

--翻译结果编辑框只读函数
local trOutputText = ""
local function trOutputOnTextChanged()
	trOutputEdit:SetText(trOutputText)
end

-- 手动翻译：创建翻译窗口
local trLangBtn--语言切换按钮
local function CreateTranslatorUI()

	trMainWindow = api.Interface:CreateEmptyWindow("tr_translatorMainWindow", "UIParent")
	trMainWindow:Show(false)
	trMainWindow:SetExtent(300, 90)--设置窗口大小
	trMainWindow:AddAnchor("TOPLEFT", "UIParent", trSettings.MainWindowx, trSettings.MainWindowy)
	-- 编辑框纹理做背景，染蓝色
	local trBg = trMainWindow:CreateNinePartDrawable(TEXTURE_PATH.MONEY_WINDOW, "background")
	trBg:SetCoords(191, 0, 13, 13)
	trBg:SetInset(6, 6, 6, 6)
	trBg:SetColor(0.4, 0.7, 0.95, 0.2)
	trBg:AddAnchor("TOPLEFT", trMainWindow, 0, 0)
	trBg:AddAnchor("BOTTOMRIGHT", trMainWindow, 0, 0)
	trMainBg = trBg
	function trMainWindow:OnDragStart()--拖动开始
		if api.Input:IsShiftKeyDown() then
			trMainWindow:StartMoving()
			api.Cursor:ClearCursor()
			api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
		end
	end
	function trMainWindow:OnDragStop()--拖动停止
		trMainWindow:StopMovingOrSizing()
		api.Cursor:ClearCursor()
		local x, y = trMainWindow:GetOffset()
		trSettings.MainWindowx = x * GameUIScale
		trSettings.MainWindowy = y * GameUIScale
		api.SaveSettings()
	end
	trMainWindow:SetHandler("OnDragStart", trMainWindow.OnDragStart)
	trMainWindow:SetHandler("OnDragStop", trMainWindow.OnDragStop)
	trLangBtn = api.Interface:CreateWidget("button", "tr_topLabel", trMainWindow)
	trLangBtn:AddAnchor("TOPLEFT", trMainWindow, 195, 5)
	trLangBtn:SetExtent(100, 25)
	trLangBtn:SetText(typeLabels[1])
	trLangBtn.style:SetFontSize(14)
	trLangBtn.style:SetColor(1, 1, 1, 1)
	trLangBtn.style:SetAlign(ALIGN.CENTER)
	trLangBtn:RegisterForClicks("LeftButton")
	-- 编辑框纹理（MONEY_WINDOW），三个状态染不同深浅的蓝色
	local texPath = TEXTURE_PATH.MONEY_WINDOW
	local function makeBtnBg(color)
		local bg = trLangBtn:CreateNinePartDrawable(texPath, "background")
		bg:SetCoords(191, 0, 13, 13)
		bg:SetInset(6, 6, 6, 6)
		bg:SetColor(color[1], color[2], color[3], color[4])
		bg:AddAnchor("TOPLEFT", trLangBtn, 0, 0)
		bg:AddAnchor("BOTTOMRIGHT", trLangBtn, 0, 0)
		return bg
	end
	trLangBtn:SetNormalBackground(makeBtnBg({0, 0, 0, 1}))
	trLangBtn:SetHighlightBackground(makeBtnBg({0, 0, 0, 0.6}))
	trLangBtn:SetPushedBackground(makeBtnBg({0, 0, 0, 0.8}))
	trLangBtn:SetHandler("OnClick", function()
		local lang = settingsPage.GetLang()
		local base
		if lang == "zh" then
			base = 0
		elseif lang == "en" then
			base = 2
		elseif lang == "ru" then
			base = 4
		elseif lang == "unknown" then
			return
		end
		local first = base + 1
		local second = base + 2
		-- 不在合法方向范围内则初始化，否则切换
		if translateType ~= first and translateType ~= second then
			translateType = first
		else
			translateType = (translateType == first) and second or first
		end
		trLangBtn:SetText(typeLabels[translateType])
	end)
	local btn2 = api.Interface:CreateWidget("button", "tr_btn2", trMainWindow)
	btn2:AddAnchor("TOPLEFT", trMainWindow, 5, 5)
	btn2:SetExtent(25, 25)

	btn2:SetText("-")
	btn2.style:SetFontSize(14)
	btn2.style:SetColor(1, 1, 1, 1)
	btn2.style:SetAlign(ALIGN.CENTER)
	local btn2Bg = btn2:CreateNinePartDrawable(TEXTURE_PATH.MONEY_WINDOW, "background")
	btn2Bg:SetCoords(191, 0, 13, 13)
	btn2Bg:SetInset(6, 6, 6, 6)
	btn2Bg:SetColor(0, 0, 0, 0.8)
	btn2Bg:AddAnchor("TOPLEFT", btn2, 0, 0)
	btn2Bg:AddAnchor("BOTTOMRIGHT", btn2, 0, 0)
	btn2:SetHandler("OnClick", function()
		local width = trMainWindow:GetWidth()
		if trMainWindow:GetWidth() >35 then
			trLangBtn:Show(false)
			trInputEdit:Show(false)
			trOutputEdit:Show(false)
			trMainWindow:SetExtent(35, 35)
		else

			trLangBtn:Show(true)
			trInputEdit:Show(true)
			trOutputEdit:Show(true)
			trMainWindow:SetExtent(300, 90)
		end

	end)


	trInputEdit = W_CTRL.CreateEdit("tr_translatorInputEdit", trMainWindow)
	trInputEdit:SetExtent(290, 25)
	trInputEdit:AddAnchor("TOPLEFT", trMainWindow, 5, 33)
	trInputEdit:SetHandler("OnEnterPressed", trDoTranslate)
	trInputEdit.bg:SetColor(0, 0, 0, 0.8)
	trInputEdit.style:SetColor(1, 1, 1, 1)
	trOutputEdit = W_CTRL.CreateEdit("tr_translatorOutputEdit", trMainWindow)
	trOutputEdit:SetExtent(290, 25)
	trOutputEdit:AddAnchor("TOPLEFT", trMainWindow, 5, 63)
	trOutputEdit:SetText("")
	trOutputEdit.bg:SetColor(0, 0, 0, 0.8)
	trOutputEdit.style:SetColor(1, 1, 1, 1)
	trOutputEdit:SetHandler("OnTextChanged", trOutputOnTextChanged)
	trOutputEdit.SetOutputText = function(self, text)
		trOutputText = text
		self:SetText(text)
	end
	trOutputEdit:SetHandler("OnEnterPressed", function()
		if api.Input:IsShiftKeyDown() then
			local text = trOutputEdit:GetText()
			if text and text ~= "" then
				trMainWindow:Show(false)	-- 丢失当前输入焦点
				trMainWindow:Show(true)
				local b64Text = base64Encode(text)
				local InputBoxState = X2Chat:IsActivatedChatInput() and 1 or 0
				api.File:Write(sendResultFile, tostring("||||" .. b64Text .. "||||" .. tostring(InputBoxState) .. "||||" .. settingsPage.GetLang() .. "||||" .. tostring(GetTimestamp()) .. "||||"))
			end
		end
	end)
	trMainWindow:EnableDrag(true)
end
-- 手动翻译：创建聊天窗口监听
local function CreateTranslationWindow()
	-- 聊天事件监听窗口
	TranslationWindow = api.Interface:CreateEmptyWindow("TranslationWindow", "UIParent")
	--监听聊天事件 必须在创建窗口后调用不然不生效
	function TranslationWindow:OnEvent(event, ...)
		if event == "CHAT_MESSAGE" then
			if arg ~= nil and settingsPage.enabled then
				writeChatToTranslatingFile(unpack(arg))
			end
		end
	end
	TranslationWindow:AddAnchor("LEFT", "UIParent", 100, 0)

	local bg = TranslationWindow:CreateNinePartDrawable(TEXTURE_PATH.HUD, "background")
	bg:SetTextureInfo("bg_quest")
	bg:SetColor(0, 0, 0, 0)
	bg:AddAnchor("TOPLEFT", TranslationWindow, 0, 0)
	bg:AddAnchor("BOTTOMRIGHT", TranslationWindow, 0, 0)


	TranslationWindow:SetHandler("OnEvent", TranslationWindow.OnEvent)
	TranslationWindow:RegisterEvent("CHAT_MESSAGE")
	TranslationWindow:SetExtent(1, 1)
	TranslationWindow:Show(true)


end

-- 实时获取当前UIScale
local function WindowOnEvent()
	if TranslationWindow and trMainWindow then
		local x, y = TranslationWindow:GetOffset()
		local scale = 100 / x
		if GameUIScale ~= scale then
			GameUIScale = 100 / x
		end
	end
end


-- ============================================================
-- 检查手动翻译结果
-- ============================================================

-- 初始化翻译类型
local function InitTranslateType()
	if translateType == 0 then
		local lang = settingsPage.GetLang()
		local base
		if lang == "zh" then
			base = 1
		elseif lang == "en" then
			base = 3
		elseif lang == "ru" then
			base = 5
		elseif lang == "unknown" then
			base = -1
		end
		if base and base >= 0 and base <=6 then
			if trLangBtn then
				translateType = base
				trLangBtn:SetText(typeLabels[base])
			end
		elseif base == -1 then
			trLangBtn:SetText("N/A")
		end
	end
end
-- ============================================================
-- 每帧更新
-- ============================================================
local function OnUpdate(dt)
	local now = api.Time:GetUiMsec()
	if now < checkTimer + checkMs then return end --每100ms执行下面代码
	checkTimer = now
	
	if settingsPage.resetUIPos then --根据设置重置UI位置
		settingsPage.resetUIPos = false
		trSettings.MainWindowx = 0
		trSettings.MainWindowy = 300
		api.SaveSettings()
		trMainWindow:AddAnchor("TOPLEFT", "UIParent", trSettings.MainWindowx, trSettings.MainWindowy)
	end

	if settingsPage.launchInput == 1 then--根据系统设置显示窗口
		if not trMainWindow:IsVisible() then
			trMainWindow:Show(true)
		end
	else
		if trMainWindow:IsVisible() then
			trMainWindow:Show(false)
		end
	end
	InitTranslateType() --初始化翻译手动输入翻译类型

	if trMainBg then --根据是否按shift键改变背景颜色
		if api.Input:IsShiftKeyDown() then
			trMainBg:SetColor(0.2, 0.4, 0.7, 0.3)
		else
			trMainBg:SetColor(0.4, 0.7, 0.95, 0.2)
		end
	end
	WindowOnEvent()
	readLatestTranslatedMessage()
	trReadResponseRaw()
end

-- ============================================================
-- 加载 / 卸载
-- ============================================================
local function OnLoad()
	trSettings = api.GetSettings("AAFreeTranslation")
	playerName = api.Unit:GetUnitNameById(api.Unit:GetUnitId("player"))
	CreateTranslatorUI()
	CreateTranslationWindow()

	api.On("UPDATE", OnUpdate)
	settingsPage.Initialize()
	api.SaveSettings()
end

local function OnUnload()
	settingsPage.Unload()
	api.On("UPDATE", function() return end)
	if trMainWindow then
		trMainWindow:Show(false)
		api.Interface:Free(trMainWindow)
		trMainWindow = nil
	end
	if TranslationWindow then
		TranslationWindow:ReleaseHandler("OnEvent")
		TranslationWindow:Show(false)
		api.Interface:Free(TranslationWindow)
		TranslationWindow = nil
	end
	lastProcessedMsg = nil
end

AAFree_Translation_addon.OnLoad = OnLoad
AAFree_Translation_addon.OnUnload = OnUnload
AAFree_Translation_addon.OnSettingToggle = settingsPage.Toggle

return AAFree_Translation_addon
