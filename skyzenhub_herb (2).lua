local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local TS = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local VIM = game:GetService("VirtualInputManager")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

------------------------------------------------------------
-- SETTINGS (edit here)
------------------------------------------------------------
local TITLE = "SKYZENHUB (Herb Auto Collect)"
local PHOTO_URL = "https://raw.githubusercontent.com/SkyzenHub/FOTO-SKYZEN/refs/heads/main/file_00000000f5548211add457d612909d05.png"
local LOGO_URL = PHOTO_URL
local LOADING_URL = "https://raw.githubusercontent.com/SkyzenHub/FOTO-SKYZEN/refs/heads/main/1794024795815.jpg"
local LOAD_TIME = 10

local CONFIG = {
    ENABLED = true,
    FARM = false,
    TWEEN_SPEED = 150,   -- 10 - 500
    SCAN_DELAY = 100,    -- ms, 0 - 1000
    PURGE = false,
    ESP_HERB = false,
    MEDITATE = false,
    BREAKTHROUGH = false,
    BT_INTERVAL = 3,     -- seconds, 1 - 60
    BT_DELAY = 3,        -- seconds the minigame takes before the result is sent, 1 - 15
}

local TIERS = { 1000, 100, 10, 1 }

------------------------------------------------------------
-- AUTO SAVE
------------------------------------------------------------
local SAVE_FILE = "SkyZenHub_Herb.json"
local SAVE_KEYS = {"TWEEN_SPEED", "SCAN_DELAY", "BT_INTERVAL", "BT_DELAY"}
local ConfigLocked = false

local function LoadConfig()
    if not (isfile and readfile) then return end
    local ok, data = pcall(function()
        if not isfile(SAVE_FILE) then return nil end
        return HttpService:JSONDecode(readfile(SAVE_FILE))
    end)
    if ok and type(data) == "table" then
        for _, key in ipairs(SAVE_KEYS) do
            if type(data[key]) == type(CONFIG[key]) then CONFIG[key] = data[key] end
        end
    end
end

local function SaveNow()
    if not writefile or ConfigLocked then return end
    local data = {}
    for _, key in ipairs(SAVE_KEYS) do data[key] = CONFIG[key] end
    pcall(function() writefile(SAVE_FILE, HttpService:JSONEncode(data)) end)
end

local savePending = false
local function SaveConfig()
    if savePending then return end
    savePending = true
    task.delay(0.5, function()
        savePending = false
        SaveNow()
    end)
end

LoadConfig()

------------------------------------------------------------
-- HERB LOGIC
------------------------------------------------------------
local farmId = 0
local HAS_FIRE_PROMPT = type(fireproximityprompt) == "function"

local hooked = {}
local function hookPrompt(obj)
    if obj:IsA("ProximityPrompt") and obj.Name == "CollectHerbPrompt" then
        obj.HoldDuration = 0
    end
end

local function hookSpots(spots)
    if hooked[spots] then return end
    hooked[spots] = true
    for _, d in ipairs(spots:GetDescendants()) do hookPrompt(d) end
    spots.DescendantAdded:Connect(hookPrompt)
end

local function purgeMap(spots)
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj ~= spots
            and obj ~= workspace.CurrentCamera
            and obj.Name ~= "Terrain"
            and not Players:GetPlayerFromCharacter(obj)
            and (obj:IsA("BasePart") or obj:IsA("Model") or obj:IsA("Folder")) then
            pcall(function() obj:Destroy() end)
        end
    end
end

local function getPos(obj)
    if obj:IsA("Model") then return obj:GetPivot().Position end
    if obj:IsA("BasePart") then return obj.Position end
end

local function moveTo(hrp, pos, id)
    local cf = CFrame.new(pos + Vector3.new(0, 3, 0))
    local dist = (hrp.Position - cf.Position).Magnitude
    if dist < 5 then
        hrp.CFrame = cf
        return true
    end

    local t = math.max(dist / CONFIG.TWEEN_SPEED, 0.02)
    local tw = TS:Create(hrp, TweenInfo.new(t, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut), {CFrame = cf})
    local done = false
    local conn = tw.Completed:Connect(function() done = true end)
    tw:Play()

    while not done and CONFIG.FARM and farmId == id do
        task.wait(0.01)
    end
    conn:Disconnect()

    if not done then
        tw:Cancel()
        return false
    end
    hrp.CFrame = cf
    return true
