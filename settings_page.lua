local api = require("api")

local Locale = {
    zh = {
        title = "AAFreeTranslation 设置",
        ok = "确定",
        cancel = "取消",
        enableAuto = "启用自动翻译",
        enableInput = "启用输入翻译窗口",
        google = "使用谷歌翻译",
        ai = "使用AI翻译",
        sectionOutput = "翻译模型-消息",
        sectionInput = "翻译模型-输入",
        url = "完整请求地址:",
        apiKey = "API 密钥 (APIKEY):",
        modelName = "模型名称 (modelName):",
        resetUI = "重置UI位置",
    },
    en = {
        title = "AAFreeTranslation Settings",
        ok = "OK",
        cancel = "Cancel",
        enableAuto = "Enable Auto Translate",
        enableInput = "Enable Translation Input Window",
        google = "Use Google Translate",
        ai = "Use AI Translate",
        sectionOutput = "Translate Model - Message",
        sectionInput = "Translate Model - Input",
        url = "Full Request URL:",
        apiKey = "API Key (APIKEY):",
        modelName = "Model Name (modelName):",
        resetUI = "Reset UI",
    },
    ru = {
        title = "Настройки AAFreeTranslation",
        ok = "ОК",
        cancel = "Отмена",
        enableAuto = "Включить автоперевод",
        enableInput = "Включить окно перевода ввода",
        google = "Использовать Google Переводчик",
        ai = "Использовать ИИ-перевод",
        sectionOutput = "Модель перевода — Сообщения",
        sectionInput = "Модель перевода — Ввод",
        url = "Полный URL запроса:",
        apiKey = "API-ключ (APIKEY):",
        modelName = "Название модели (modelName):",
        resetUI = "Сбросить UI",
    },
}

-- ============================================================
-- check_button.lua 内联
-- ============================================================
function ButtonInit(button)
    button:EnableDrawables("background")
    button.style:SetAlign(ALIGN.CENTER)
    button.style:SetSnap(true)
    button.style:SetColor(0.87, 0.69, 0, 1)
    SetButtonFontColor(button, GetButtonDefaultFontColor())
    button:RegisterForClicks("LeftButton")
end
function GetDefaultCheckButtonFontColor()
    local color = {}
    color.normal = FONT_COLOR.DEFAULT
    color.highlight = FONT_COLOR.DEFAULT
    color.pushed = FONT_COLOR.DEFAULT
    color.disabled = {0.42, 0.42, 0.42, 1}
    return color
end
function GetButtonDefaultFontColor()
    local color = {}
    color.normal = {ConvertColor(104), ConvertColor(68), ConvertColor(18), 1}
    color.highlight = {ConvertColor(154), ConvertColor(96), ConvertColor(16), 1}
    color.pushed = {ConvertColor(104), ConvertColor(68), ConvertColor(18), 1}
    color.disabled = {ConvertColor(92), ConvertColor(92), ConvertColor(92), 1}
    return color
end
function SetButtonFontColor(button, color)
    local n = color.normal
    local h = color.highlight
    local p = color.pushed
    local d = color.disabled
    button:SetTextColor(n[1], n[2], n[3], n[4])
    button:SetHighlightTextColor(h[1], h[2], h[3], h[4])
    button:SetPushedTextColor(p[1], p[2], p[3], p[4])
    button:SetDisabledTextColor(d[1], d[2], d[3], d[4])
end
function SetViewOfEmptyButton(id, parent)
    local button = api.Interface:CreateWidget("button", id, parent)
    button:RegisterForClicks("LeftButton")
    button:RegisterForClicks("RightButton", false)
    button.style:SetAlign(ALIGN.CENTER)
    button.style:SetSnap(true)
    SetButtonFontColor(button, GetButtonDefaultFontColor())
    return button
end
function CreateEmptyButton(id, parent)
    local button = SetViewOfEmptyButton(id, parent)
    return button
end
function SetButtonBackground(button)
    button:SetNormalBackground(button.bgs[1])
    button:SetHighlightBackground(button.bgs[2])
    button:SetPushedBackground(button.bgs[3])
    button:SetDisabledBackground(button.bgs[4])
    if button.bgs[5] ~= nil then button:SetCheckedBackground(button.bgs[5]) end
    if button.bgs[6] ~= nil then button:SetDisabledCheckedBackground(button.bgs[6]) end
