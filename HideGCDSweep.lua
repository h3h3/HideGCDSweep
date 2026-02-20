-- ============================================================================
-- HideGCDSweep
-- Standalone addon to hide the GCD cooldown swipe/sweep animation on
-- Blizzard's Cooldown Manager icons (Essential, Utility, Buff trackers).
--
-- Uses Midnight's secret-safe APIs to distinguish GCD from real cooldowns:
--   1. C_Spell.GetSpellCooldown().isOnGCD  (primary, non-secret when readable)
--   2. C_CurveUtil + EvaluateRemainingDuration curve  (secret-safe fallback)
-- Never reads duration from SetCooldown hook params → no taint in combat.
-- ============================================================================

local ADDON_NAME = ...

-- ============================================================================
-- SETTINGS (edit here to customize)
-- ============================================================================

local HIDE_EDGE = true   -- Also hide the bright edge line on the GCD sweep

-- ============================================================================
-- BLIZZARD CDM VIEWER DEFINITIONS
-- ============================================================================

local VIEWERS = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
}

-- ============================================================================
-- STATE
-- ============================================================================

local hookedCooldowns = {}   -- cooldown frame → true  (already hooked)
local chargeSpellCache = {}  -- [spellID] = true for spells known to have charges

-- ============================================================================
-- GCD FILTER CURVE  (secret-safe, Midnight pattern from TweaksUI)
--
-- A step curve evaluated against a Duration Object:
--   remaining ≤ 2.0 s  →  0  (GCD range)
--   remaining > 2.0 s  →  1  (real cooldown)
-- Combined with C_StringUtil.TruncateWhenZero to extract a non-secret
-- result without ever reading secret numbers directly.
-- ============================================================================

local gcdFilterCurve

local function GetGCDFilterCurve()
    if gcdFilterCurve then return gcdFilterCurve end
    if not C_CurveUtil or not C_CurveUtil.CreateCurve then return nil end
    if not Enum or not Enum.LuaCurveType then return nil end

    local ok, curve = pcall(function()
        local c = C_CurveUtil.CreateCurve()
        c:SetType(Enum.LuaCurveType.Linear)
        c:AddPoint(0,    0)   -- 0 s remaining   → 0
        c:AddPoint(2.0,  0)   -- 2.0 s remaining → 0   (still GCD range)
        c:AddPoint(2.01, 1)   -- 2.01 s          → 1   (real CD)
        c:AddPoint(600,  1)   -- 10 min           → 1
        return c
    end)
    if ok and curve then gcdFilterCurve = curve end
    return gcdFilterCurve
end

-- ============================================================================
-- GCD SPELL (61304) – for duration comparison when struct is non-secret
-- ============================================================================

local GCD_SPELL_ID = 61304

local function GetGCDDuration()
    if not C_Spell or not C_Spell.GetSpellCooldown then return nil end
    local ok, info = pcall(C_Spell.GetSpellCooldown, GCD_SPELL_ID)
    if not ok or not info then return nil end
    local d = info.duration
    if d and type(d) == "number" and not (issecretvalue and issecretvalue(d)) then
        return d
    end
    return nil
end

