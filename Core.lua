--[[
    Expanded Input - Core.lua
    Version 1.0.0

    THE IDEA
    WoW's chat input is a single line. Instead of replacing that box (which
    is a Blizzard frame that many chat addons also touch), we keep using it
    for typing and show our OWN panel right next to it. That panel holds a
    word-wrapped copy of whatever you are typing and grows up or down as the
    text gets longer. You can click in it to move the cursor or select text.

    WHY THIS IS SAFE / COMPATIBLE
    - We never call SetScript, HookScript, SetMultiLine, SetWidth, ... on
      Blizzard's edit box. While you type we only READ from it (GetText,
      GetCursorPosition), from our own frame's OnUpdate.
    - Only when YOU click in the panel do we touch the box: we make it active
      again (the same as pressing Enter), move its cursor and select text in
      it (SetCursorPosition, HighlightText).
    - During Midnight's restricted content (boss encounters, Mythic+,
      PvP matches, chat lockdown) the addon switches itself off completely.
]]

local ADDON_NAME, ns = ...   -- every file of an addon gets the same "ns" table

---------------------------------------------------------------------------
-- Settings and their default values
---------------------------------------------------------------------------
local DEFAULTS = {
    direction  = "auto",      -- "auto", "up" or "down"
    showWhen   = "overflow",  -- "overflow" = only when the text no longer fits on one line, "always" = whenever you type
    maxLines   = 12,          -- how tall the panel may grow before it starts scrolling
    bgAlpha    = 0.85,        -- background opacity (0 - 1)
    showCursor = true,        -- show a marker where your text cursor is
    showInfo   = true,        -- show channel name + character count on top
    announce   = true,        -- print a line in chat when the addon pauses / resumes
    attachChat  = "box",      -- Blizzard chat: attach to the input "box" or the whole "window"
    attachOther = "window",   -- other addons (WIM, ...): same choice, default whole window
    clickToEdit = true,       -- click in the panel to move the cursor, drag to select, double-click a word
    rpColours   = true,       -- colour "speech", *emotes* and ((ooc)) like Total RP 3 does
    angleEmotes = false,      -- also treat <text> as an emote (off: so "I <3 you" stays normal)
}
ns.DEFAULTS = DEFAULTS

local db                      -- points to ExpandedInputDB once it's loaded
local MSG_LIMIT = 255         -- WoW's limit for one chat message (bytes)
local PAD       = 8           -- inner padding of the panel, in pixels
local TICK      = 0.03        -- how often (seconds) we look at the input box
local CURSOR    = "|cffffd100" .. "||" .. "|r"   -- a gold "|" ( "||" is an escaped pipe )

local SAMPLE = "leans against the cold stone railing, eyes drifting over the harbour lights "
    .. "while the wind tugs at her cloak. For a long while she says nothing at all, turning a "
    .. "small brass compass over in her gloved fingers, as if it might point somewhere other "
    .. "than north this time. \"You know,\" she finally murmurs, \"I never did figure out why "
    .. "he left it to me.\" Her thumb brushes the scratched glass before she tucks it away again."

local function Print(msg)
    print("|cff66ccffExpanded Input|r: " .. msg)
end
ns.Print = Print

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local lastBox, lastText, lastCursor   -- what we drew last time (so we only redraw on changes)
local dirty        = false            -- true = settings changed, redraw next tick
local throttle     = 0
local previewUntil = 0                -- /ei test: show the sample until this time
local learnUntil   = 0                -- /ei learn: wait for a click in another addon's box until this time
local sessionBoxes = {}               -- learned boxes without a name (only valid until /reload)
local restricted   = nil              -- nil = not known yet, true/false afterwards
local sel          = {}               -- selection we made by dragging: box, a, b (bytes), cursor, text

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
-- "driver" is our invisible engine frame: it receives events and runs OnUpdate.
local driver = CreateFrame("Frame", nil, UIParent)
driver:SetSize(1, 1)
driver:SetPoint("TOPLEFT")
driver:SetAlpha(0)

-- A one-line, never-wrapping text used only to MEASURE text width/height.
local measureLine = driver:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
measureLine:SetWordWrap(false)

-- The reading panel itself.
local panel = CreateFrame("Frame", "ExpandedInputPanel", UIParent, "BackdropTemplate")
panel:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
})
panel:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
panel:SetFrameStrata("DIALOG")
panel:SetClampedToScreen(true)
panel:EnableMouseWheel(true)          -- scroll with the wheel
panel:Hide()
panel.offset = 0
panel.range  = 0
panel.lineH  = 14

-- Top line: "Emote  ·  312 chars  ·  ~2 posts"
panel.info = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
panel.info:SetPoint("TOPLEFT", PAD, -PAD)
panel.info:SetPoint("TOPRIGHT", -PAD, -PAD)
panel.info:SetJustifyH("LEFT")

-- "clip" cuts off anything outside its area; "content" slides up/down inside it.
panel.clip = CreateFrame("Frame", nil, panel)
panel.clip:SetClipsChildren(true)
panel.content = CreateFrame("Frame", nil, panel.clip)

panel.text = panel.content:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
panel.text:SetPoint("TOPLEFT")
panel.text:SetJustifyH("LEFT")
panel.text:SetJustifyV("TOP")
panel.text:SetWordWrap(true)
panel.text:SetNonSpaceWrap(true)

local function SetOffset(offset)
    panel.offset = math.max(0, math.min(offset, panel.range))
    panel.content:SetPoint("TOPLEFT", panel.clip, "TOPLEFT", 0, panel.offset)
