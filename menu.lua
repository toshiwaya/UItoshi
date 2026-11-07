--[[
    MenuLib - a small menu UI library for Roblox (Luau). No dependencies.

    Quick start
        local Library = loadstring(readfile("MenuLib.lua"))()

        local Window = Library:CreateWindow({ Title = "My menu", Keybind = Enum.KeyCode.RightShift })
        local Tab = Window:AddTab("Main")

        Tab:AddSection("Controls")
        Tab:AddButton({ Name = "Say hello", Callback = function() print("hello") end })
        Tab:AddToggle({ Name = "Enabled", Default = false, Callback = function(on) print(on) end })
        Tab:AddSlider({ Name = "Amount", Min = 0, Max = 100, Default = 25, Callback = function(value) print(value) end })
        Tab:AddDropdown({ Name = "Mode", Options = { "Easy", "Normal", "Hard" }, Default = "Normal", Callback = function(choice) print(choice) end })
        Tab:AddTextBox({ Name = "Name", Placeholder = "Type here", Callback = function(text, enterPressed) print(text) end })
        Tab:AddKeybind({ Name = "Action", Default = Enum.KeyCode.E, Callback = function() print("pressed") end })
        Tab:AddLabel("Plain text")

        Library:Notify({ Title = "Ready", Text = "The menu is loaded.", Duration = 4 })

    Library
        Library:CreateWindow({ Title, Keybind, Size = Vector2.new(540, 360), ToggleButton })
            Keybind        key that shows/hides the window (default RightShift)
            ToggleButton   floating "Menu" button; on by default for touch devices
        Library:Notify({ Title, Text, Duration })   or   Library:Notify("text")
        Library:Destroy()
        Library.Theme      colors and fonts - change these BEFORE building the UI
        Library.Elements   element builders - add your own: function(ctx, opts)

    Window
        Window:AddTab(name)  ->  Tab
        Window:SelectTab(tab)  Window:SetTitle(text)  Window:SetVisible(bool)
        Window:Toggle()  Window:Destroy()

    Elements (called on a Tab)
        AddButton   { Name, Callback() }
        AddToggle   { Name, Default = false, Callback(on) }
        AddSlider   { Name, Min = 0, Max = 100, Default, Increment = 1, Suffix = "", Callback(value) }
        AddDropdown { Name, Options = {...}, Default, Placeholder, Callback(choice) }
        AddTextBox  { Name, Default, Placeholder, Callback(text, enterPressed) }
        AddKeybind  { Name, Default = Enum.KeyCode.X, Callback(key), Changed(key) }
        AddLabel    "text"   or   { Text }
        AddSection  "title"  or   { Name }

    Each element returns an object:
        Toggle:Set(bool, silent)        Toggle:Get()
        Slider:Set(number, silent)      Slider:Get()
        Dropdown:Set(value, silent)     Dropdown:Get()     Dropdown:SetOptions(list)
        TextBox:Set(text)               TextBox:Get()
        Keybind:Set(keyCode, silent)    Keybind:Get()
        Label:Set(text)                 Button:SetText(text)

    Notes
        - Callbacks fire on user changes. A Default does not fire its callback; use :Get().
        - Keybind: Escape cancels while rebinding, Backspace clears the key.
        - Callback errors are caught and printed with warn(), so one bad callback
          cannot break the menu.
        - The menu mounts in gethui() or CoreGui, and falls back to PlayerGui, so the
          same file also works when pasted into Studio for testing.
]]

-- If the script is executed twice, remove the previous menu first.
local env = (getgenv and getgenv()) or _G
if env.__MenuLib then
    pcall(function()
        env.__MenuLib:Destroy()
    end)
end

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local GUI_NAME = "MenuLib"
local ROW_H = 34
local TOPBAR_H = 38
local SIDEBAR_W = 140

-- Builder Sans is Roblox's own UI face; older clients fall back to Gotham.
local function pickFont(name, fallback)
    local ok, font = pcall(function()
        return Enum.Font[name]
    end)
    return ok and font or fallback
end

