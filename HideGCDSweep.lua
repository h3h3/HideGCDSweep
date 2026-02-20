-- ============================================================================
-- HideGCDSweep
-- Standalone addon to hide the cooldown swipe/sweep animation on Blizzard's
-- Cooldown Manager icons (Essential, Utility, Buff trackers).
-- ============================================================================

local ADDON_NAME = ...

-- ============================================================================
-- SETTINGS (edit these to customize behaviour)
-- ============================================================================

local HIDE_EDGE      = true  -- Also hide the bright edge line on the GCD sweep
local GCD_THRESHOLD  = 2.0  -- Seconds; SetCooldown calls with duration <= this are treated as GCD

-- ============================================================================
-- BLIZZARD CDM VIEWER DEFINITIONS
-- ============================================================================

local VIEWERS = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
}

-- ============================================================================
-- STATE TRACKING
-- ============================================================================

local hookedCooldowns = {}

-- ============================================================================
-- ICON DETECTION
-- ============================================================================

local function IsIcon(frame)
    if not frame then return false end
    return (frame.Cooldown or frame.cooldown or frame.Icon or frame.icon) ~= nil
end

local function GetCooldownFrame(icon)
    return icon.Cooldown or icon.cooldown
end

local function CollectIcons(viewer)
    local icons = {}
    if not viewer or not viewer.GetChildren then return icons end

    local numChildren = viewer:GetNumChildren() or 0
    for i = 1, numChildren do
        local child = select(i, viewer:GetChildren())
        if child and IsIcon(child) then
            icons[#icons + 1] = child
        elseif child and child.GetNumChildren then
            local numNested = child:GetNumChildren() or 0
            for j = 1, numNested do
                local nested = select(j, child:GetChildren())
                if nested and IsIcon(nested) then
                    icons[#icons + 1] = nested
                end
            end
        end
    end
    return icons
end

-- ============================================================================
-- HOOK A COOLDOWN FRAME
-- Blizzard resets SetDrawSwipe/SetDrawEdge on SetCooldown calls, so we hook
-- those methods to reapply.
-- ============================================================================

local function HookCooldownFrame(cooldownFrame)
    if not cooldownFrame or hookedCooldowns[cooldownFrame] then return end
    hookedCooldowns[cooldownFrame] = true

    -- SetCooldown(start, duration, modRate)
    -- Only suppress the swipe for GCD-length durations; restore it for real cooldowns.
    hooksecurefunc(cooldownFrame, "SetCooldown", function(self, start, duration)
        pcall(function()
            if duration and duration > 0 and duration <= GCD_THRESHOLD then
                self:SetDrawSwipe(false)
                if HIDE_EDGE then self:SetDrawEdge(false) end
            else
                self:SetDrawSwipe(true)
                self:SetDrawEdge(true)
            end
        end)
    end)
end

-- ============================================================================
-- PROCESS A VIEWER
-- ============================================================================

local function ProcessViewer(globalName)
    local viewer = _G[globalName]
    if not viewer then return end

    for _, icon in ipairs(CollectIcons(viewer)) do
        local cd = GetCooldownFrame(icon)
        if cd then
            HookCooldownFrame(cd)
        end
    end
end

local function ProcessAllViewers()
    for _, globalName in ipairs(VIEWERS) do
        ProcessViewer(globalName)
    end
end

-- ============================================================================
-- CHILD MONITORING
-- ============================================================================

local monitoredViewers = {}

local function StartMonitoringViewer(globalName)
    local viewer = _G[globalName]
    if not viewer or monitoredViewers[globalName] then return end
    monitoredViewers[globalName] = true

    hooksecurefunc(viewer, "Show", function()
        C_Timer.After(0.1, function() ProcessViewer(globalName) end)
    end)
end

-- ============================================================================
-- EVENT HANDLING
-- ============================================================================

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("SPELL_DATA_LOAD_RESULT")

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        C_Timer.After(1, function()
            for _, globalName in ipairs(VIEWERS) do
                StartMonitoringViewer(globalName)
            end
            ProcessAllViewers()
        end)

    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(0.5, function()
            for _, globalName in ipairs(VIEWERS) do
                StartMonitoringViewer(globalName)
            end
            ProcessAllViewers()
        end)

    elseif event == "PLAYER_SPECIALIZATION_CHANGED"
        or event == "PLAYER_REGEN_ENABLED"
        or event == "SPELL_DATA_LOAD_RESULT" then
        C_Timer.After(0.2, ProcessAllViewers)

    elseif event == "PLAYER_REGEN_DISABLED" then
        C_Timer.After(0, ProcessAllViewers)
    end
end)