end

panel:SetScript("OnMouseWheel", function(self, delta)
    if self.range > 0 then
        SetOffset(self.offset - delta * self.lineH * 2)
    end
end)

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

-- Give a FontString the same font as the edit box.
local function CopyFont(fontString, box)
    local font, size, flags = box:GetFont()
    if font and size and size > 0 then
        fontString:SetFont(font, size, flags or "")
    elseif box.GetFontObject and box:GetFontObject() then
        fontString:SetFontObject(box:GetFontObject())
    end
end

---------------------------------------------------------------------------
-- Text layout
-- We break the text into lines OURSELVES instead of letting WoW wrap it.
-- That way we know exactly which character sits where, which is what makes
-- "click in the panel to put the cursor there" possible.
---------------------------------------------------------------------------

-- Where does the "unit" starting at byte i end? A unit is one thing you
-- can't cut in half: a normal character (1-4 bytes in UTF-8, "é" is 2),
-- an escaped pipe "||", a colour code, or a whole link like
-- |Hitem:...|h[Sword]|h (a link is treated as one big character).
local CLOSERS = { H = "|h", T = "|t", A = "|a", K = "|k" }
local function UnitEnd(text, i, n)
    local b = text:byte(i)
    if b == 124 then                                   -- "|"
        local d = text:sub(i + 1, i + 1)
        if d == "|" or d == "r" or d == "n" then return math.min(i + 1, n) end
        if d == "c" then
            if text:sub(i + 2, i + 2) == "n" then      -- newer style: |cnCOLOR_NAME:
                return text:find(":", i + 3, true) or n
            end
            return math.min(i + 9, n)                  -- |cAARRGGBB
        end
        local closer = CLOSERS[d]
        if closer then
            local e = text:find(closer, i + 2, true)
            if e and d == "H" then e = text:find("|h", e + 2, true) end  -- |Hdata|h[text]|h
            return e and (e + 1) or n
        end
        return math.min(i + 1, n)
    end
    if not b or b < 0x80 then return i end
    if b >= 0xF0 then return math.min(i + 3, n) end
    if b >= 0xE0 then return math.min(i + 2, n) end
    if b >= 0xC0 then return math.min(i + 1, n) end
    return i
end