-- ============================================================================
-- SECRET-SAFE DURATION CHECK
-- Returns true (remaining > 2 s), false (≤ 2 s), or nil (can't determine)
-- ============================================================================

local function IsDurationLongerThanGCD(dObj)
    local curve = GetGCDFilterCurve()
    if not curve or not C_StringUtil or not C_StringUtil.TruncateWhenZero then return nil end

    local ok, result = pcall(dObj.EvaluateRemainingDuration, dObj, curve)
    if not ok or result == nil then return nil end

    local ok2, str = pcall(C_StringUtil.TruncateWhenZero, result)
    if not ok2 then return nil end

    -- str is secret → curve returned 1 → remaining > 2 s → real CD
    -- str is ""     → curve returned 0 → remaining ≤ 2 s → GCD range
    if issecretvalue and issecretvalue(str) then
        return true
    end
    return false
end

-- ============================================================================
-- IS THIS COOLDOWN EVENT A GCD?
-- Returns true  → GCD (hide the sweep)
--         false → real CD (allow sweep)
--
-- @param spellID        spell ID from icon (may be nil or secret)
-- @param durationObject Duration Object from hook or API (may be nil)
-- @param hookDur        raw duration from SetCooldown hook (may be secret)
-- ============================================================================

local function IsGCD(spellID, durationObject, hookDur)
    -- ==================================================================
    -- PRE-CHECK: Charge spells with an active recharge timer
    -- When charges > 0, C_Spell.GetSpellCooldown reports isOnGCD = true
    -- (the spell itself is GCD-locked), but the CDM icon is actually
    -- displaying the recharge timer. Let the swipe through.
    -- When charges = 0, the regular cooldown detection below handles it.
    --
    -- Two paths:
    --   A) Values readable (out of combat) → direct branch
    --   B) Values secret (in combat) → cache + curve on charge duration
    -- ==================================================================
    if spellID and not (issecretvalue and issecretvalue(spellID))
       and C_Spell and C_Spell.GetSpellCharges then
        local ok, chargeInfo = pcall(C_Spell.GetSpellCharges, spellID)
        if ok and chargeInfo then
            local cur  = chargeInfo.currentCharges
            local max  = chargeInfo.maxCharges

            local curReadable = cur ~= nil and type(cur) == "number"
                and not (issecretvalue and issecretvalue(cur))
            local maxReadable = max ~= nil and type(max) == "number"
                and not (issecretvalue and issecretvalue(max))

            if curReadable and maxReadable and max > 1 then
                -- PATH A: readable → cache and branch directly
                chargeSpellCache[spellID] = true
                if cur < max then
                    return false  -- recharge ticking → show swipe
                end
                return true  -- fully charged → CD shown is GCD
            end

            -- PATH B: secret values → use cache + charge Duration Object
            if chargeSpellCache[spellID] then
                -- We know this is a charge spell; check if recharge is active
                if C_Spell.GetSpellChargesCooldownDuration then
                    local ok2, chargeDObj = pcall(C_Spell.GetSpellChargesCooldownDuration, spellID)
                    if ok2 and chargeDObj then
                        local isLong = IsDurationLongerThanGCD(chargeDObj)
                        if isLong == true then
                            return false  -- recharge > 2 s → show swipe
                        elseif isLong == false then
                            -- remaining ≤ 2 s: could be tail-end of recharge
                            -- or GCD on a fully-charged spell — show swipe
                            -- to be safe (avoids clipping last 2 s of recharge)
                            return false
                        end
                    end
                end
                -- Charge duration unavailable; for a known charge spell
                -- default to showing swipe (safer than hiding recharge)
                return false
            end
        end
    end

    -- ==================================================================
    -- PATH 1: SpellCooldownInfo.isOnGCD  (non-secret if readable)
    -- ==================================================================
    if spellID and C_Spell and C_Spell.GetSpellCooldown then
        local ok, cdInfo = pcall(C_Spell.GetSpellCooldown, spellID)
        if ok and cdInfo then
            local isOnGCD   = cdInfo.isOnGCD
            local duration  = cdInfo.duration

            -- Check if isOnGCD is readable (non-secret)
            local gcdReadable = isOnGCD ~= nil
                and not (issecretvalue and issecretvalue(isOnGCD))
            if gcdReadable then
                return isOnGCD == true  -- definitive
            end

            -- isOnGCD is secret; check duration if readable
            local durReadable = duration ~= nil
                and type(duration) == "number"
                and not (issecretvalue and issecretvalue(duration))
            if durReadable then
                if duration < 0.5 then return false end   -- off CD
                if duration <= 1.0 then return true end   -- ≤ 1 s is always GCD
                local gcd = GetGCDDuration()
                if gcd and gcd > 0 and math.abs(duration - gcd) < 0.01 then
                    return true  -- duration matches GCD exactly
                end
                return false  -- longer than GCD → real CD
            end
        end
    end

    -- ==================================================================
    -- PATH 2: Raw duration from SetCooldown hook  (works outside combat)
    -- ==================================================================
    if hookDur ~= nil then
        local isSecret = issecretvalue and issecretvalue(hookDur)
        if not isSecret and type(hookDur) == "number" then
            if hookDur <= 0 then return false end         -- no cooldown
            if hookDur <= 1.8 then return true end        -- GCD range
            local gcd = GetGCDDuration()
            if gcd and gcd > 0 and math.abs(hookDur - gcd) < 0.05 then
                return true  -- matches GCD duration
            end
            return false  -- longer than GCD → real CD
        end
    end

    -- ==================================================================
    -- PATH 3: Curve-based check on Duration Object  (fully secret-safe)
    -- ==================================================================
    if durationObject then
        local isLong = IsDurationLongerThanGCD(durationObject)
        if isLong == true then
            return false  -- remaining > 2 s → real CD
        elseif isLong == false then
            return true   -- remaining ≤ 2 s → GCD
        end
    end

    -- ==================================================================
    -- PATH 4: Can't determine → default to showing sweep (don't hide)
    -- ==================================================================
    return false