end

local function findTarget(spots)
    for _, tier in ipairs(TIERS) do
        for _, spot in ipairs(spots:GetChildren()) do
            if spot.Parent and spot:GetAttribute("HerbYear") == tier then
                local prompt = spot:FindFirstChild("CollectHerbPrompt", true)
                local pos = getPos(spot)
                if prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled and pos then
                    return spot, prompt, pos, tier
                end
            end
        end
    end
end

local function farmLoop(id)
    local purged = false
    while CONFIG.ENABLED and CONFIG.FARM and farmId == id do
        local spots = workspace:FindFirstChild("HerbSpots")
        if not spots then
            task.wait(1)
        else
            hookSpots(spots)
            if CONFIG.PURGE and not purged then
                purged = true
                purgeMap(spots)
            end

            local spot, prompt, pos, tier = findTarget(spots)
            if spot then
                local char = LocalPlayer.Character
                local hrp = char and char:FindFirstChild("HumanoidRootPart")
                if hrp then
                    if moveTo(hrp, pos, id) and CONFIG.FARM and farmId == id
                        and prompt.Parent and prompt.Enabled then
                        if HAS_FIRE_PROMPT then
                            pcall(fireproximityprompt, prompt)
                        else
                            -- fallback only for executors without fireproximityprompt
                            VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                            task.wait(0.02)
                            VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game)
                        end
                        task.wait(0.1)
                    end
                else
                    task.wait(0.5)
                end
            else
                task.wait(CONFIG.SCAN_DELAY / 1000)
            end
        end
    end
end

local function setFarm(v)
    CONFIG.FARM = v
    farmId = farmId + 1
    if v then
        task.spawn(farmLoop, farmId)
    else
        if not HAS_FIRE_PROMPT then
            pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game) end)
        end
    end
end

-- ESP Herb (label per herb: tier + distance, visible through walls)
local espHerbs = {}
local espLoopId = 0
local TIER_COLORS = {
    [1000] = Color3.fromRGB(255, 215, 0),
    [100] = Color3.fromRGB(180, 90, 255),
    [10] = Color3.fromRGB(80, 160, 255),
    [1] = Color3.fromRGB(90, 255, 120),
}

local function clearEspHerbs()
    for _, d in pairs(espHerbs) do
        pcall(function() d.bb:Destroy() end)
    end
    espHerbs = {}
end

local function addHerbEsp(spot, tier)
    local adornee = spot:IsA("BasePart") and spot or spot:FindFirstChildWhichIsA("BasePart", true)
    if not adornee then return end

    local bb = Instance.new("BillboardGui")
    bb.Name = "HerbESP"
    bb.Size = UDim2.new(0, 160, 0, 24)
    bb.AlwaysOnTop = true
    bb.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
    bb.Adornee = adornee
    bb.Parent = adornee

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 1, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextSize = 13
    label.TextColor3 = TIER_COLORS[tier] or Color3.new(1, 1, 1)
    label.TextStrokeTransparency = 0
    label.Text = "Tier " .. tostring(tier)
    label.Parent = bb

    espHerbs[spot] = { bb = bb, label = label }
end