-- All byte positions where the cursor can be (0 = before the first character).
-- spaceAt[k] = true if the unit that ends at pos[k] is a space.
local function SafePositions(text)
    local pos, spaceAt = { 0 }, {}
    local i, n = 1, #text
    while i <= n do
        local e = UnitEnd(text, i, n)
        pos[#pos + 1] = e
        if e == i and text:byte(i) == 32 then spaceAt[#pos] = true end
        i = e + 1
    end
    return pos, spaceAt
end

local function Width(str)
    measureLine:SetText(str)
    return measureLine.GetUnboundedStringWidth and measureLine:GetUnboundedStringWidth()
        or measureLine:GetStringWidth()
end

-- Word wrap: returns lines as { firstIndex, lastIndex } into pos.
local function Wrap(text, pos, spaceAt, width)
    local lines, s, last = {}, 1, #pos
    while s < last do
        local e
        if Width(text:sub(pos[s] + 1, pos[last])) <= width then
            e = last                                   -- the rest fits
        else
            local lo, hi = s + 1, last                 -- binary search: how much fits?
            while lo < hi do
                local mid = math.floor((lo + hi + 1) / 2)
                if Width(text:sub(pos[s] + 1, pos[mid])) <= width then lo = mid else hi = mid - 1 end
            end
            e = lo
            for k = e, s + 1, -1 do                    -- rather break right after a space
                if spaceAt[k] then e = k break end
            end
        end
        lines[#lines + 1] = { s, e }
        s = e
    end
    if #lines == 0 then lines[1] = { 1, 1 } end
    return lines
end

-- Index into pos for a byte position (snaps back to a safe spot).
local function IndexOf(pos, byte)
    local lo, hi = 1, #pos
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if pos[mid] <= byte then lo = mid else hi = mid - 1 end
    end
    return lo
end

-- Which line is index idx on? (The end of a wrapped line counts as the next line.)
local function LineOf(lines, idx)
    for L, line in ipairs(lines) do
        if idx >= line[1] and (idx < line[2] or L == #lines) then return L end
    end
    return #lines
end

local SEL_ON, SEL_OFF = "|cff7fd3ff", "|r"   -- selected text shows light blue

---------------------------------------------------------------------------
-- RP colours, the way Total RP 3 shows them once the message is sent:
--   "speech" and “speech”   -> /say colour
--   *emote*                 -> /emote colour (and <emote> if you turn that on)
--   ((out of character))    -> grey
-- The markers themselves get the colour too. An unclosed marker colours the
-- rest of the text, so you see it while you're still typing.
---------------------------------------------------------------------------
local OOC_COLOUR = { 0.6, 0.6, 0.6 }

-- Colour of a chat type, e.g. "SAY" or "EMOTE", as "|cffRRGGBB".
local function ChatColour(chatType, r, g, b)
    local info = ChatTypeInfo and ChatTypeInfo[chatType]
    if info and info.r then r, g, b = info.r, info.g, info.b end
    return ("|cff%02x%02x%02x"):format(r * 255, g * 255, b * 255)
end

local function RPColours()
    return {
        speech = ChatColour("SAY", 1, 1, 1),
        emote  = ChatColour("EMOTE", 1, 0.5, 0.25),
        ooc    = ("|cff%02x%02x%02x"):format(OOC_COLOUR[1] * 255, OOC_COLOUR[2] * 255, OOC_COLOUR[3] * 255),
    }
end

-- Works out a style for every unit: nil (normal), "speech", "emote" or "ooc".
-- styles[k] belongs to the unit that ends at pos[k].
local function RPStyles(text, pos, useAngle)
    local styles = {}
    local speech, star, angle, ooc = false, false, false, false
    local function current()
        if speech then return "speech" end
        if star or angle then return "emote" end
        return nil
    end
    local n, k = #pos, 2
    while k <= n do
        local u = text:sub(pos[k - 1] + 1, pos[k])
        local nextU = (k < n) and text:sub(pos[k] + 1, pos[k + 1]) or ""
        if ooc then
            styles[k] = "ooc"
            if u == ")" and nextU == ")" then
                styles[k + 1] = "ooc"
                ooc = false
                k = k + 1
            end
        elseif u == "(" and nextU == "(" then
            ooc = true
            styles[k], styles[k + 1] = "ooc", "ooc"
            k = k + 1
        elseif u == '"' then
            if speech then styles[k] = current(); speech = false
            else speech = true; styles[k] = current() end
        elseif u == "“" then
            speech = true; styles[k] = current()
        elseif u == "”" then
            styles[k] = current(); speech = false
        elseif u == "*" then
            if star then styles[k] = current(); star = false
            else star = true; styles[k] = current() end
        elseif useAngle and u == "<" then
            angle = true; styles[k] = current()
        elseif useAngle and u == ">" then
            styles[k] = current(); angle = false
        else
            styles[k] = current()
        end
        k = k + 1
    end
    return styles
end

-- Build the text we actually show: lines joined with line breaks, plus the
-- cursor marker, the selection colour and the RP colours.
local function BuildDisplay(text, pos, lines, cursorIdx, selA, selB, styles, colours)
    local out = {}
    local cursorLine = cursorIdx and LineOf(lines, cursorIdx)
    for L, line in ipairs(lines) do
        local s, e = line[1], line[2]
        local parts = {}

        -- Add units a+1 .. b. Each piece closes its own colours, so line
        -- breaks, the cursor and the selection never end up inside one.
        local function add(a, b, useStyles)
            local run = nil
            for k = a + 1, b do
                local style = useStyles and styles and styles[k] or nil
                if style ~= run then
                    if run then parts[#parts + 1] = "|r" end
                    if style then parts[#parts + 1] = colours[style] end
                    run = style
                end
                local u = text:sub(pos[k - 1] + 1, pos[k])
                parts[#parts + 1] = u
                -- a link or colour code inside the run ends with |r: re-open our colour
                if run and u == "|r" then parts[#parts + 1] = colours[run] end
            end
            if run then parts[#parts + 1] = "|r" end
        end

        if selA and math.max(selA, s) < math.min(selB, e) then
            local a, b = math.max(selA, s), math.min(selB, e)
            add(s, a, true)
            parts[#parts + 1] = SEL_ON; add(a, b, false); parts[#parts + 1] = SEL_OFF
            add(b, e, true)
        elseif cursorLine == L then
            add(s, cursorIdx, true); parts[#parts + 1] = CURSOR; add(cursorIdx, e, true)
        else
            add(s, e, true)
        end
        out[#out + 1] = table.concat(parts)
    end
    return table.concat(out, "\n"), cursorLine
end

-- Free space above and below the box, in UIParent units.
local function GetSpace(box)
    local top, bottom = box:GetTop(), box:GetBottom()
    if not top or not bottom then return 300, 300 end
    local ratio = box:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return UIParent:GetHeight() - top * ratio, bottom * ratio
end

local function IsBlizzardChatBox(box)
    local name = box:GetName()
    return name ~= nil and name:match("^ChatFrame%d+EditBox$") ~= nil
end

-- Size of a frame in screen (UIParent) units, so frames with a different
-- scale (WIM has its own scale setting) are compared fairly.
local function ScreenSize(frame)
    local width, height = frame:GetWidth(), frame:GetHeight()
    if not width or not height then return 0, 0 end
    local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return width * ratio, height * ratio
end

-- The window a box lives in. A window is the thing you can DRAG around,
-- so we climb up through the box's parents and take the first one that is
-- movable (for WIM that's WIM3_msgFrame1, for Blizzard chat the chat frame).
--
-- We can't just take the outermost parent: WIM keeps all its windows inside
-- WIM_UIParent, an invisible container that covers a large part of the
-- screen. Containers like that are never movable, so they're skipped.
local function IsTooBig(frame)
    local width, height = ScreenSize(frame)
    return width <= 0 or height <= 0
        or width > UIParent:GetWidth() * 0.5 or height > UIParent:GetHeight() * 0.5
end

local function GetWindow(box)
    -- 1. First movable parent = the window.
    local parent = box:GetParent()
    while parent and parent ~= UIParent do
        if parent.IsForbidden and parent:IsForbidden() then break end
        if parent.IsMovable and parent:IsMovable() and parent:GetTop() and not IsTooBig(parent) then
            return parent
        end
        parent = parent:GetParent()
    end
    -- 2. None found: take the biggest parent that is still clearly smaller
    --    than half the screen, or else just the box itself.
    local window
    window, parent = box, box:GetParent()
    while parent and parent ~= UIParent do
        if (parent.IsForbidden and parent:IsForbidden()) or IsTooBig(parent) or not parent:GetTop() then
            break
        end
        window = parent
        parent = parent:GetParent()
    end
    return window
end

-- What should the panel attach to: the box itself, or its whole window?
local function GetAnchorFrame(box)
    local mode = IsBlizzardChatBox(box) and db.attachChat or db.attachOther
    if mode == "window" then return GetWindow(box) end
    return box
end

local function ResolveDirection(box)
    if db.direction == "up" or db.direction == "down" then
        return db.direction
    end
    local above, below = GetSpace(box)
    return (above >= below) and "up" or "down"
end

-- The "Say:" / "Emote:" / "[2. Trade]:" label Blizzard shows in front of the box.
local function GetHeader(box)
    local name = box:GetName()
    local header = box.header or (name and _G[name .. "Header"])
    if not header or not header.GetText then return nil end
    local text = header:GetText()
    if not text or IsSecret(text) or text == "" then return nil end
    return (text:gsub("[:%s]+$", ""))
end

-- Which edit boxes do we work with?
local function IsEligible(box)
    if box:GetObjectType() ~= "EditBox" then return false end
    if box.IsMultiLine and box:IsMultiLine() then return false end   -- already multi-line, nothing to add
    if sessionBoxes[box] then return true end
    local name = box:GetName()
    if not name then return false end
    if name:match("^ChatFrame%d+EditBox$") then return true end      -- all Blizzard chat tabs + whisper tabs
    return db.extraBoxes[name] == true                                -- boxes learned with /ei learn
end

-- Should the panel be visible for this text?
local function ShouldShow(box, text)
    if text == "" then return false end
    if db.showWhen == "always" then return true end
    CopyFont(measureLine, box)
    measureLine:SetText(text)
    local left, right = box:GetTextInsets()
    local usable = box:GetWidth() - (left or 0) - (right or 0) - 4
    local width = measureLine.GetUnboundedStringWidth and measureLine:GetUnboundedStringWidth()
        or measureLine:GetStringWidth()
    return width > usable
end

---------------------------------------------------------------------------
-- Drawing the panel
---------------------------------------------------------------------------
local function HidePanel(resetCache)
    if panel:IsShown() then panel:Hide() end
    if resetCache then
        lastBox, lastText, lastCursor = nil, nil, nil
    end
end

-- Draw order. Higher number = drawn on top of lower ones.
local STRATA_ORDER = {
    BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4,
    DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}

-- Make sure the panel is drawn on top of the window the box belongs to
-- (Blizzard chat, WIM, ...). Addon windows like WIM sit in the DIALOG
-- layer, so we go one layer higher (still below tooltips), or to the box's
-- own layer with a higher level if the box is already above that.
local function RaiseAbove(box)
    local strata = box:GetFrameStrata()
    if (STRATA_ORDER[strata] or 0) < STRATA_ORDER.FULLSCREEN_DIALOG then
        strata = "FULLSCREEN_DIALOG"
    end
    panel:SetFrameStrata(strata)
    panel:SetFrameLevel(math.min(box:GetFrameLevel() + 100, 9000))
end

local function Layout(box, text, cursor)
    CopyFont(panel.text, box)
    CopyFont(measureLine, box)
    measureLine:SetText("Ag")
    local lineH = math.max(measureLine:GetStringHeight(), 8)
    panel.lineH = lineH

    -- 1. Attach the panel to the box (or its whole window), in the chosen direction.
    local anchor = GetAnchorFrame(box)
    local gap = (anchor == box) and 2 or 4
    panel.box = box
    panel.anchor, panel.anchorTop, panel.anchorLeft = anchor, anchor:GetTop(), anchor:GetLeft()
    local dir = ResolveDirection(anchor)
    panel:ClearAllPoints()
    if dir == "up" then
        panel:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, gap)
        panel:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, gap)
    else
        panel:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -gap)
        panel:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -gap)
    end
    RaiseAbove(box)
    panel:SetBackdropColor(0, 0, 0, db.bgAlpha)
    panel:Show()

    local ratio = anchor:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local innerWidth = math.max(anchor:GetWidth() * ratio - PAD * 2, 50)

    panel:EnableMouse(db.clickToEdit and true or false)

    -- 2. Break the text into lines and add the cursor marker or selection.
    local pos, spaceAt = SafePositions(text)
    local lines = Wrap(text, pos, spaceAt, innerWidth)
    local cursorIdx = IndexOf(pos, cursor)
    local selA, selB
    if sel.box == box and sel.text == text and sel.cursor == cursor and sel.a and sel.a < sel.b then
        selA, selB = IndexOf(pos, sel.a), IndexOf(pos, sel.b)
    end
    local styles = db.rpColours and RPStyles(text, pos, db.angleEmotes) or nil
    local display, cursorLine = BuildDisplay(text, pos, lines,
        (db.showCursor and not selA) and cursorIdx or nil, selA, selB, styles, styles and RPColours())
    cursorLine = cursorLine or LineOf(lines, cursorIdx)

    -- 3. Info line.
    local infoH = 0
    if db.showInfo then
        local parts = {}
        local header = GetHeader(box)
        if header then parts[#parts + 1] = header end
        local chars = strlenutf8 and strlenutf8(text) or #text
        parts[#parts + 1] = chars .. " chars"
        if #text > MSG_LIMIT then
            parts[#parts + 1] = "|cffff9933~" .. math.ceil(#text / MSG_LIMIT) .. " posts|r"
        end
        panel.info:SetTextColor(0.7, 0.7, 0.7)
        panel.info:SetText(table.concat(parts, "  ·  "))
        panel.info:Show()
        infoH = panel.info:GetStringHeight() + 4
    else
        panel.info:Hide()
    end

    -- 4. The text itself, in the same colour as the chat channel.
    -- (a few pixels extra so WoW never wraps a line that we measured as fitting)
    panel.text:SetWidth(innerWidth + 4)
    panel.text:SetTextColor(box:GetTextColor())
    panel.text:SetText(display)
    local textH = math.max(panel.text:GetStringHeight(), lineH)
    local rowH = textH / #lines

    -- Remember everything the mouse code needs to find a character.
    panel.raw, panel.pos, panel.spaceAt, panel.lines = text, pos, spaceAt, lines
    panel.rowH, panel.cursorIdx, panel.cursorLine = rowH, cursorIdx, (not selA and db.showCursor) and cursorLine or nil

    -- 5. How tall may we get? (setting, but never off the screen)
    local above, below = GetSpace(anchor)
    local room = ((dir == "up") and above or below) - infoH - PAD * 2 - 10
    local visibleH = math.min(textH, db.maxLines * rowH, math.max(room, rowH))

    panel:SetHeight(visibleH + infoH + PAD * 2)
    panel.clip:ClearAllPoints()
    panel.clip:SetPoint("TOPLEFT", PAD, -(PAD + infoH))
    panel.clip:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    panel.content:SetSize(innerWidth + 4, textH)
    panel.range = math.max(textH - visibleH, 0)

    -- 6. Scroll so the line with the cursor is visible.
    local cursorTop = (cursorLine - 1) * rowH
    local cursorBottom = cursorTop + rowH
    local offset = panel.offset
    if cursorTop < offset then
        offset = cursorTop
    elseif cursorBottom > offset + visibleH then
        offset = cursorBottom - visibleH
    end
    SetOffset(offset)
end

local function ShowPreview()
    local box = ChatFrame1EditBox
    if not box or restricted then return end
    previewUntil = GetTime() + 10
    panel.offset = 0
    Layout(box, SAMPLE, #SAMPLE)
end


---------------------------------------------------------------------------
-- Click to edit: click = move the cursor there, drag = select,
-- double-click = select a word. The actual typing still happens in the
-- normal input box, so replacing a selection just works.
---------------------------------------------------------------------------
local CURSOR_WIDTH   -- width of our gold marker, measured once

-- Which byte position in the text is under the mouse?
local function ByteAtMouse()
    local lines, pos, text, box = panel.lines, panel.pos, panel.raw, panel.box
    if not lines or not box then return nil end
    local left, top = panel.content:GetLeft(), panel.content:GetTop()
    if not left or not top then return nil end
    local scale = panel.content:GetEffectiveScale()
    local mouseX, mouseY = GetCursorPosition()
    local x, y = mouseX / scale - left, top - mouseY / scale

    -- Which line? Then: which character on that line?
    local L = math.max(1, math.min(#lines, math.floor(y / panel.rowH) + 1))
    local s, e = lines[L][1], lines[L][2]
    CopyFont(measureLine, box)

    -- The gold cursor marker takes up a little room on its own line.
    if panel.cursorLine == L then
        CURSOR_WIDTH = CURSOR_WIDTH or Width(CURSOR)
        if x > Width(text:sub(pos[s] + 1, pos[panel.cursorIdx])) + CURSOR_WIDTH / 2 then
            x = x - CURSOR_WIDTH
        end
    end

    local lo, hi = s, e                    -- last spot whose text is still left of the mouse
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if Width(text:sub(pos[s] + 1, pos[mid])) <= x then lo = mid else hi = mid - 1 end
    end
    local k = lo
    if k < e then                          -- is the next spot closer?
        local w1 = Width(text:sub(pos[s] + 1, pos[k]))
        local w2 = Width(text:sub(pos[s] + 1, pos[k + 1]))
        if x - w1 > w2 - x then k = k + 1 end
    end
    -- Clicking past the end of a wrapped line: stay on that line, before its last space.
    if L < #lines and k == e and panel.spaceAt[e] then k = e - 1 end
    return pos[k]
end

-- Move the cursor in the real input box, and select from..to if they differ.
local function SelectInBox(box, from, to)
    box:SetCursorPosition(to)
    local a, b = math.min(from, to), math.max(from, to)
    if a ~= b then box:HighlightText(a, b) else box:HighlightText(0, 0) end
    -- remember where the cursor REALLY ended up, as the game reports it
    sel.box, sel.a, sel.b, sel.to, sel.text = box, a, b, to, box:GetText()
    sel.cursor = box:GetCursorPosition()
    dirty = true
end

-- Start and end of the word around a byte position (links count as one word).
local function WordAround(byte)
    local pos, spaceAt = panel.pos, panel.spaceAt
    local idx = IndexOf(pos, byte)
    local first = idx
    while first > 1 and not spaceAt[first] do first = first - 1 end
    local last = idx + 1
    while last <= #pos and not spaceAt[last] do last = last + 1 end
    return pos[first], pos[last - 1]
end

local function CanClick()
    return db.clickToEdit and previewUntil == 0 and panel.box ~= nil and panel:IsShown()
end

-- Clicking the panel takes keyboard focus away from the input box (and
-- Blizzard's chat then closes its box). After the click we give it back:
-- for Blizzard chat via Blizzard's own "open chat" function, for other
-- addons' boxes (WIM) by simply focusing the box again.
local function ActivateBox(box)
    if GetCurrentKeyBoardFocus() == box then return end
    if IsBlizzardChatBox(box) then
        local activate = (ChatFrameUtil and ChatFrameUtil.ActivateChat) or ChatEdit_ActivateChat
        if type(activate) == "function" then
            pcall(activate, box)
        end
    end
    if GetCurrentKeyBoardFocus() ~= box then
        if not box:IsShown() then box:Show() end
        box:SetFocus()
    end
end

-- Finish a click/drag: make the box active again, then put the cursor and
-- selection where you clicked (opening the box can move the cursor to the end).
local function FinishClick()
    local box, click = panel.box, panel.click
    if not box or not click then return end
    ActivateBox(box)
    if click.text ~= "" and box:GetText() == "" then
        box:SetText(click.text)              -- just in case closing the box emptied it
    end
    SelectInBox(box, click.from, click.to)
    -- once more on the next frame, after the game has finished opening the box
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if panel.box == box then SelectInBox(box, click.from, click.to) end
            panel.click = nil
        end)
    else
        panel.click = nil
    end
end

local lastClickTime, lastClickByte = 0, nil

panel:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" or not CanClick() then return end
    local byte = ByteAtMouse()
    if not byte then return end
    local box, now = self.box, GetTime()
    local text = self.raw or box:GetText() or ""

    if now - lastClickTime < 0.35 and byte == lastClickByte then
        local a, b = WordAround(byte)               -- double-click: select the word
        self.click = { from = a, to = b, text = text }
        lastClickTime = 0
        SelectInBox(box, a, b)
        self.dragging = false
        FinishClick()
        return
    end
    lastClickTime, lastClickByte = now, byte

    local from = byte
    if IsShiftKeyDown() then                        -- shift-click: select from the cursor to here
        from = (sel.box == box and sel.text == text and sel.a ~= sel.b)
            and ((sel.to == sel.b) and sel.a or sel.b) or (box:GetCursorPosition() or byte)
    end
    self.click = { from = from, to = byte, text = text }
    SelectInBox(box, from, byte)
    self.dragging = true
end)

-- Called from the main loop while the mouse button is held down, and once
-- more when it's released.
local function UpdateDrag()
    local click = panel.click
    if not click then panel.dragging = false return end
    local byte = ByteAtMouse()
    if byte and byte ~= click.to then
        click.to = byte
        SelectInBox(panel.box, click.from, byte)
    end
    if not IsMouseButtonDown("LeftButton") then
        panel.dragging = false
        FinishClick()
    end
end

panel:SetScript("OnMouseUp", function(self)
    if self.dragging then UpdateDrag() end
    if self.dragging then                   -- button reported as still down: finish anyway
        self.dragging = false
        FinishClick()
    end
end)

---------------------------------------------------------------------------
-- /ei learn: remember another addon's input box (e.g. WIM)
---------------------------------------------------------------------------
local function TryLearn(box, now)
    if now > learnUntil then
        learnUntil = 0
        Print("Learn mode timed out. Nothing was added.")
        return
    end
    if not box or box:GetObjectType() ~= "EditBox" then return end
    -- Blizzard's own chat boxes always work; ignore them (you may still be
    -- in the chat box right after typing /ei learn) and keep waiting.
    if IsBlizzardChatBox(box) then return end
    learnUntil = 0
    if IsEligible(box) then
        Print("That input box was already added, so it's working already.")
        return
    end
    if box.IsMultiLine and box:IsMultiLine() then
        Print("That input box is already multi-line, so it doesn't need this addon.")
        return
    end
    local name = box:GetName()
    if name then
        db.extraBoxes[name] = true
        Print("Added |cffffd100" .. name .. "|r. It will now expand too.")
    else
        sessionBoxes[box] = true
        Print("Added for this session. That box has no name, so it's forgotten after /reload.")
    end
end

---------------------------------------------------------------------------
-- The main loop: runs every frame on OUR frame, but only works every TICK
---------------------------------------------------------------------------
local function OnUpdate(self, elapsed)
    if restricted then return end           -- hard stop first, before touching anything

    throttle = throttle + elapsed
    if throttle < TICK then return end
    throttle = 0

    local now = GetTime()
    if previewUntil > 0 then
        if now < previewUntil then return end
        previewUntil = 0
        HidePanel(true)
    end

    -- Which input box is the player typing in right now?
    local box = GetCurrentKeyBoardFocus()
    if box and box.IsForbidden and box:IsForbidden() then box = nil end

    if learnUntil > 0 then TryLearn(box, now) end

    -- While you're clicking/dragging in the panel the input box has no focus,
    -- so keep showing the panel for that box until the click is finished.
    local clicking = panel.click ~= nil and panel.box ~= nil
    if panel.dragging then UpdateDrag() end
    if clicking then box = panel.box end

    if not box or not IsEligible(box) or (not clicking and not box:IsVisible()) then
        if panel:IsShown() or lastBox then HidePanel(true) end
        return
    end

    local text = box:GetText()
    if IsSecret(text) or type(text) ~= "string" then HidePanel(true) return end
    local cursor = box:GetCursorPosition() or #text

    -- Window dragged somewhere else while the panel is open? Then redraw, so
    -- the direction and maximum height fit the new spot.
    if panel:IsShown() and panel.anchor
        and (panel.anchor:GetTop() ~= panel.anchorTop or panel.anchor:GetLeft() ~= panel.anchorLeft) then
        dirty = true
    end

    -- Nothing changed? Then there's nothing to redraw.
    if box == lastBox and text == lastText and cursor == lastCursor and not dirty then return end
    if box ~= lastBox then panel.offset = 0 end   -- new box: start at the top
    lastBox, lastText, lastCursor, dirty = box, text, cursor, false

    if not ShouldShow(box, text) then
        HidePanel(false)
        return
    end
    Layout(box, text, cursor)
end

---------------------------------------------------------------------------
-- Midnight addon restrictions: switch off during boss encounters, Mythic+,
-- PvP matches and chat lockdown, and switch back on when they end.
--
-- We deliberately ignore the "Map" restriction: it can stay active for as
-- long as you're inside an instance, which would keep the addon off after
-- every trash pull. Blizzard's chat restrictions target boss encounters and
-- Mythic+ runs, so those are what we watch.
---------------------------------------------------------------------------
local TYPE     = (Enum and Enum.AddOnRestrictionType) or {}
local INACTIVE = (Enum and Enum.AddOnRestrictionState and Enum.AddOnRestrictionState.Inactive) or 0
local eventState = {}   -- last state the game TOLD us per restriction type (backup only)

-- Call a game function safely; true only if it worked AND returned true.
local function SafeTrue(func, ...)
    if type(func) ~= "function" then return false end
    local ok, result = pcall(func, ...)
    return ok and result == true
end

-- Is this restriction type active? Ask the game first (always up to date).
-- Only if that's not possible, fall back to what the last event told us.
local function RestrictionActive(restrictionType)
    if restrictionType == nil then return false end
    if C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive then
        local ok, active = pcall(C_RestrictedActions.IsAddOnRestrictionActive, restrictionType)
        if ok and type(active) == "boolean" then return active end
    end
    return eventState[restrictionType] == true
end

-- Each reason the addon pauses for. Each test is checked in two ways where possible.
local CHECKS = {
    { label = "boss encounter", test = function()
        return SafeTrue(IsEncounterInProgress) or RestrictionActive(TYPE.Encounter)
    end },
    { label = "Mythic+ run", test = function()
        return SafeTrue(C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive)
            or RestrictionActive(TYPE.ChallengeMode)
    end },
    { label = "PvP match", test = function()
        return RestrictionActive(TYPE.PvPMatch)
    end },
    { label = "chat lockdown", test = function()
        return SafeTrue(C_ChatInfo and C_ChatInfo.InChatMessagingLockdown)
    end },
}

local function GetPauseReason()
    for _, check in ipairs(CHECKS) do
        if check.test() then return check.label end
    end
    return nil
end

local function ApplyRestricted(reason)
    local state = reason ~= nil
    if state == restricted then return end
    local wasKnown = restricted ~= nil
    restricted = state
    if state then
        previewUntil, learnUntil = 0, 0
        HidePanel(true)
        driver:SetScript("OnUpdate", nil)    -- don't even run while restricted
    else
        driver:SetScript("OnUpdate", OnUpdate)
    end
    if wasKnown and db and db.announce then
        if state then
            Print("|cffff9933paused|r (" .. reason .. "). It switches back on by itself afterwards.")
        else
            Print("|cff66ff66active again|r.")
        end
    end
end

local function Recompute()
    ApplyRestricted(GetPauseReason())
end

-- Re-check a moment later, after the game has finished updating its state.
local function RecomputeSoon(delay)
    if C_Timer and C_Timer.After then
        C_Timer.After(delay or 0.5, Recompute)
    else
        Recompute()
    end
end

---------------------------------------------------------------------------
-- Saved settings
---------------------------------------------------------------------------
local function FillDefaults()
    for key, value in pairs(DEFAULTS) do
        if db[key] == nil then db[key] = value end
    end
    if type(db.extraBoxes) ~= "table" then db.extraBoxes = {} end
end

-- Called by the options panel and slash commands after a setting changes.
function ns.Refresh()
    dirty = true
    if previewUntil > 0 then ShowPreview() end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_LOGIN")

-- Events that mean "a restriction may have started or ended".
-- pcall: if an event doesn't exist in this client version, just skip it.
local RECHECK_EVENTS = {
    "ADDON_RESTRICTION_STATE_CHANGED",
    "ENCOUNTER_START", "ENCOUNTER_END",
    "CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED", "CHALLENGE_MODE_RESET",
    "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
    "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
}
for _, eventName in ipairs(RECHECK_EVENTS) do
    pcall(driver.RegisterEvent, driver, eventName)
end

-- After these, any remembered "restriction is active" from events is stale.
local CLEAR_EVENTS = {
    ENCOUNTER_END = true, CHALLENGE_MODE_COMPLETED = true, CHALLENGE_MODE_RESET = true,
    PLAYER_ENTERING_WORLD = true, ZONE_CHANGED_NEW_AREA = true,
}

driver:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        ExpandedInputDB = ExpandedInputDB or {}
        db = ExpandedInputDB
        FillDefaults()
        if ns.CreateOptions then
            local ok, result = pcall(ns.CreateOptions, db)
            if not ok or result == false then ns.settingsCategory = nil end
        end
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGIN" then
        Recompute()
        if C_Timer and C_Timer.NewTicker then
            C_Timer.NewTicker(1, Recompute)   -- safety net: re-check every second
        end

    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
        local restrictionType, state = ...
        if restrictionType ~= nil then
            eventState[restrictionType] = (state ~= nil and state ~= INACTIVE)
        end
        -- While this event is being handled the game still reports the OLD state,
        -- so we check again right after.
        RecomputeSoon(0)

    else
        if CLEAR_EVENTS[event] then wipe(eventState) end
        RecomputeSoon(0.5)
    end
end)

---------------------------------------------------------------------------
-- Slash commands: /ei or /expandedinput
---------------------------------------------------------------------------
local function ShowHelp()
    Print("commands:")
    print("  /ei  - open the settings")
    print("  /ei up | down | auto  - direction the panel grows")
    print("  /ei lines <3-30>  - maximum height in lines")
    print("  /ei always | overflow  - show while typing, or only when text doesn't fit")
    print("  /ei cursor | info  - toggle cursor marker / info line")
    print("  /ei click  - toggle click / drag / double-click in the panel to edit")
    print("  /ei colours  - toggle RP colours for \"speech\", *emotes* and ((ooc))")
    print("  /ei angle  - also colour <emotes> written with angle brackets")
    print("  /ei attach chat|other box|window  - attach to the input box or the whole window")
    print("  /ei test  - show a 10 second preview")
    print("  /ei learn  - then click into another addon's input box (e.g. WIM) within 15 sec")
    print("  /ei forget  - forget all learned input boxes")
    print("  /ei status  - is the addon active or paused, and why?")
    print("  /ei window  - show which frame the panel attaches to (for troubleshooting)")
    print("  /ei quiet  - toggle the paused / active again messages")
    print("  /ei reset  - back to default settings")
end

SLASH_EXPANDEDINPUT1 = "/ei"
SLASH_EXPANDEDINPUT2 = "/expandedinput"
SlashCmdList.EXPANDEDINPUT = function(msg)
    local cmd, arg = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        if ns.settingsCategory and Settings and Settings.OpenToCategory then
            local ok = pcall(Settings.OpenToCategory, ns.settingsCategory:GetID())
            if ok then return end
        end
        ShowHelp()
    elseif cmd == "help" then
        ShowHelp()
    elseif cmd == "up" or cmd == "down" or cmd == "auto" then
        db.direction = cmd
        Print("direction set to " .. cmd .. ".")
    elseif cmd == "lines" then
        local n = tonumber(arg)
        if n then
            db.maxLines = math.max(3, math.min(30, math.floor(n)))
            Print("maximum height set to " .. db.maxLines .. " lines.")
        else
            Print("usage: /ei lines 12")
        end
    elseif cmd == "always" or cmd == "overflow" then
        db.showWhen = cmd
        Print(cmd == "always" and "panel shows whenever you type." or "panel shows when your text no longer fits on one line.")
    elseif cmd == "cursor" then
        db.showCursor = not db.showCursor
        Print("cursor marker " .. (db.showCursor and "on." or "off."))
    elseif cmd == "info" then
        db.showInfo = not db.showInfo
        Print("info line " .. (db.showInfo and "on." or "off."))
    elseif cmd == "test" then
        if restricted then Print("paused right now (restricted content).") else ShowPreview() end
    elseif cmd == "learn" then
        learnUntil = GetTime() + 15
        Print("click into the input box you want to add (you have 15 seconds).")
    elseif cmd == "forget" then
        wipe(db.extraBoxes)
        wipe(sessionBoxes)
        Print("forgot all learned input boxes.")
    elseif cmd == "status" then
        Print(restricted and "|cffff9933paused|r" or "|cff66ff66active|r")
        for _, check in ipairs(CHECKS) do
            print("  " .. check.label .. ": " .. (check.test() and "|cffff9933yes|r" or "no"))
        end
        print("  map restriction (not used): " .. (RestrictionActive(TYPE.Map) and "yes" or "no"))
    elseif cmd == "attach" then
        local which, mode = arg:lower():match("^(%S+)%s+(%S+)$")
        if (which == "chat" or which == "other") and (mode == "box" or mode == "window") then
            db[which == "chat" and "attachChat" or "attachOther"] = mode
            Print((which == "chat" and "Blizzard chat" or "other addons") .. ": panel attaches to the " .. mode .. ".")
        else
            Print("usage: /ei attach chat box | /ei attach chat window | /ei attach other box | /ei attach other window")
        end
    elseif cmd == "window" then
        local box = panel.box    -- the last box the panel was shown for
        if not box then
            Print("type something long in an input box first, then run /ei window.")
        else
            local chosen = GetAnchorFrame(box)
            Print("frames around the last input box (chosen one marked with <<):")
            local frame = box
            while frame and frame ~= UIParent do
                if frame.IsForbidden and frame:IsForbidden() then print("  (protected frame)") break end
                local width, height = ScreenSize(frame)
                print(("  %s  %dx%d%s%s"):format(frame:GetName() or "(no name)", math.floor(width), math.floor(height),
                    (frame.IsMovable and frame:IsMovable()) and "  (movable)" or "",
                    frame == chosen and "  <<" or ""))
                frame = frame:GetParent()
            end
        end
    elseif cmd == "click" then
        db.clickToEdit = not db.clickToEdit
        Print("click to edit " .. (db.clickToEdit and "on." or "off (clicks go through the panel)."))
    elseif cmd == "colours" or cmd == "colors" then
        db.rpColours = not db.rpColours
        Print("RP colours " .. (db.rpColours and "on." or "off."))
    elseif cmd == "angle" then
        db.angleEmotes = not db.angleEmotes
        Print("<emote> colouring " .. (db.angleEmotes and "on." or "off. Only *emote* counts as an emote."))
    elseif cmd == "quiet" then
        db.announce = not db.announce
        Print("pause/resume messages " .. (db.announce and "on." or "off."))
    elseif cmd == "reset" then
        local learned = db.extraBoxes      -- keep the learned boxes
        wipe(db)
        db.extraBoxes = learned
        FillDefaults()
        Print("settings reset to defaults.")
    else
        ShowHelp()
    end
    ns.Refresh()
end