-- Monochrome theme: black surfaces, white text, and one grey accent.
-- There is intentionally no colour picker; the menu stays black and white.
local Library = {
    Theme = {
        Background   = Color3.fromRGB(9, 9, 9),
        Topbar       = Color3.fromRGB(14, 14, 14),
        Element      = Color3.fromRGB(22, 22, 22),
        ElementHover = Color3.fromRGB(32, 32, 32),
        Stroke       = Color3.fromRGB(50, 50, 50),
        Text         = Color3.fromRGB(245, 245, 245),
        SubText      = Color3.fromRGB(145, 145, 145),
        Accent       = Color3.fromRGB(190, 190, 190),
        Font         = pickFont("BuilderSansMedium", Enum.Font.GothamMedium),
        FontBold     = pickFont("BuilderSansBold", Enum.Font.GothamBold),
    },
    Elements = {},
    _windows = {},
    _root = nil,
}
local Theme = Library.Theme
local Elements = Library.Elements

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------

-- Creates an instance, applies properties, adds children, parents last.
local function new(className, props, children)
    local inst = Instance.new(className)
    local parent
    for key, value in pairs(props or {}) do
        if key == "Parent" then
            parent = value
        else
            inst[key] = value
        end
    end
    for _, child in ipairs(children or {}) do
        child.Parent = inst
    end
    inst.Parent = parent
    return inst
end