end
function SetButtonCoordsForBg(button, bg, coords)
    if coords ~= nil then
        bg:SetExtent(coords[3], coords[4])
        bg:SetCoords(coords[1], coords[2], coords[3], coords[4])
        return true
    end
    if default ~= nil then
        bg:SetCoords(default[1], default[2], default[3], default[4])
        button:SetNormalBackground(bg)
    end
    return false
end
local CreateDefaultDrawable = function(widget, type, path, layer)
    layer = layer or "background"
    local bg
    if type == "threePart" then bg = widget:CreateThreePartDrawable(path, layer) end
    if type == "drawable" then bg = widget:CreateImageDrawable(path, layer) end
    if type == "ninePart" then bg = widget:CreateNinePartDrawable(path, layer) end
    return bg
end
function CreateCheckButtonBackGround(button, path, drawableType, count)
    button.bgs = {}
    for i = 1, count or 4 do
        button.bgs[i] = CreateDefaultDrawable(button, drawableType, path)
        button.bgs[i]:SetExtent(16, 16)
        button.bgs[i]:AddAnchor("CENTER", button, 0, 0)
        if button.bgs[i].SetTexture ~= nil then
            button.bgs[i]:SetTexture(path)
        end
    end
end
function CreateCheckButton(id, parent, text)
    local button = api.Interface:CreateWidget("checkbutton", id, parent)
    CreateCheckButtonBackGround(button, "ui/button/check_button.dds", "drawable", 6)
    if text ~= nil then
        local textButton = CreateEmptyButton(id .. ".textButton", button)
        textButton:AddAnchor("LEFT", button, "RIGHT", 0, 0)
        ButtonInit(textButton)
        textButton:SetAutoResize(true)
        textButton:SetHeight(16)
        textButton:SetText(text)
        textButton.style:SetAlign(ALIGN.LEFT)
        button.textButton = textButton
    end
    function button:SetButtonStyle(style)
        local coords = {}
        if style == "eyeShape" then
            self:SetExtent(27, 18)
            if self.textButton ~= nil then
                self.textButton:RemoveAllAnchors()
                self.textButton:AddAnchor("RIGHT", button, "LEFT", -5, 0)
                SetButtonFontColor(self.textButton, GetDefaultCheckButtonFontColor())
            end
            coords[1] = {37, 0, 27, 18}
            coords[2] = {37, 0, 27, 18}
            coords[3] = {37, 0, 27, 18}
            coords[4] = {37, 36, 27, 18}
            coords[5] = {37, 18, 27, 18}
            coords[6] = {37, 36, 27, 18}
        elseif style == "soft_brown" then
            if self.textButton ~= nil then
                self.textButton:RemoveAllAnchors()
                self.textButton:AddAnchor("LEFT", button, "RIGHT", 0, 0)
                SetButtonFontColor(self.textButton, GetDefaultCheckButtonFontColor())
            end
            self:SetExtent(18, 17)
            coords[1] = {18, 0, 18, 17}
            coords[2] = {18, 0, 18, 17}
            coords[3] = {0, 0, 18, 17}
            coords[4] = {36, 0, 18, 17}
            coords[5] = {18, 17, 18, 17}
            coords[6] = {36, 17, 18, 17}
        else
            if self.textButton ~= nil then
                self.textButton:RemoveAllAnchors()
                self.textButton:AddAnchor("LEFT", button, "RIGHT", 0, 0)
                SetButtonFontColor(self.textButton, GetDefaultCheckButtonFontColor())
            end
            self:SetExtent(18, 17)
            coords[1] = {18, 0, 18, 17}
            coords[2] = {18, 0, 18, 17}
            coords[3] = {0, 0, 18, 17}
            coords[4] = {36, 0, 18, 17}
            coords[5] = {18, 17, 18, 17}
            coords[6] = {36, 17, 18, 17}
        end
        for i = 1, #coords do
            SetButtonBackground(button)
            SetButtonCoordsForBg(button, button.bgs[i], coords[i])
        end
    end
    button:SetButtonStyle(nil)
    SetButtonBackground(button)
    function button:SetEnableCheckButton(enable)
        self:Enable(enable, true)
        if self.textButton ~= nil then self.textButton:Enable(enable) end
    end
    function button:OnCheckChanged()
        if self.CheckBtnCheckChagnedProc ~= nil then
            self:CheckBtnCheckChagnedProc(self:GetChecked())
        end
    end
    button:SetHandler("OnCheckChanged", button.OnCheckChanged)
    if button.textButton ~= nil then
        function button.textButton:OnClick()
            if button:IsEnabled() then
                button:SetChecked(not button:GetChecked())
                if button.CheckBtnCheckChagnedProc ~= nil then
                    button:CheckBtnCheckChagnedProc(button:GetChecked())
                end
            end
        end
        button.textButton:SetHandler("OnClick", button.textButton.OnClick)
    end
    return button