end

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

    for i = 1, (viewer:GetNumChildren() or 0) do
        local child = select(i, viewer:GetChildren())
        if child and IsIcon(child) then
            icons[#icons + 1] = child
        elseif child and child.GetNumChildren then
            for j = 1, (child:GetNumChildren() or 0) do
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
-- GET spellID FROM a CDM icon  (best-effort)
-- Blizzard's CDM icons store the tracked spell in various fields.
-- ============================================================================

local function GetSpellIDFromIcon(icon)
    if not icon then return nil end

    -- Direct properties (Blizzard CDM icons, TweaksUI custom icons, etc.)
    local id = icon.spellID or icon.SpellID or icon.spellId or icon._spellID or icon.trackID

    -- Method call (some Blizzard frames expose GetSpellID())
    if not id and icon.GetSpellID then
        pcall(function() id = icon:GetSpellID() end)
    end

    -- Validate: must be a real, non-secret number
    if id then
        if issecretvalue and issecretvalue(id) then
            return id  -- secret but still passable to C_Spell APIs
        end
        if type(id) == "number" and id > 0 then
            return id
        end
    end
    return nil
end

-- ============================================================================
-- APPLY / REMOVE SWEEP ON A SINGLE COOLDOWN FRAME
-- ============================================================================

local function SuppressSweep(cd)
    pcall(function()
        cd:SetDrawSwipe(false)
        if HIDE_EDGE then cd:SetDrawEdge(false) end
    end)
end

local function RestoreSweep(cd)
    pcall(function()
        cd:SetDrawSwipe(true)
        cd:SetDrawEdge(true)
    end)
end

-- ============================================================================
-- HOOK A COOLDOWN FRAME
-- Hooks SetCooldown and SetCooldownFromDurationObject.
-- Rather than reading the hook's duration parameter (which may be secret/
-- tainted), we query C_Spell.GetSpellCooldown().isOnGCD and use the
-- curve fallback when that value is secret.
-- ============================================================================