local function tween(inst, duration, goal, style)
    local info = TweenInfo.new(duration, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local t = TweenService:Create(inst, info, goal)
    t:Play()
    return t
end

local function safeCall(fn, ...)
    if type(fn) ~= "function" then
        return
    end
    local ok, err = pcall(fn, ...)
    if not ok then
        warn("[MenuLib] callback error: " .. tostring(err))
    end
end

local function corner(px)
    return new("UICorner", { CornerRadius = UDim.new(0, px or 6) })
end

local function stroke(color)
    return new("UIStroke", {
        Color = color or Theme.Stroke,
        Thickness = 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
end

local function isPress(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

local function isMove(input)
    return input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch
end

local function decimals(n)
    local s = tostring(n)
    local dot = s:find(".", 1, true)
    return dot and (#s - dot) or 0
end

-- Clamp to [min, max], snap to the step, and strip floating point noise.
local function snap(value, min, max, step)
    value = math.clamp(value, min, max)
    if step > 0 then
        value = min + math.floor((value - min) / step + 0.5) * step
    end
    value = math.clamp(value, min, max)
    local places = math.max(decimals(step), decimals(min))
    return tonumber(string.format("%." .. places .. "f", value))
end

-- Hover colour for a clickable row. Returns a function telling if it is hovered.
local function hover(button, target)
    target = target or button
    local hovering = false
    button.MouseEnter:Connect(function()
        hovering = true
        tween(target, 0.12, { BackgroundColor3 = Theme.ElementHover })
    end)
    button.MouseLeave:Connect(function()
        hovering = false
        tween(target, 0.12, { BackgroundColor3 = Theme.Element })
    end)
    return function()
        return hovering
    end
end

---------------------------------------------------------------------
-- Root ScreenGui
---------------------------------------------------------------------

local function getRoot()
    if Library._root and Library._root.Parent then
        return Library._root
    end

    local gui = new("ScreenGui", {
        Name = GUI_NAME,
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 100,
    })

    local mounted = pcall(function()
        gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
    end)
    if not mounted or not gui.Parent then
        gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
    end

    -- Remove leftovers from an earlier run that could not be reached.
    for _, child in ipairs(gui.Parent:GetChildren()) do
        if child ~= gui and child.Name == GUI_NAME then
            child:Destroy()
        end
    end

    Library._root = gui
    return gui
end

---------------------------------------------------------------------
-- Elements
-- Every builder is  function(ctx, opts) -> object
--   ctx.page   the ScrollingFrame to build into
--   ctx.track  registers a global connection so Window:Destroy() cleans it up
---------------------------------------------------------------------

local function makeRow(ctx, class, height)
    local props = {
        Size = UDim2.new(1, 0, 0, height or ROW_H),
        BackgroundColor3 = Theme.Element,
        BorderSizePixel = 0,
        Parent = ctx.page,
    }
    if class == "TextButton" then
        props.AutoButtonColor = false
        props.Text = ""
    end
    return new(class or "Frame", props, { corner(6) })
end

local function nameLabel(parent, text, size)
    return new("TextLabel", {
        Position = UDim2.fromOffset(12, 0),
        Size = size or UDim2.new(1, -24, 0, ROW_H),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = Theme.Text,
        Font = Theme.Font,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = parent,
    })
end

function Elements.Section(ctx, opts)
    local holder = new("Frame", {
        Size = UDim2.new(1, 0, 0, 28),
        BackgroundTransparency = 1,
        Parent = ctx.page,
    })
    local label = new("TextLabel", {
        Size = UDim2.new(1, 0, 1, -5),
        BackgroundTransparency = 1,
        Text = opts.Name or opts.Text or "Section",
        TextColor3 = Theme.SubText,
        Font = Theme.FontBold,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Bottom,
        Parent = holder,
    })
    new("Frame", {
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.fromScale(0, 1),
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = Theme.Stroke,
        BorderSizePixel = 0,
        Parent = holder,
    })

    local object = {}
    function object:Set(text)
        label.Text = tostring(text)
    end
    return object
end

function Elements.Label(ctx, opts)
    local label = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 20),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Text = opts.Text or opts.Name or "",
        TextColor3 = Theme.SubText,
        Font = Theme.Font,
        TextSize = 13,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = ctx.page,
    })

    local object = {}
    function object:Set(text)
        label.Text = tostring(text)
    end
    return object
end

function Elements.Button(ctx, opts)
    local button = makeRow(ctx, "TextButton")
    button.Text = opts.Name or "Button"
    button.TextColor3 = Theme.Text
    button.Font = Theme.Font
    button.TextSize = 14

    local isHovering = hover(button)
    button.MouseButton1Down:Connect(function()
        tween(button, 0.08, { BackgroundColor3 = Theme.Stroke })
    end)
    button.MouseButton1Up:Connect(function()
        tween(button, 0.15, { BackgroundColor3 = isHovering() and Theme.ElementHover or Theme.Element })
    end)
    button.MouseButton1Click:Connect(function()
        safeCall(opts.Callback)
    end)

    local object = {}
    function object:SetText(text)
        button.Text = tostring(text)
    end
    return object
end

function Elements.Toggle(ctx, opts)
    local state = opts.Default == true

    local row = makeRow(ctx, "TextButton")
    nameLabel(row, opts.Name or "Toggle", UDim2.new(1, -68, 0, ROW_H))
    local track = new("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(36, 18),
        BackgroundColor3 = Theme.Stroke,
        BorderSizePixel = 0,
        Parent = row,
    }, { corner(99) })
    local knob = new("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 2, 0.5, 0),
        Size = UDim2.fromOffset(14, 14),
        BackgroundColor3 = Theme.Text,
        BorderSizePixel = 0,
        Parent = track,
    }, { corner(99) })

    local function render(animate)
        local color = state and Theme.Accent or Theme.Stroke
        local position = UDim2.new(0, state and 20 or 2, 0.5, 0)
        if animate then
            tween(track, 0.15, { BackgroundColor3 = color })
            tween(knob, 0.15, { Position = position })
        else
            track.BackgroundColor3 = color
            knob.Position = position
        end
    end

    local object = {}
    function object:Set(value, silent)
        value = value and true or false
        if value == state then
            return
        end
        state = value
        render(true)
        if not silent then
            safeCall(opts.Callback, state)
        end
    end
    function object:Get()
        return state
    end

    hover(row)
    row.MouseButton1Click:Connect(function()
        object:Set(not state)
    end)
    render(false)
    return object
end