local function setEspHerb(v)
    CONFIG.ESP_HERB = v
    espLoopId = espLoopId + 1
    clearEspHerbs()
    if not v then return end

    local id = espLoopId
    task.spawn(function()
        while CONFIG.ENABLED and CONFIG.ESP_HERB and espLoopId == id do
            local spots = workspace:FindFirstChild("HerbSpots")
            if spots then
                local char = LocalPlayer.Character
                local myRoot = char and char:FindFirstChild("HumanoidRootPart")
                local seen = {}

                for _, spot in ipairs(spots:GetChildren()) do
                    local tier = spot:GetAttribute("HerbYear")
                    local prompt = tier and spot:FindFirstChild("CollectHerbPrompt", true)
                    if prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled then
                        seen[spot] = true
                        local d = espHerbs[spot]
                        if not d or not d.bb.Parent then
                            addHerbEsp(spot, tier)
                            d = espHerbs[spot]
                        end
                        if d then
                            local text = "Tier " .. tostring(tier)
                            local pos = getPos(spot)
                            if myRoot and pos then
                                text = text .. " | " .. math.floor((pos - myRoot.Position).Magnitude) .. "m"
                            end
                            d.label.Text = text
                        end
                    end
                end

                -- remove labels of herbs that were collected or removed
                local stale = {}
                for spot in pairs(espHerbs) do
                    if not seen[spot] then stale[#stale + 1] = spot end
                end
                for _, spot in ipairs(stale) do
                    pcall(function() espHerbs[spot].bb:Destroy() end)
                    espHerbs[spot] = nil
                end
            end
            task.wait(0.3)
        end
        if espLoopId == id then clearEspHerbs() end
    end)
end

-- Cultivation (remotes found with Cobalt)
local function getCultivationEvent(name)
    local folder = ReplicatedStorage:FindFirstChild("CultivationEvents")
    return folder and folder:FindFirstChild(name)
end

local function fireMeditate()
    local ev = getCultivationEvent("StartMeditate")
    if ev then pcall(function() ev:FireServer() end) end
end

local function setMeditate(v)
    CONFIG.MEDITATE = v
    if v then fireMeditate() end
end

-- start meditating again after every respawn while Auto Meditate is ON
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(2)
    if CONFIG.ENABLED and CONFIG.MEDITATE then fireMeditate() end
end)

local function copyCultivationRemotes()
    local folder = ReplicatedStorage:FindFirstChild("CultivationEvents")
    local lines = {}
    if folder then
        for _, c in ipairs(folder:GetChildren()) do
            lines[#lines + 1] = c.Name .. " (" .. c.ClassName .. ")"
        end
    else
        lines[1] = "CultivationEvents not found"
    end
    local text = table.concat(lines, "\n")
    if setclipboard then pcall(setclipboard, text) end
    print("[SkyZenHub] Cultivation remotes:\n" .. text)
end

local btId = 0
local function setBreakthrough(v)
    CONFIG.BREAKTHROUGH = v
    btId = btId + 1
    if not v then return end
    local id = btId
    task.spawn(function()
        while CONFIG.ENABLED and CONFIG.BREAKTHROUGH and btId == id do
            -- 1) start the breakthrough
            local startEv = getCultivationEvent("Breakthrough")
            if startEv then pcall(function() startEv:FireServer() end) end

            -- 2) wait while the minigame runs, then send the result
            task.wait(CONFIG.BT_DELAY)
            local resultEv = getCultivationEvent("BreakthroughMinigameResult")
            if resultEv then pcall(function() resultEv:FireServer(true) end) end

            task.wait(CONFIG.BT_INTERVAL)
        end
    end)
end

------------------------------------------------------------
-- UI
------------------------------------------------------------
local parent = (gethui and gethui()) or game:GetService("CoreGui")
if parent:FindFirstChild("SkyzenGUI") then parent.SkyzenGUI:Destroy() end

local RED = Color3.fromRGB(0, 0, 0)
local DARK = Color3.fromRGB(10, 10, 14)
local GREY = Color3.fromRGB(60, 60, 70)

local gui = Instance.new("ScreenGui")
gui.Name = "SkyzenGUI"
gui.ResetOnSpawn = false
gui.Parent = parent

local function isImage(data)
    if type(data) ~= "string" or #data < 100 then return false end
    local h = data:sub(1, 4)
    return h == "\137PNG" or h:sub(1, 2) == "\255\216" or h == "RIFF"
end

local function loadImage(url, fname)
    if url == "" then return nil, "empty URL" end
    if not writefile then return nil, "executor has no writefile" end
    local getAsset = getcustomasset or getsynasset
    if not getAsset then return nil, "executor has no getcustomasset" end

    local data
    local req = (syn and syn.request) or request or http_request
    if req then
        local ok, res = pcall(function() return req({Url = url, Method = "GET"}) end)
        if ok and res and isImage(res.Body) then data = res.Body end
    end
    if not data then
        local ok, r = pcall(function() return game:HttpGet(url) end)
        if ok and isImage(r) then data = r end
    end
    if not data then return nil, "download failed or not an image" end

    local ok3, err3 = pcall(writefile, fname, data)
    if not ok3 then return nil, "writefile failed: " .. tostring(err3) end
    local ok4, id = pcall(getAsset, fname)
    if not ok4 or not id then return nil, "getcustomasset failed" end
    return id