local function HookCooldownFrame(cd, icon)
    if not cd or hookedCooldowns[cd] then return end
    hookedCooldowns[cd] = true

    -- Store the parent icon so we can look up spellID later
    cd._HGS_icon = icon

    -- ---------- SetCooldown (classic API) ----------
    hooksecurefunc(cd, "SetCooldown", function(self, start, dur)
        -- Get a fresh Duration Object for the curve fallback
        local parentIcon = self._HGS_icon
        local spellID = parentIcon and GetSpellIDFromIcon(parentIcon)
        local dObj
        if spellID and C_Spell and C_Spell.GetSpellCooldownDuration then
            local ok, d = pcall(C_Spell.GetSpellCooldownDuration, spellID)
            if ok then dObj = d end
        end

        if IsGCD(spellID, dObj, dur) then
            SuppressSweep(self)
        end
    end)

    -- ---------- SetCooldownFromDurationObject (Midnight API) ----------
    if cd.SetCooldownFromDurationObject then
        hooksecurefunc(cd, "SetCooldownFromDurationObject", function(self, dObj)
            local parentIcon = self._HGS_icon
            local spellID = parentIcon and GetSpellIDFromIcon(parentIcon)
            if IsGCD(spellID, dObj, nil) then
                SuppressSweep(self)
            end
        end)
    end

    -- ---------- Prevent Blizzard from re-enabling swipe during GCD ----------
    local suppressingSwipe = false
    hooksecurefunc(cd, "SetDrawSwipe", function(self, drawSwipe)
        if suppressingSwipe then return end
        if not drawSwipe then return end  -- already hidden, nothing to do

        local parentIcon = self._HGS_icon
        local spellID = parentIcon and GetSpellIDFromIcon(parentIcon)
        local dObj
        if spellID and C_Spell and C_Spell.GetSpellCooldownDuration then
            local ok, d = pcall(C_Spell.GetSpellCooldownDuration, spellID)
            if ok then dObj = d end
        end

        if IsGCD(spellID, dObj, nil) then
            suppressingSwipe = true
            self:SetDrawSwipe(false)
            suppressingSwipe = false
        end
    end)

    if HIDE_EDGE then
        local suppressingEdge = false
        hooksecurefunc(cd, "SetDrawEdge", function(self, drawEdge)
            if suppressingEdge then return end
            if not drawEdge then return end

            local parentIcon = self._HGS_icon
            local spellID = parentIcon and GetSpellIDFromIcon(parentIcon)
            local dObj
            if spellID and C_Spell and C_Spell.GetSpellCooldownDuration then
                local ok, d = pcall(C_Spell.GetSpellCooldownDuration, spellID)
                if ok then dObj = d end
            end

            if IsGCD(spellID, dObj, nil) then
                suppressingEdge = true
                self:SetDrawEdge(false)
                suppressingEdge = false
            end
        end)
    end
end

-- ============================================================================
-- PROCESS VIEWERS
-- ============================================================================

local function ProcessViewer(globalName)
    local viewer = _G[globalName]
    if not viewer then return end

    for _, icon in ipairs(CollectIcons(viewer)) do
        local cd = GetCooldownFrame(icon)
        if cd then
            HookCooldownFrame(cd, icon)
        end
    end
end

local function ProcessAllViewers()
    for _, name in ipairs(VIEWERS) do
        ProcessViewer(name)
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

    if viewer.Show then
        hooksecurefunc(viewer, "Show", function()
            C_Timer.After(0.1, function() ProcessViewer(globalName) end)
        end)
    end
    if viewer.SetShown then
        hooksecurefunc(viewer, "SetShown", function()
            C_Timer.After(0.1, function() ProcessViewer(globalName) end)
        end)
    end
end

-- ============================================================================
-- COMBAT SCANNER – pick up dynamically-created icon frames during combat
-- ============================================================================

local SCAN_INTERVAL = 0.5
local scanElapsed   = 0

local scannerFrame = CreateFrame("Frame")
scannerFrame:Hide()
scannerFrame:SetScript("OnUpdate", function(self, elapsed)
    scanElapsed = scanElapsed + elapsed
    if scanElapsed < SCAN_INTERVAL then return end
    scanElapsed = 0
    ProcessAllViewers()
end)

-- ============================================================================
-- EVENT HANDLING
-- ============================================================================

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("SPELL_DATA_LOAD_RESULT")

frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(1, function()
            for _, name in ipairs(VIEWERS) do StartMonitoringViewer(name) end
            ProcessAllViewers()
        end)

    elseif event == "PLAYER_REGEN_DISABLED" then
        ProcessAllViewers()
        scanElapsed = 0
        scannerFrame:Show()

    elseif event == "PLAYER_REGEN_ENABLED" then
        scannerFrame:Hide()
        C_Timer.After(0.5, ProcessAllViewers)

    elseif event == "PLAYER_SPECIALIZATION_CHANGED"
        or event == "SPELL_DATA_LOAD_RESULT" then
        C_Timer.After(0.5, ProcessAllViewers)
    end
end)