function Elements.Slider(ctx, opts)
    local min = opts.Min or 0
    local max = opts.Max or 100
    local step = opts.Increment or 1
    local suffix = opts.Suffix or ""
    local value = min

    local row = makeRow(ctx, "Frame", 52)
    nameLabel(row, opts.Name or "Slider", UDim2.new(1, -104, 0, 28))
    local valueLabel = new("TextLabel", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -12, 0, 0),
        Size = UDim2.fromOffset(80, 28),
        BackgroundTransparency = 1,
        TextColor3 = Theme.SubText,
        Font = Theme.Font,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Right,
        Parent = row,
    })
    local bar = new("Frame", {
        Position = UDim2.new(0, 12, 0, 36),
        Size = UDim2.new(1, -24, 0, 6),
        BackgroundColor3 = Theme.Stroke,
        BorderSizePixel = 0,
        Parent = row,
    }, { corner(99) })
    local fill = new("Frame", {
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = Theme.Accent,
        BorderSizePixel = 0,
        Parent = bar,
    }, { corner(99) })
    local knob = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(12, 12),
        BackgroundColor3 = Theme.Text,
        BorderSizePixel = 0,
        Parent = bar,
    }, { corner(99) })
    -- Taller invisible hit area so the thin bar is easy to grab.
    local hit = new("TextButton", {
        Position = UDim2.fromOffset(0, 26),
        Size = UDim2.new(1, 0, 1, -26),
        BackgroundTransparency = 1,
        Text = "",
        Parent = row,
    })

    local object = {}
    function object:Set(newValue, silent)
        newValue = snap(tonumber(newValue) or min, min, max, step)
        local changed = newValue ~= value
        value = newValue
        local alpha = (max > min) and (value - min) / (max - min) or 0
        fill.Size = UDim2.fromScale(alpha, 1)
        knob.Position = UDim2.fromScale(alpha, 0.5)
        valueLabel.Text = tostring(value) .. suffix
        if changed and not silent then
            safeCall(opts.Callback, value)
        end
    end
    function object:Get()
        return value
    end

    local dragging = false
    local function update(x)
        local width = bar.AbsoluteSize.X
        if width <= 0 then
            return
        end
        local alpha = math.clamp((x - bar.AbsolutePosition.X) / width, 0, 1)
        object:Set(min + (max - min) * alpha)
    end

    hit.InputBegan:Connect(function(input)
        if isPress(input) then
            dragging = true
            ctx.page.ScrollingEnabled = false
            update(input.Position.X)
        end
    end)
    ctx.track(UserInputService.InputChanged:Connect(function(input)
        if dragging and isMove(input) then
            update(input.Position.X)
        end
    end))
    ctx.track(UserInputService.InputEnded:Connect(function(input)
        if dragging and isPress(input) then
            dragging = false
            ctx.page.ScrollingEnabled = true
        end
    end))

    object:Set(opts.Default or min, true)
    return object
end