end

local photoId, photoErr = loadImage(PHOTO_URL, "skyzenhub_bg.png")
if not photoId then print("[SkyZenHub] Photo failed: " .. tostring(photoErr)) end
local logoId = photoId
if LOGO_URL ~= PHOTO_URL then
    logoId = loadImage(LOGO_URL, "skyzenhub_logo.png")
end
local loadingId = loadImage(LOADING_URL, "skyzenhub_loading.jpg") or photoId

local function makeLogo(obj)
    obj.BackgroundTransparency = 1
    local bg = Instance.new("Frame")
    bg.Size = UDim2.new(1, 0, 1, 0)
    bg.BackgroundColor3 = Color3.new(1, 1, 1)
    bg.BorderSizePixel = 0
    bg.ZIndex = 1
    bg.Parent = obj
    Instance.new("UICorner", bg).CornerRadius = UDim.new(1, 0)
    local g = Instance.new("UIGradient", bg)
    g.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, RED),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 0, 0)),
        ColorSequenceKeypoint.new(1, RED),
    })
    TS:Create(g, TweenInfo.new(3, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1), {Rotation = 360}):Play()
    local st = Instance.new("UIStroke", bg)
    st.Color = RED
    st.Thickness = 1.5

    if logoId then
        local img = Instance.new("ImageLabel")
        img.Size = UDim2.new(1, -4, 1, -4)
        img.Position = UDim2.new(0, 2, 0, 2)
        img.BackgroundTransparency = 1
        img.Image = logoId
        img.ScaleType = Enum.ScaleType.Crop
        img.ZIndex = 2
        img.Parent = obj
        Instance.new("UICorner", img).CornerRadius = UDim.new(1, 0)
    else
        local t = Instance.new("TextLabel")
        t.Size = UDim2.new(1, 0, 1, 0)
        t.BackgroundTransparency = 1
        t.Text = "SZ"
        t.Font = Enum.Font.GothamBlack
        t.TextScaled = true
        t.TextColor3 = Color3.new(1, 1, 1)
        t.ZIndex = 2
        t.Parent = obj
        Instance.new("UITextSizeConstraint", t).MaxTextSize = 20
    end
end

------------------------------------------------------------
-- LOADING SCREEN
------------------------------------------------------------
local loader = Instance.new("CanvasGroup")
loader.Name = "Loader"
loader.AnchorPoint = Vector2.new(0.5, 0.5)
loader.Position = UDim2.new(0.5, 0, 0.5, 0)
loader.Size = UDim2.new(0, 280, 0, 170)
loader.BackgroundTransparency = 1
loader.BorderSizePixel = 0
loader.Active = false
loader.ZIndex = 50
loader.Parent = gui

local lbg = Instance.new("Frame")
lbg.Size = UDim2.new(1, 0, 1, 0)
lbg.BackgroundColor3 = Color3.new(1, 1, 1)
lbg.BorderSizePixel = 0
lbg.Parent = loader
Instance.new("UICorner", lbg).CornerRadius = UDim.new(0, 14)
local lbgGrad = Instance.new("UIGradient", lbg)
lbgGrad.Rotation = 90
lbgGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 30, 34)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(6, 6, 10)),
})
local lbgStroke = Instance.new("UIStroke", lbg)
lbgStroke.Color = RED
lbgStroke.Thickness = 1.5
TS:Create(lbgStroke, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {Transparency = 0.7}):Play()

if loadingId then
    local lImgBg = Instance.new("ImageLabel")
    lImgBg.Size = UDim2.new(1, 0, 1, 0)
    lImgBg.BackgroundTransparency = 1
    lImgBg.Image = loadingId
    lImgBg.ScaleType = Enum.ScaleType.Crop
    lImgBg.ImageTransparency = 0.15
    lImgBg.Parent = lbg
    Instance.new("UICorner", lImgBg).CornerRadius = UDim.new(0, 14)

    local lShade = Instance.new("Frame")
    lShade.Size = UDim2.new(1, 0, 1, 0)
    lShade.BackgroundColor3 = Color3.new(1, 1, 1)
    lShade.BackgroundTransparency = 0.4
    lShade.BorderSizePixel = 0
    lShade.Parent = lbg
    Instance.new("UICorner", lShade).CornerRadius = UDim.new(0, 14)