end

-- ============================================================
-- SETTINGS
-- ============================================================
local SETTINGS = {}
local settingsWindow
local ctrl = {}
local resetPending = false

-- ============================================================
-- 辅助函数
-- ============================================================
local function createLabel(parent, id, text, offsetY, fontSize)
    local label = parent:CreateChildWidget("label", id, 0, true)
    label:AddAnchor("TOPLEFT", parent, 20, offsetY)
    label:SetExtent(200, 20)
    label:SetText(text)
    label.style:SetColor(FONT_COLOR.TITLE[1], FONT_COLOR.TITLE[2],
                         FONT_COLOR.TITLE[3], 1)
    label.style:SetAlign(ALIGN.LEFT)
    label.style:SetFontSize(fontSize or 15)
    return label
end

local function createEdit(parent, id, offsetY, width)
    local field = W_CTRL.CreateEdit(id, parent)
    field:AddAnchor("TOPLEFT", parent, 20, offsetY)
    field:SetExtent(width or 350, 22)
    field.style:SetAlign(ALIGN.LEFT)
    field:SetMaxTextLength(512)
    return field
end

local function createButton(parent, id, text, width)
    local btn = api.Interface:CreateWidget("button", id, parent)
    btn:SetExtent(width or 70, 26)
    btn:SetText(text)
    api.Interface:ApplyButtonSkin(btn, BUTTON_BASIC.DEFAULT)
    return btn
end



-- ============================================================
-- 保存
-- ============================================================
local function saveEnabled()
    local settings = {}
    settings.enabled = ctrl.enabled:GetChecked() and 1 or 0 --开启自动翻译
    if ctrl.useGoogle:GetChecked() then
        settings.translateEngine = 1 --使用谷歌翻译
    elseif ctrl.useAI:GetChecked() then
        settings.translateEngine = 2 --使用AI翻译
    else
        settings.translateEngine = 0 --不使用翻译引擎
    end

    settings.launchInput = ctrl.launchInput:GetChecked() and 1 or 0 --手动翻译 
    settings.outputBaseURL = ctrl.baseURL:GetText() --输出接口地址
    settings.outputApiKey = ctrl.apiKey:GetText() --输出API Key
    settings.outputModelName = ctrl.modelName:GetText() --输出模型名称
    settings.inputBaseURL = ctrl.inputBaseURL:GetText() --输入接口地址
    settings.inputApiKey = ctrl.inputApiKey:GetText() --输入API Key
    settings.inputModelName = ctrl.inputModelName:GetText() --输入模型名称
    api.File:Write("AAFreeTranslation/config.ini", settings) --保存配置文件
    for k, v in pairs(settings) do
        SETTINGS[k] = v
    end

end