function Elements.Dropdown(ctx, opts)
    local ITEM_H, MAX_VISIBLE = 28, 5
    local options = opts.Options or {}
    local selected = opts.Default
    local isOpen = false
    local items = {}

    local holder = makeRow(ctx, "Frame")
    holder.ClipsDescendants = true
    local header = new("TextButton", {
        Size = UDim2.new(1, 0, 0, ROW_H),
        BackgroundTransparency = 1,
        Text = "",
        Parent = holder,
    })
    new("TextLabel", {
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(0.5, -12, 1, 0),
        BackgroundTransparency = 1,
        Text = opts.Name or "Dropdown",
        TextColor3 = Theme.Text,
        Font = Theme.Font,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = header,
    })
    local valueLabel = new("TextLabel", {
        Position = UDim2.fromScale(0.5, 0),
        Size = UDim2.new(0.5, -34, 1, 0),
        BackgroundTransparency = 1,
        TextColor3 = Theme.SubText,
        Font = Theme.Font,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = header,
    })
    local arrow = new("TextLabel", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(1, -16, 0.5, 0),
        Size = UDim2.fromOffset(16, 16),
        BackgroundTransparency = 1,
        Text = ">",
        TextColor3 = Theme.SubText,
        Font = Theme.FontBold,
        TextSize = 14,
        Parent = header,
    })
    local list = new("ScrollingFrame", {
        Position = UDim2.fromOffset(6, ROW_H + 2),
        Size = UDim2.new(1, -12, 0, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = Theme.Stroke,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Parent = holder,
    }, {
        new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
    })

    local function listHeight()
        local visible = math.min(#options, MAX_VISIBLE)
        return visible * ITEM_H + math.max(visible - 1, 0) * 2
    end

    local function setOpen(state)
        isOpen = state
        local height = listHeight()
        list.Size = UDim2.new(1, -12, 0, height)
        tween(holder, 0.18, { Size = UDim2.new(1, 0, 0, isOpen and (ROW_H + 2 + height + 6) or ROW_H) })
        tween(arrow, 0.18, { Rotation = isOpen and 90 or 0 })
    end

    local function refresh()
        if selected ~= nil then
            valueLabel.Text = tostring(selected)
            valueLabel.TextColor3 = Theme.SubText
        else
            valueLabel.Text = opts.Placeholder or "Choose one"
            valueLabel.TextColor3 = Theme.Stroke
        end
        for _, item in ipairs(items) do
            local active = item.value == selected
            item.button.BackgroundTransparency = active and 0 or 1
            item.button.TextColor3 = active and Theme.Accent or Theme.Text
        end
    end

    local object = {}
    function object:Set(value, silent)
        if value == selected then
            return
        end
        selected = value
        refresh()
        if not silent then
            safeCall(opts.Callback, selected)
        end
    end
    function object:Get()
        return selected
    end

    local function build()
        for _, item in ipairs(items) do
            item.button:Destroy()
        end
        items = {}
        for index, option in ipairs(options) do
            local button = new("TextButton", {
                Size = UDim2.new(1, -6, 0, ITEM_H),
                BackgroundColor3 = Theme.ElementHover,
                BackgroundTransparency = 1,
                AutoButtonColor = false,
                Text = tostring(option),
                TextColor3 = Theme.Text,
                Font = Theme.Font,
                TextSize = 13,
                LayoutOrder = index,
                Parent = list,
            }, { corner(4) })
            button.MouseButton1Click:Connect(function()
                object:Set(option)
                setOpen(false)
            end)
            table.insert(items, { value = option, button = button })
        end
        refresh()
    end

    function object:SetOptions(newOptions)
        options = newOptions or {}
        if table.find(options, selected) == nil then
            selected = nil
        end
        build()
        if isOpen then
            setOpen(true)
        end
    end

    hover(header, holder)
    header.MouseButton1Click:Connect(function()
        setOpen(not isOpen)
    end)
    build()
    return object
end

function Elements.TextBox(ctx, opts)
    local row = makeRow(ctx, "Frame")
    nameLabel(row, opts.Name or "Text", UDim2.new(0.45, -12, 0, ROW_H))

    local outline = stroke()
    local box = new("TextBox", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -8, 0.5, 0),
        Size = UDim2.new(0.55, -16, 0, 24),
        BackgroundColor3 = Theme.Background,
        BorderSizePixel = 0,
        ClearTextOnFocus = false,
        Text = opts.Default or "",
        PlaceholderText = opts.Placeholder or "Type here",
        PlaceholderColor3 = Theme.SubText,
        TextColor3 = Theme.Text,
        Font = Theme.Font,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    }, {
        corner(4),
        outline,
        new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
    })

    box.Focused:Connect(function()
        tween(outline, 0.12, { Color = Theme.Accent })
    end)
    box.FocusLost:Connect(function(enterPressed)
        tween(outline, 0.12, { Color = Theme.Stroke })
        safeCall(opts.Callback, box.Text, enterPressed)
    end)

    local object = {}
    function object:Set(text)
        box.Text = tostring(text)
    end
    function object:Get()
        return box.Text
    end
    return object
end

function Elements.Keybind(ctx, opts)
    local key = opts.Default
    local listening = false

    local row = makeRow(ctx, "Frame")
    nameLabel(row, opts.Name or "Keybind", UDim2.new(1, -122, 0, ROW_H))
    local button = new("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -8, 0.5, 0),
        Size = UDim2.fromOffset(90, 24),
        BackgroundColor3 = Theme.Background,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Theme.Font,
        TextSize = 13,
        Parent = row,
    }, { corner(4), stroke() })

    local function render()
        if listening then
            button.Text = "Press a key"
            button.TextColor3 = Theme.Accent
        else
            button.Text = key and key.Name or "None"
            button.TextColor3 = Theme.SubText
        end
    end

    local object = {}
    function object:Set(newKey, silent)
        key = newKey
        render()
        if not silent then
            safeCall(opts.Changed, key)
        end
    end
    function object:Get()
        return key
    end

    button.MouseButton1Click:Connect(function()
        listening = true
        render()
    end)
    ctx.track(UserInputService.InputBegan:Connect(function(input)
        if listening then
            if input.UserInputType == Enum.UserInputType.Keyboard then
                listening = false
                if input.KeyCode == Enum.KeyCode.Escape then
                    render()
                elseif input.KeyCode == Enum.KeyCode.Backspace then
                    object:Set(nil)
                else
                    object:Set(input.KeyCode)
                end
            end
            return
        end
        if key and input.KeyCode == key and not UserInputService:GetFocusedTextBox() then
            safeCall(opts.Callback, key)
        end
    end))

    render()
    return object