end

local lLogo = Instance.new("Frame")
lLogo.AnchorPoint = Vector2.new(0.5, 0)
lLogo.Position = UDim2.new(0.5, 0, 0, 18)
lLogo.Size = UDim2.new(0, 56, 0, 56)
lLogo.Parent = loader
makeLogo(lLogo)

local lTitle = Instance.new("TextLabel")
lTitle.Position = UDim2.new(0, 0, 0, 82)
lTitle.Size = UDim2.new(1, 0, 0, 24)
lTitle.BackgroundTransparency = 1
lTitle.Text = "SKYZENHUB"
lTitle.Font = Enum.Font.GothamBlack
lTitle.TextSize = 16
lTitle.TextColor3 = Color3.fromRGB(0, 0, 0)
lTitle.Parent = loader

local lStatus = Instance.new("TextLabel")
lStatus.Position = UDim2.new(0, 0, 0, 108)
lStatus.Size = UDim2.new(1, 0, 0, 18)
lStatus.BackgroundTransparency = 1
lStatus.Text = "Initializing..."
lStatus.Font = Enum.Font.GothamBlack
lStatus.TextSize = 13
lStatus.TextColor3 = Color3.fromRGB(0, 0, 0)
lStatus.Parent = loader

local lBar = Instance.new("Frame")
lBar.AnchorPoint = Vector2.new(0.5, 0)
lBar.Position = UDim2.new(0.5, 0, 0, 138)
lBar.Size = UDim2.new(0, 220, 0, 6)
lBar.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
lBar.BorderSizePixel = 0
lBar.Parent = loader
Instance.new("UICorner", lBar).CornerRadius = UDim.new(1, 0)

local lFill = Instance.new("Frame")
lFill.Size = UDim2.new(0, 0, 1, 0)
lFill.BackgroundColor3 = RED
lFill.BorderSizePixel = 0
lFill.Parent = lBar
Instance.new("UICorner", lFill).CornerRadius = UDim.new(1, 0)

local function setProgress(p, text, dur)
    lStatus.Text = text
    TS:Create(lFill, TweenInfo.new(dur or 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = UDim2.new(p, 0, 1, 0)}):Play()
end

local loadStart = os.clock()
setProgress(0.1, "Initializing...", 1.2)
task.wait(1.5)

------------------------------------------------------------
-- MAIN WINDOW
------------------------------------------------------------
local main = Instance.new("Frame")
main.Size = UDim2.new(0, 340, 0, 280)
main.Position = UDim2.new(0.5, -170, 0.5, -140)
main.BackgroundColor3 = DARK
main.ClipsDescendants = true
main.Visible = false
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 12)

local grad = Instance.new("UIGradient", main)
grad.Rotation = 90
grad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 30, 34)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(6, 6, 10)),
})

local stroke = Instance.new("UIStroke", main)
stroke.Color = RED
stroke.Thickness = 1.5
TS:Create(stroke, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {Transparency = 0.7}):Play()

setProgress(0.3, "Loading assets...", 1)

if photoId then
    local bgImg = Instance.new("ImageLabel")
    bgImg.Size = UDim2.new(1, 0, 1, 0)
    bgImg.BackgroundTransparency = 1
    bgImg.Image = photoId
    bgImg.ScaleType = Enum.ScaleType.Crop
    bgImg.ZIndex = 1
    bgImg.Parent = main
    Instance.new("UICorner", bgImg).CornerRadius = UDim.new(0, 12)

    local shade = Instance.new("Frame")
    shade.Size = UDim2.new(1, 0, 1, 0)
    shade.BackgroundColor3 = Color3.new(0, 0, 0)
    shade.BackgroundTransparency = 0.45
    shade.BorderSizePixel = 0
    shade.ZIndex = 1
    shade.Parent = main
    Instance.new("UICorner", shade).CornerRadius = UDim.new(0, 12)
