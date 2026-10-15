--[[
    Expanded Input - Options.lua
    Adds a page under Esc > Options > AddOns, using Blizzard's own Settings API.
    Core.lua calls ns.CreateOptions(db) once the saved settings are loaded.
    If anything here fails, the addon still works; you can use /ei commands instead.
]]

local ADDON_NAME, ns = ...

function ns.CreateOptions(db)
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then
        return false
    end

    local D = ns.DEFAULTS
    local category = Settings.RegisterVerticalLayoutCategory("Expanded Input")
    local CreateCheckbox = Settings.CreateCheckbox or Settings.CreateCheckBox

    -- Registers one setting that reads/writes db[key] directly.
    local function AddSetting(key, varType, label, default)
        local setting = Settings.RegisterAddOnSetting(category, "ExpandedInput_" .. key, key, db, varType, label, default)
        if setting.SetValueChangedCallback then
            setting:SetValueChangedCallback(function() ns.Refresh() end)
        end
        return setting
    end

    -- Direction
    do
        local setting = AddSetting("direction", Settings.VarType.String, "Expand direction", D.direction)
        local function GetOptions()
            local container = Settings.CreateControlTextContainer()
            container:Add("auto", "Automatic", "Grows towards the side of the screen with the most room.")
            container:Add("up", "Upwards")
            container:Add("down", "Downwards")
            return container:GetData()
        end
        Settings.CreateDropdown(category, setting, GetOptions, "Which way the reading panel grows from your chat input.")
    end

    -- When to show
    do
        local setting = AddSetting("showWhen", Settings.VarType.String, "Show the panel", D.showWhen)
        local function GetOptions()
            local container = Settings.CreateControlTextContainer()
            container:Add("overflow", "When text doesn't fit on one line")
            container:Add("always", "Whenever I type")
            return container:GetData()
        end
        Settings.CreateDropdown(category, setting, GetOptions, "When the reading panel appears.")
    end

    -- Attach to box or whole window
    do
        local function GetOptions()
            local container = Settings.CreateControlTextContainer()
            container:Add("box", "The input box")
            container:Add("window", "The whole window")
            return container:GetData()
        end
        local chat = AddSetting("attachChat", Settings.VarType.String, "Attach to (Blizzard chat)", D.attachChat)
        Settings.CreateDropdown(category, chat, GetOptions, "Input box: the panel sits right against the chat input. Whole window: it sits above or below the entire chat window, so the chat stays readable.")
        local other = AddSetting("attachOther", Settings.VarType.String, "Attach to (other addons, e.g. WIM)", D.attachOther)
        Settings.CreateDropdown(category, other, GetOptions, "Whole window: the panel sits above or below the entire WIM window, so you can still read your partner's replies.")
    end

    -- Max height
    do
        local setting = AddSetting("maxLines", Settings.VarType.Number, "Maximum height (lines)", D.maxLines)
        local options = Settings.CreateSliderOptions(3, 30, 1)
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
        Settings.CreateSlider(category, setting, options, "Beyond this the panel scrolls. Use the mouse wheel over it to scroll back.")
    end

    -- Background opacity
    do
        local setting = AddSetting("bgAlpha", Settings.VarType.Number, "Background opacity", D.bgAlpha)
        local options = Settings.CreateSliderOptions(0.2, 1, 0.05)
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
            return math.floor(value * 100 + 0.5) .. "%"
        end)
        Settings.CreateSlider(category, setting, options, "How see-through the panel is.")
    end

    -- Checkboxes
    if CreateCheckbox then
        local cursor = AddSetting("showCursor", Settings.VarType.Boolean, "Show cursor position", D.showCursor)
        CreateCheckbox(category, cursor, "Shows a gold | where your text cursor is, handy when editing in the middle of a post.")

        local info = AddSetting("showInfo", Settings.VarType.Boolean, "Show channel and character count", D.showInfo)
        CreateCheckbox(category, info, "Shows e.g. 'Emote · 312 chars · ~2 posts' above your text.")

        local click = AddSetting("clickToEdit", Settings.VarType.Boolean, "Click in the panel to edit", D.clickToEdit)
        CreateCheckbox(category, click, "Click to put the cursor there, drag to select, double-click to select a word, shift-click to select up to there. Turn off to let clicks pass through the panel.")

        local colours = AddSetting("rpColours", Settings.VarType.Boolean, "RP colours", D.rpColours)
        CreateCheckbox(category, colours, "Colours \"speech\" in the /say colour, *emotes* in the /emote colour and ((out of character)) in grey, like Total RP 3 does after sending.")

        local angle = AddSetting("angleEmotes", Settings.VarType.Boolean, "Also colour <emotes>", D.angleEmotes)
        CreateCheckbox(category, angle, "Treat text between < and > as an emote too. Off by default, so things like \"I <3 you\" aren't coloured.")

        local announce = AddSetting("announce", Settings.VarType.Boolean, "Tell me when it pauses / resumes", D.announce)
        CreateCheckbox(category, announce, "Prints a short line in chat when the addon pauses for a boss, Mythic+ or PvP, and when it's active again.")
    end

    Settings.RegisterAddOnCategory(category)
    ns.settingsCategory = category
    return true
end