end

-- Adds Tab:AddButton, Tab:AddToggle, ... for every registered element.
local function attachElements(tab, ctx)
    for name, builder in pairs(Elements) do
        tab["Add" .. name] = function(_, options)
            if type(options) ~= "table" then
                options = { Name = tostring(options), Text = tostring(options) }
            end
            return builder(ctx, options)
        end
    end
end

---------------------------------------------------------------------
-- Window
---------------------------------------------------------------------

function Library:CreateWindow(opts)
    opts = opts or {}
    local root = getRoot()
    local window = { Tabs = {} }
    local activeTab
    local toggleButton
    local conns = {}

    local function track(connection)
        table.insert(conns, connection)
        return connection
    end

    local toggleKey = opts.Keybind or Enum.KeyCode.RightShift
    local camera = workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
    local wanted = opts.Size or Vector2.new(540, 360)
    local width = math.min(wanted.X, viewport.X - 24)
    local height = math.min(wanted.Y, viewport.Y - 24)

    local main = new("Frame", {
        Name = "Window",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(width, height),
        BackgroundColor3 = Theme.Background,
        BorderSizePixel = 0,
        Active = true, -- clicks on the window do not reach the game
        Parent = root,
    }, { corner(10), stroke() })

    local topbar = new("Frame", {
        Name = "Topbar",
        Size = UDim2.new(1, 0, 0, TOPBAR_H),
        BackgroundColor3 = Theme.Topbar,
        BorderSizePixel = 0,
        Parent = main,
    }, {
        corner(10),
        new("Frame", { -- squares off the topbar's lower corners
            Position = UDim2.new(0, 0, 1, -10),
            Size = UDim2.new(1, 0, 0, 10),
            BackgroundColor3 = Theme.Topbar,
            BorderSizePixel = 0,
        }),
    })

    local title = new("TextLabel", {
        Position = UDim2.fromOffset(14, 0),
        Size = UDim2.new(1, -90, 1, 0),
        BackgroundTransparency = 1,
        Text = opts.Title or "Menu",
        TextColor3 = Theme.Text,
        Font = Theme.FontBold,
        TextSize = 15,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = topbar,
    })

    local function topButton(text, offsetX)
        local button = new("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, offsetX, 0.5, 0),
            Size = UDim2.fromOffset(26, 26),
            BackgroundColor3 = Theme.Element,
            AutoButtonColor = false,
            Text = text,
            TextColor3 = Theme.SubText,
            Font = Theme.FontBold,
            TextSize = 14,
            Parent = topbar,
        }, { corner(5) })
        hover(button)
        return button
    end
    local hideButton = topButton("-", -42)
    local closeButton = topButton("X", -10)

    -- Structure lines: under the topbar and between the tab rail and the content.
    new("Frame", {
        Position = UDim2.fromOffset(0, TOPBAR_H),
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = Theme.Stroke,
        BorderSizePixel = 0,
        Parent = main,
    })
    new("Frame", {
        Position = UDim2.fromOffset(SIDEBAR_W, TOPBAR_H + 1),
        Size = UDim2.new(0, 1, 1, -(TOPBAR_H + 1)),
        BackgroundColor3 = Theme.Stroke,
        BorderSizePixel = 0,
        Parent = main,
    })

    local sidebar = new("ScrollingFrame", {
        Name = "Tabs",
        Position = UDim2.fromOffset(0, TOPBAR_H + 1),
        Size = UDim2.new(0, SIDEBAR_W, 1, -(TOPBAR_H + 1)),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Parent = main,
    }, {
        new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
        new("UIPadding", {
            PaddingTop = UDim.new(0, 8),
            PaddingLeft = UDim.new(0, 8),
            PaddingRight = UDim.new(0, 8),
        }),
    })

    local pages = new("Frame", {
        Name = "Pages",
        Position = UDim2.fromOffset(SIDEBAR_W + 1, TOPBAR_H + 1),
        Size = UDim2.new(1, -(SIDEBAR_W + 1), 1, -(TOPBAR_H + 1)),
        BackgroundTransparency = 1,
        Parent = main,
    })

    -- Drag the window by its topbar (mouse or touch).
    do
        local dragging, dragStart, startPosition
        topbar.InputBegan:Connect(function(input)
            if isPress(input) then
                dragging = true
                dragStart = input.Position
                startPosition = main.Position
            end
        end)
        track(UserInputService.InputChanged:Connect(function(input)
            if dragging and isMove(input) then
                local delta = input.Position - dragStart
                main.Position = UDim2.new(
                    startPosition.X.Scale, startPosition.X.Offset + delta.X,
                    startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
                )
            end
        end))
        track(UserInputService.InputEnded:Connect(function(input)
            if isPress(input) then
                dragging = false
            end
        end))
    end

    function window:SetVisible(state)
        main.Visible = state and true or false
    end

    function window:Toggle()
        main.Visible = not main.Visible
    end

    function window:SetTitle(text)
        title.Text = tostring(text)
    end

    function window:SelectTab(tab)
        if activeTab == tab then
            return
        end
        if activeTab then
            activeTab._setActive(false)
        end
        activeTab = tab
        tab._setActive(true)
    end

    function window:Destroy()
        for _, connection in ipairs(conns) do
            connection:Disconnect()
        end
        table.clear(conns)
        main:Destroy()
        if toggleButton then
            toggleButton:Destroy()
        end
        local index = table.find(Library._windows, window)
        if index then
            table.remove(Library._windows, index)
        end
    end

    function window:AddTab(name)
        name = tostring(name or "Tab")
        local tab = {}

        local button = new("TextButton", {
            Name = name,
            Size = UDim2.new(1, 0, 0, 30),
            BackgroundColor3 = Theme.Element,
            BackgroundTransparency = 1,
            AutoButtonColor = false,
            Text = "",
            LayoutOrder = #self.Tabs + 1,
            Parent = sidebar,
        }, { corner(6) })
        local label = new("TextLabel", {
            Position = UDim2.fromOffset(14, 0),
            Size = UDim2.new(1, -14, 1, 0),
            BackgroundTransparency = 1,
            Text = name,
            TextColor3 = Theme.SubText,
            Font = Theme.Font,
            TextSize = 14,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Parent = button,
        })
        local indicator = new("Frame", {
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, 4, 0.5, 0),
            Size = UDim2.fromOffset(3, 0),
            BackgroundColor3 = Theme.Accent,
            BorderSizePixel = 0,
            Parent = button,
        }, { corner(2) })

        local page = new("ScrollingFrame", {
            Name = name,
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ScrollBarThickness = 3,
            ScrollBarImageColor3 = Theme.Stroke,
            CanvasSize = UDim2.new(),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            Visible = false,
            Parent = pages,
        }, {
            new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
            new("UIPadding", {
                PaddingTop = UDim.new(0, 10),
                PaddingBottom = UDim.new(0, 10),
                PaddingLeft = UDim.new(0, 10),
                PaddingRight = UDim.new(0, 12),
            }),
        })

        -- Elements appear in the order they were added.
        local order = 0
        page.ChildAdded:Connect(function(child)
            if child:IsA("GuiObject") then
                order = order + 1
                child.LayoutOrder = order
            end
        end)

        tab.Page = page
        tab._setActive = function(active)
            page.Visible = active
            tween(button, 0.15, { BackgroundTransparency = active and 0 or 1 })
            tween(label, 0.15, { TextColor3 = active and Theme.Text or Theme.SubText })
            tween(indicator, 0.15, { Size = UDim2.fromOffset(3, active and 14 or 0) })
        end

        button.MouseButton1Click:Connect(function()
            window:SelectTab(tab)
        end)

        attachElements(tab, { page = page, track = track })
        table.insert(self.Tabs, tab)
        if not activeTab then
            window:SelectTab(tab)
        end
        return tab
    end

    -- Toggle key.
    track(UserInputService.InputBegan:Connect(function(input)
        if input.KeyCode == toggleKey and not UserInputService:GetFocusedTextBox() then
            window:Toggle()
        end
    end))

    hideButton.MouseButton1Click:Connect(function()
        window:SetVisible(false)
        if UserInputService.KeyboardEnabled then
            Library:Notify({
                Title = "Menu hidden",
                Text = "Press " .. toggleKey.Name .. " to show it again.",
                Duration = 3,
            })
        end
    end)
    closeButton.MouseButton1Click:Connect(function()
        window:Destroy()
    end)

    -- Floating button for devices without a keyboard.
    local wantButton = opts.ToggleButton
    if wantButton == nil then
        wantButton = not UserInputService.KeyboardEnabled
    end
    if wantButton then
        toggleButton = new("TextButton", {
            Name = "MenuToggle",
            AnchorPoint = Vector2.new(0.5, 0),
            Position = UDim2.new(0.5, 0, 0, 10),
            Size = UDim2.fromOffset(72, 28),
            BackgroundColor3 = Theme.Topbar,
            AutoButtonColor = false,
            Text = "Menu",
            TextColor3 = Theme.Text,
            Font = Theme.FontBold,
            TextSize = 13,
            Parent = root,
        }, { corner(99), stroke() })
        toggleButton.MouseButton1Click:Connect(function()
            window:Toggle()
        end)
    end

    table.insert(Library._windows, window)
    return window