end

setProgress(0.5, "Building interface...", 1)

-- Header
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 42)
header.BackgroundTransparency = 1
header.Parent = main

local logo = Instance.new("Frame")
logo.Size = UDim2.new(0, 30, 0, 30)
logo.Position = UDim2.new(0, 10, 0, 6)
logo.Parent = header
makeLogo(logo)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -130, 1, 0)
title.Position = UDim2.new(0, 48, 0, 0)
title.BackgroundTransparency = 1
title.Text = TITLE
title.Font = Enum.Font.GothamBlack
title.TextSize = 13
title.TextColor3 = Color3.fromRGB(235, 235, 240)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local function topBtn(text, x)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 28, 0, 24)
    b.Position = UDim2.new(1, x, 0, 9)
    b.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    b.Text = text
    b.Font = Enum.Font.GothamBold
    b.TextSize = 14
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Parent = header
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end
local minBtn = topBtn("-", -66)
local closeBtn = topBtn("X", -34)

local line = Instance.new("Frame")
line.Size = UDim2.new(1, -24, 0, 1)
line.Position = UDim2.new(0, 12, 0, 44)
line.BackgroundColor3 = GREY
line.BorderSizePixel = 0
line.Parent = main

-- Tab bar
local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, -24, 0, 28)
tabBar.Position = UDim2.new(0, 12, 0, 52)
tabBar.BackgroundTransparency = 1
tabBar.Parent = main
local tl = Instance.new("UIListLayout", tabBar)
tl.FillDirection = Enum.FillDirection.Horizontal
tl.Padding = UDim.new(0, 6)

local pages = {}
local tabButtons = {}

local function selectTab(name)
    for n, page in pairs(pages) do
        page.Visible = (n == name)
        tabButtons[n].BackgroundColor3 = (n == name) and RED or Color3.fromRGB(25, 25, 30)
    end
end

local function createTab(name)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 70, 1, 0)
    b.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    b.Text = name
    b.Font = Enum.Font.GothamBold
    b.TextSize = 11
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Parent = tabBar
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    tabButtons[name] = b

    local page = Instance.new("ScrollingFrame")
    page.Size = UDim2.new(1, -24, 1, -92)
    page.Position = UDim2.new(0, 12, 0, 86)
    page.BackgroundTransparency = 1
    page.BorderSizePixel = 0
    page.ScrollBarThickness = 3
    page.CanvasSize = UDim2.new(0, 0, 0, 0)
    page.AutomaticCanvasSize = Enum.AutomaticSize.Y
    page.Visible = false
    page.Parent = main
    Instance.new("UIListLayout", page).Padding = UDim.new(0, 4)
    pages[name] = page

    b.MouseButton1Click:Connect(function() selectTab(name) end)
    return page
end

local function addToggle(page, name, default, callback)
    local state = default
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -6, 0, 30)
    b.BackgroundColor3 = Color3.fromRGB(55, 55, 64)
    b.BackgroundTransparency = 0.1
    b.Font = Enum.Font.GothamBold
    b.TextSize = 13
    b.TextColor3 = Color3.fromRGB(220, 220, 225)
    b.Parent = page
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
    local s = Instance.new("UIStroke", b)
    b.Text = ""

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    fill.BorderSizePixel = 0
    fill.Parent = b
    Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 8)

    local shine = Instance.new("UIGradient", fill)
    shine.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(95, 95, 105)),
        ColorSequenceKeypoint.new(0.3, Color3.fromRGB(0, 0, 0)),
        ColorSequenceKeypoint.new(0.7, Color3.fromRGB(0, 0, 0)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(95, 95, 105)),
    })
    local shimmer = nil

    local txt = Instance.new("TextLabel")
    txt.Size = UDim2.new(1, 0, 1, 0)
    txt.BackgroundTransparency = 1
    txt.Font = Enum.Font.GothamBold
    txt.TextSize = 13
    txt.TextColor3 = Color3.new(1, 1, 1)
    txt.Parent = b

    local function refresh(animate)
        txt.Text = name .. "  :  " .. (state and "ON" or "OFF")
        local goalSize = UDim2.new(state and 1 or 0, 0, 1, 0)
        local goalColor = state and Color3.fromRGB(0, 0, 0) or GREY
        if animate then
            TS:Create(fill, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = goalSize}):Play()
            TS:Create(s, TweenInfo.new(0.35), {Color = goalColor, Thickness = state and 2.5 or 1}):Play()
        else
            fill.Size = goalSize
            s.Color = goalColor
            s.Thickness = state and 2.5 or 1
        end
        if state then
            if not shimmer then
                shine.Offset = Vector2.new(-1, 0)
                shimmer = TS:Create(shine, TweenInfo.new(1.4, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1), {Offset = Vector2.new(1, 0)})
                shimmer:Play()
            end
        elseif shimmer then
            shimmer:Cancel()
            shimmer = nil
        end
    end
    refresh(false)

    b.MouseButton1Click:Connect(function()
        state = not state
        refresh(true)
        pcall(callback, state)
        SaveConfig()
    end)