-- ============================================================
-- 创建设置窗口
-- ============================================================
function SETTINGS.Initialize()
    local settings = SETTINGS.ReadConfig()
    if settings.enabled == nil then settings.enabled = 1 end
    if settings.translateEngine == nil then settings.translateEngine = 1 end
    if settings.launchInput == nil then settings.launchInput = 1 end
    if settings.outputBaseURL == nil then settings.outputBaseURL = "https://open.bigmodel.cn/api/paas/v4/chat/completions" end
    if settings.outputApiKey == nil then settings.outputApiKey = "" end
    if settings.outputModelName == nil then settings.outputModelName = "GLM-4-Flash" end
    if settings.inputBaseURL == nil then settings.inputBaseURL = "https://open.bigmodel.cn/api/paas/v4/chat/completions" end
    if settings.inputApiKey == nil then settings.inputApiKey = "" end
    if settings.inputModelName == nil then settings.inputModelName = "GLM-4-Flash" end
    resetPending = false

    settingsWindow = api.Interface:CreateWindow("AAFreeTrSettingsWnd", Locale.en.title)
    settingsWindow:SetExtent(510, 550)
    settingsWindow:AddAnchor("CENTER", "UIParent", "CENTER", 0, 0)

    -- 创建可滚动区域
    local scrollFrame = settingsWindow:CreateChildWidget("emptywidget", "AAF_ScrollFrame", 0, true)
    scrollFrame:AddAnchor("TOPLEFT", settingsWindow, 5, 30)
    scrollFrame:AddAnchor("BOTTOMRIGHT", settingsWindow, -5, -45)
    scrollFrame:Show(true)
    local content = scrollFrame:CreateChildWidget("emptywidget", "AAF_Content", 0, true)
    content:EnableScroll(true)
    content:Show(true)
    scrollFrame.content = content
    local scrollBar = W_CTRL.CreateScroll("AAF_Scroll", scrollFrame)
    scrollBar:AddAnchor("TOPRIGHT", scrollFrame, 0, 30)
    scrollBar:AddAnchor("BOTTOMRIGHT", scrollFrame, 0, -30)
    scrollBar:SetWheelMoveStep(40)
    scrollBar:SetButtonMoveStep(5)
    scrollBar:AlwaysScrollShow()
    scrollFrame.scroll = scrollBar
    content:AddAnchor("TOPLEFT", scrollFrame, 0, 0)
    content:AddAnchor("BOTTOM", scrollFrame, 0, -30)
    content:AddAnchor("RIGHT", scrollBar, "LEFT", -5, 0)
    function scrollBar.vs:OnSliderChanged(val)
        scrollFrame.content:ChangeChildAnchorByScrollValue("vert", val)
    end
    scrollBar.vs:SetHandler("OnSliderChanged", scrollBar.vs.OnSliderChanged)

    -- 启用自动翻译
    ctrl.enabled = CreateCheckButton("AAF_Chk_Enabled", content, Locale.en.enableAuto)
    ctrl.enabled:AddAnchor("TOPLEFT", content, 20, 40)
    ctrl.enabled:SetButtonStyle("default")
    ctrl.enabled:SetChecked(settings.enabled == 1)
    -- 启用输入翻译窗口
    ctrl.launchInput = CreateCheckButton("AAF_Chk_Launch", content, Locale.en.enableInput)
    ctrl.launchInput:AddAnchor("TOPLEFT", content, 200, 40)
    ctrl.launchInput:SetButtonStyle("default")
    ctrl.launchInput:SetChecked(settings.launchInput == 1)

    local updatingCheck = false
    -- 使用谷歌翻译
    ctrl.useGoogle = CreateCheckButton("AAF_Chk_Google", content, Locale.en.google)
    ctrl.useGoogle:AddAnchor("TOPLEFT", content, 20, 65)
    ctrl.useGoogle:SetButtonStyle("default")
    ctrl.useGoogle:SetChecked(settings.translateEngine == 1)
    ctrl.useGoogle.CheckBtnCheckChagnedProc = function()
        if updatingCheck then return end
        updatingCheck = true
        if ctrl.useGoogle:GetChecked() and ctrl.useAI:GetChecked() then
            ctrl.useAI:SetChecked(false)
        elseif not ctrl.useGoogle:GetChecked() and not ctrl.useAI:GetChecked() then
            ctrl.useGoogle:SetChecked(true)
        end
        updatingCheck = false
    end
    -- 使用AI翻译
    ctrl.useAI = CreateCheckButton("AAF_Chk_AI", content, Locale.en.ai)
    ctrl.useAI:AddAnchor("TOPLEFT", content, 20, 90)
    ctrl.useAI:SetButtonStyle("default")
    ctrl.useAI:SetChecked(settings.translateEngine == 2)

    -- 翻译模型-消息
    ctrl.sectionLabel = createLabel(content, "AAF_Section", Locale.en.sectionOutput, 120, 16)
    ctrl.urlLabel = createLabel(content, "AAF_Lbl_URL", Locale.en.url, 150, 14)
    ctrl.baseURL = createEdit(content, "AAF_Edit_URL", 168, 350)
    ctrl.baseURL:SetText(settings.outputBaseURL ~= nil and settings.outputBaseURL ~= "" and settings.outputBaseURL or "https://open.bigmodel.cn/api/paas/v4/chat/completions")
    ctrl.keyLabel = createLabel(content, "AAF_Lbl_Key", Locale.en.apiKey, 195, 14)
    ctrl.apiKey = createEdit(content, "AAF_Edit_Key", 213, 350)
    ctrl.apiKey:SetText(settings.outputApiKey or "")
    ctrl.modelLabel = createLabel(content, "AAF_Lbl_Model", Locale.en.modelName, 240, 14)
    ctrl.modelName = createEdit(content, "AAF_Edit_Model", 258, 350)
    ctrl.modelName:SetText(settings.outputModelName ~= nil and settings.outputModelName ~= "" and settings.outputModelName or "GLM-4-Flash")

    -- ====== 翻译模型-输入 ======
    ctrl.sectionInputLabel = createLabel(content, "AAF_Section_Input", Locale.en.sectionInput, 310, 16)
    ctrl.urlInputLabel = createLabel(content, "AAF_Lbl_URL_Input", Locale.en.url, 340, 14)
    ctrl.inputBaseURL = createEdit(content, "AAF_Edit_URL_Input", 358, 350)
    ctrl.inputBaseURL:SetText(settings.inputBaseURL ~= nil and settings.inputBaseURL ~= "" and settings.inputBaseURL or "https://open.bigmodel.cn/api/paas/v4/chat/completions")
    ctrl.keyInputLabel = createLabel(content, "AAF_Lbl_Key_Input", Locale.en.apiKey, 385, 14)
    ctrl.inputApiKey = createEdit(content, "AAF_Edit_Key_Input", 403, 350)
    ctrl.inputApiKey:SetText(settings.inputApiKey or "")
    ctrl.modelInputLabel = createLabel(content, "AAF_Lbl_Model_Input", Locale.en.modelName, 430, 14)
    ctrl.inputModelName = createEdit(content, "AAF_Edit_Model_Input", 448, 350)
    ctrl.inputModelName:SetText(settings.inputModelName ~= nil and settings.inputModelName ~= "" and settings.inputModelName or "GLM-4-Flash")

    -- 重置UI位置按钮
    local lang = SETTINGS.GetLang()
    local resetText, resetWidth
    if lang == "zh" then
        resetText = Locale.zh.resetUI; resetWidth = 100
    elseif lang == "en" then
        resetText = Locale.en.resetUI; resetWidth = 80
    else
        resetText = Locale.ru.resetUI; resetWidth = 100
    end
    ctrl.resetBtn = createButton(content, "AAF_Btn_ResetUI", resetText, resetWidth)
    ctrl.resetBtn:AddAnchor("TOPLEFT", content, 20, 480)
    ctrl.resetBtn:SetHandler("OnClick", function(self, arg)
        if arg ~= "LeftButton" then return end
        ctrl.launchInput:SetChecked(true)
        resetPending = true
    end)

    ctrl.useAI.CheckBtnCheckChagnedProc = function()
        if updatingCheck then return end
        updatingCheck = true
        if ctrl.useAI:GetChecked() then
            ctrl.useGoogle:SetChecked(false)
        elseif not ctrl.useGoogle:GetChecked() then
            ctrl.useAI:SetChecked(true)
        end
        updatingCheck = false
    end

    -- 确定 / 取消（右下角）
    local cancelBtn = createButton(settingsWindow, "AAF_Btn_Cancel", Locale.en.cancel, 70)
    ctrl.cancelBtn = cancelBtn
    cancelBtn:AddAnchor("BOTTOMRIGHT", settingsWindow, -15, -15)
    cancelBtn:SetHandler("OnClick", function(self, arg)
        if arg ~= "LeftButton" then return end
        if resetPending then
            resetPending = false
        end
        settingsWindow:Show(false)
    end)
    local okBtn = createButton(settingsWindow, "AAF_Btn_OK", Locale.en.ok, 70)
    ctrl.okBtn = okBtn
    okBtn:AddAnchor("RIGHT", cancelBtn, "LEFT", -5, 0)
    okBtn:SetHandler("OnClick", function(self, arg)
        if arg ~= "LeftButton" then return end
        saveEnabled()
        if resetPending then
            resetPending = false
            SETTINGS.resetUIPos = true
        end
        settingsWindow:Show(false)
    end)

    -- 设置滚动条范围（硬编码：窗口高280-标题栏30-底部45=205可视区，内容至y=506，滚动距离≈320）
    scrollBar.vs:SetMinMaxValues(0, 70)

    settingsWindow:Show(false)