end

---------------------------------------------------------------------
-- Notifications
---------------------------------------------------------------------

local notifyCount = 0

local function getNotifyHolder()
    local root = getRoot()
    local holder = root:FindFirstChild("Notifications")
    if holder then
        return holder
    end
    return new("Frame", {
        Name = "Notifications",
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -16, 1, -16),
        Size = UDim2.fromOffset(260, 400),
        BackgroundTransparency = 1,
        ZIndex = 10,
        Parent = root,
    }, {
        new("UIListLayout", {
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Bottom,
        }),
    })
end

function Library:Notify(opts)
    if type(opts) ~= "table" then
        opts = { Text = tostring(opts) }
    end
    local duration = opts.Duration or 4
    local hasTitle = opts.Title ~= nil and opts.Title ~= ""
    local holder = getNotifyHolder()

    notifyCount = notifyCount + 1
    local slot = new("Frame", {
        Size = UDim2.new(1, 0, 0, 58),
        BackgroundTransparency = 1,
        LayoutOrder = notifyCount,
        Parent = holder,
    })
    local card = new("Frame", {
        Position = UDim2.new(1, 24, 0, 0), -- starts just off-screen
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Theme.Topbar,
        BorderSizePixel = 0,
        Parent = slot,
    }, { corner(8), stroke() })

    if hasTitle then
        new("TextLabel", {
            Position = UDim2.fromOffset(12, 8),
            Size = UDim2.new(1, -24, 0, 16),
            BackgroundTransparency = 1,
            Text = tostring(opts.Title),
            TextColor3 = Theme.Text,
            Font = Theme.FontBold,
            TextSize = 14,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Parent = card,
        })
    end
    new("TextLabel", {
        Position = UDim2.fromOffset(12, hasTitle and 26 or 10),
        Size = UDim2.new(1, -24, 0, hasTitle and 24 or 36),
        BackgroundTransparency = 1,
        Text = tostring(opts.Text or ""),
        TextColor3 = Theme.SubText,
        Font = Theme.Font,
        TextSize = 13,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        Parent = card,
    })
    -- Time remaining.
    local remaining = new("Frame", {
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 10, 1, -6),
        Size = UDim2.new(1, -20, 0, 2),
        BackgroundColor3 = Theme.Accent,
        BorderSizePixel = 0,
        Parent = card,
    }, { corner(1) })

    tween(card, 0.25, { Position = UDim2.fromOffset(0, 0) })
    tween(remaining, duration, { Size = UDim2.new(0, 0, 0, 2) }, Enum.EasingStyle.Linear)

    task.delay(duration, function()
        if not card.Parent then
            return
        end
        tween(card, 0.25, { Position = UDim2.new(1, 24, 0, 0) })
        task.wait(0.3)
        slot:Destroy()
    end)
end

---------------------------------------------------------------------

function Library:Destroy()
    for _, window in ipairs(table.clone(self._windows)) do
        window:Destroy()
    end
    if self._root then
        self._root:Destroy()
        self._root = nil
    end
end

env.__MenuLib = Library
return Library