end

local function addStepper(page, name, min, max, step, default, callback)
    local value = default
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, -6, 0, 34)
    f.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
    f.BackgroundTransparency = 0.25
    f.Parent = page
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 8)
    local fs = Instance.new("UIStroke", f)
    fs.Color = GREY

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -90, 1, 0)
    lbl.Position = UDim2.new(0, 10, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 13
    lbl.TextColor3 = Color3.fromRGB(220, 220, 225)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = f

    local function render() lbl.Text = name .. "  :  " .. tostring(value) end
    render()

    local function btn(text, x, delta)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0, 34, 0, 24)
        b.Position = UDim2.new(1, x, 0.5, -12)
        b.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        b.Text = text
        b.Font = Enum.Font.GothamBold
        b.TextSize = 16
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Parent = f
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
        b.MouseButton1Click:Connect(function()
            value = math.clamp(value + delta, min, max)
            render()
            pcall(callback, value)
            SaveConfig()
        end)
    end
    btn("-", -80, -step)
    btn("+", -40, step)
end

local function addButton(page, name, callback)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -6, 0, 30)
    b.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    b.Text = name
    b.Font = Enum.Font.GothamBold
    b.TextSize = 13
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Parent = page
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
    local s = Instance.new("UIStroke", b)
    s.Color = GREY
    b.MouseButton1Click:Connect(function() pcall(callback) end)
end

-- Tab Farm
local FarmTab = createTab("Farm")
addToggle(FarmTab, "Auto Farm Herb", CONFIG.FARM, setFarm)
addToggle(FarmTab, "ESP Herb (Tier + Distance)", CONFIG.ESP_HERB, setEspHerb)
addStepper(FarmTab, "Tween Speed", 10, 500, 10, CONFIG.TWEEN_SPEED, function(v) CONFIG.TWEEN_SPEED = v end)
addStepper(FarmTab, "Scan Delay (ms)", 0, 1000, 50, CONFIG.SCAN_DELAY, function(v) CONFIG.SCAN_DELAY = v end)
addToggle(FarmTab, "Purge Map (reduce lag)", CONFIG.PURGE, function(v) CONFIG.PURGE = v end)

-- Tab Cultivate
local CultTab = createTab("Cultivate")
addToggle(CultTab, "Auto Meditate", CONFIG.MEDITATE, setMeditate)
addToggle(CultTab, "Auto Breakthrough", CONFIG.BREAKTHROUGH, setBreakthrough)
addStepper(CultTab, "Minigame Delay (s)", 1, 15, 1, CONFIG.BT_DELAY, function(v) CONFIG.BT_DELAY = v end)
addStepper(CultTab, "Breakthrough Interval (s)", 1, 60, 1, CONFIG.BT_INTERVAL, function(v) CONFIG.BT_INTERVAL = v end)
addButton(CultTab, "Copy Remote List (debug)", copyCultivationRemotes)

selectTab("Farm")

-- Icon shown when minimized
local icon = Instance.new("TextButton")
icon.Size = UDim2.new(0, 50, 0, 50)
icon.Position = UDim2.new(0, 15, 0.4, 0)
icon.Text = ""
icon.Visible = false
icon.Parent = gui
makeLogo(icon)