end

-- ============================================================
-- 公开接口
-- ============================================================
function SETTINGS.Toggle()
    if settingsWindow == nil then
        SETTINGS.Initialize()
    end
    SETTINGS.RefreshText()
    settingsWindow:Show(not settingsWindow:IsVisible())
end

function SETTINGS.Unload()
    if settingsWindow then
        settingsWindow:Show(false)
        settingsWindow = nil
    end
end

function SETTINGS.RefreshText()
    local loc = Locale[SETTINGS.GetLang()] or Locale.en
    settingsWindow:SetTitle(loc.title)
    ctrl.enabled.textButton:SetText(loc.enableAuto)
    ctrl.launchInput.textButton:SetText(loc.enableInput)
    ctrl.useGoogle.textButton:SetText(loc.google)
    ctrl.useAI.textButton:SetText(loc.ai)
    ctrl.sectionLabel:SetText(loc.sectionOutput)
    ctrl.urlLabel:SetText(loc.url)
    ctrl.keyLabel:SetText(loc.apiKey)
    ctrl.modelLabel:SetText(loc.modelName)
    ctrl.sectionInputLabel:SetText(loc.sectionInput)
    ctrl.urlInputLabel:SetText(loc.url)
    ctrl.keyInputLabel:SetText(loc.apiKey)
    ctrl.modelInputLabel:SetText(loc.modelName)
    ctrl.cancelBtn:SetText(loc.cancel)
    ctrl.okBtn:SetText(loc.ok)
    if ctrl.resetBtn then
        local lang = SETTINGS.GetLang()
        if lang == "zh" then
            ctrl.resetBtn:SetText(Locale.zh.resetUI)
            ctrl.resetBtn:SetExtent(100, 35)
        elseif lang == "en" then
            ctrl.resetBtn:SetText(Locale.en.resetUI)
            ctrl.resetBtn:SetExtent(80, 35)
        else
            ctrl.resetBtn:SetText(Locale.ru.resetUI)
            ctrl.resetBtn:SetExtent(100, 35)
        end
    end
end

function SETTINGS.ReadConfig()
    local data = api.File:Read("AAFreeTranslation/config.ini")
    if type(data) == "table" then
        for k, v in pairs(data) do
            SETTINGS[k] = v
        end
        return data
    end
    -- config.ini 不存在，设默认值（开启自动翻译、显示手动翻译、Google引擎）
    SETTINGS.enabled = 1
    SETTINGS.translateEngine = 1
    SETTINGS.launchInput = 1
    return {}
end

-- 模块加载时自动读取配置到 SETTINGS 表字段
SETTINGS.ReadConfig()
--获取当前客户端语言
function SETTINGS.GetLang()
    if not SETTINGS.Lang then
        local buff = api.Ability:GetBuffTooltip(1)
        if buff and buff.name then
            if buff.name == "疲劳值" then
                SETTINGS.Lang = "zh"
            elseif buff.name == "Fatigue" then
                SETTINGS.Lang = "en"
            elseif buff.name == "Усталость" then
                SETTINGS.Lang = "ru"
            else
                SETTINGS.Lang = "unknown"
            end
        else
            return "unknown"
        end
    end
    return SETTINGS.Lang
end

return SETTINGS