minBtn.MouseButton1Click:Connect(function() main.Visible = false icon.Visible = true end)
icon.MouseButton1Click:Connect(function() main.Visible = true icon.Visible = false end)

-- Delete script confirmation
local confirm = Instance.new("Frame")
confirm.Size = UDim2.new(1, 0, 1, 0)
confirm.BackgroundColor3 = Color3.new(0, 0, 0)
confirm.BackgroundTransparency = 0.35
confirm.BorderSizePixel = 0
confirm.Active = true
confirm.Visible = false
confirm.ZIndex = 20
confirm.Parent = main

local box = Instance.new("Frame")
box.AnchorPoint = Vector2.new(0.5, 0.5)
box.Position = UDim2.new(0.5, 0, 0.5, 0)
box.Size = UDim2.new(0, 260, 0, 130)
box.BackgroundColor3 = DARK
box.ZIndex = 21
box.Parent = confirm
Instance.new("UICorner", box).CornerRadius = UDim.new(0, 10)
local bs = Instance.new("UIStroke", box)
bs.Color = GREY
bs.Thickness = 1.5

local ct = Instance.new("TextLabel")
ct.Size = UDim2.new(1, -20, 0, 24)
ct.Position = UDim2.new(0, 10, 0, 12)
ct.BackgroundTransparency = 1
ct.Text = "Delete script?"
ct.Font = Enum.Font.GothamBlack
ct.TextSize = 16
ct.TextColor3 = Color3.fromRGB(235, 235, 240)
ct.ZIndex = 22
ct.Parent = box

local cs = Instance.new("TextLabel")
cs.Size = UDim2.new(1, -20, 0, 34)
cs.Position = UDim2.new(0, 10, 0, 38)
cs.BackgroundTransparency = 1
cs.Text = "The script will be closed and all features turned off."
cs.Font = Enum.Font.Gotham
cs.TextSize = 12
cs.TextWrapped = true
cs.TextColor3 = Color3.fromRGB(190, 190, 200)
cs.ZIndex = 22
cs.Parent = box

local function confirmBtn(text, x, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0.5, -15, 0, 32)
    b.Position = UDim2.new(x, x == 0 and 10 or 5, 1, -42)
    b.BackgroundColor3 = color
    b.Text = text
    b.Font = Enum.Font.GothamBold
    b.TextSize = 13
    b.TextColor3 = Color3.new(1, 1, 1)
    b.ZIndex = 22
    b.Parent = box
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
    return b
end
local cancelBtn = confirmBtn("Cancel", 0, Color3.fromRGB(35, 35, 42))
local yesBtn = confirmBtn("Yes, Delete", 0.5, RED)

closeBtn.MouseButton1Click:Connect(function() confirm.Visible = true end)
cancelBtn.MouseButton1Click:Connect(function() confirm.Visible = false end)
yesBtn.MouseButton1Click:Connect(function()
    SaveNow()
    ConfigLocked = true
    CONFIG.ENABLED = false
    CONFIG.FARM = false
    farmId = farmId + 1
    if not HAS_FIRE_PROMPT then
        pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game) end)
    end
    gui:Destroy()
end)

-- Dragging
local function makeDraggable(handle, obj)
    local dragging, start, startPos
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            start = i.Position
            startPos = obj.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseMovement) then
            local d = i.Position - start
            obj.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end
makeDraggable(header, main)
makeDraggable(icon, icon)

print("[SkyZenHub] Loaded")

-- Finish loading, then show the window
local remaining = math.max(0, LOAD_TIME - (os.clock() - loadStart) - 0.6)
local stages = {
    {0.68, "Loading modules..."},
    {0.84, "Preparing features..."},
    {0.96, "Almost ready..."},
}
for _, st in ipairs(stages) do
    local d = remaining / #stages
    setProgress(st[1], st[2], d)
    task.wait(d)
end
setProgress(1, "Ready", 0.4)
task.wait(0.6)

local mainScale = Instance.new("UIScale", main)
mainScale.Scale = 0.85
main.Visible = true
TS:Create(mainScale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()
TS:Create(loader, TweenInfo.new(0.35), {GroupTransparency = 1}):Play()
task.wait(0.4)
loader:Destroy()
