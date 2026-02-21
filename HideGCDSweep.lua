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
local DEBUG     = false  -- Set to true to print debug info to chat

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
-- DEBUG HELPER
-- ============================================================================

local function D(...)
    if not DEBUG then return end
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v == nil then
            parts[#parts + 1] = "nil"
        elseif issecretvalue and issecretvalue(v) then
            parts[#parts + 1] = "<secret>"
        else
            parts[#parts + 1] = tostring(v)
        end
    end
    print("|cff00ccff[HGS]|r " .. table.concat(parts, " "))
end

-- ============================================================================
-- PRE-SCAN: Populate chargeSpellCache from spellbook (runs out of combat)
-- ============================================================================

local function PreScanChargeSpells()
    if not C_SpellBook or not C_Spell or not C_Spell.GetSpellCharges then return end
    local bankEnum = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
    if not bankEnum or not C_SpellBook.GetNumSpellBookItems then return end

    local count = 0
    local numSpells = C_SpellBook.GetNumSpellBookItems(bankEnum) or 0
    for i = 1, numSpells do
        local ok, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, bankEnum)
        if ok and info and info.spellID then
            local ok2, chargeInfo = pcall(C_Spell.GetSpellCharges, info.spellID)
            if ok2 and chargeInfo then
                local max = chargeInfo.maxCharges
                if max and type(max) == "number" and max > 1 then
                    chargeSpellCache[info.spellID] = true
                    count = count + 1
                end
            end
        end
    end
    D("PreScan: cached", count, "charge spells")
end

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
-- NEAR-ZERO CURVE  (secret-safe)
--
-- Distinguishes "essentially zero" cooldown (fully charged) from an active
-- recharge that still has time left:
--   remaining ≤ 0.1 s  →  0  (no active recharge – fully charged)
--   remaining > 0.1 s  →  1  (recharge in progress)
-- ============================================================================

local nearZeroCurve

local function GetNearZeroCurve()
    if nearZeroCurve then return nearZeroCurve end
    if not C_CurveUtil or not C_CurveUtil.CreateCurve then return nil end
    if not Enum or not Enum.LuaCurveType then return nil end

    local ok, curve = pcall(function()
        local c = C_CurveUtil.CreateCurve()
        c:SetType(Enum.LuaCurveType.Linear)
        c:AddPoint(0,    0)   -- 0 s remaining    → 0  (fully charged)
        c:AddPoint(0.1,  0)   -- 0.1 s remaining  → 0  (essentially zero)
        c:AddPoint(0.11, 1)   -- 0.11 s            → 1  (recharge active)
        c:AddPoint(600,  1)   -- 10 min            → 1
        return c
    end)
    if ok and curve then nearZeroCurve = curve end
    return nearZeroCurve
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
-- SECRET-SAFE NEAR-ZERO CHECK
-- Returns true (remaining ≤ 0.1 s — essentially zero), false (> 0.1 s), or nil
-- ============================================================================

local function IsDurationNearZero(dObj)
    local curve = GetNearZeroCurve()
    if not curve or not C_StringUtil or not C_StringUtil.TruncateWhenZero then return nil end

    local ok, result = pcall(dObj.EvaluateRemainingDuration, dObj, curve)
    if not ok or result == nil then return nil end

    local ok2, str = pcall(C_StringUtil.TruncateWhenZero, result)
    if not ok2 then return nil end

    -- str is secret → curve returned 1 → remaining > 0.1 s → recharge active
    -- str is ""     → curve returned 0 → remaining ≤ 0.1 s → fully charged
    if issecretvalue and issecretvalue(str) then
        return false
    end
    return true
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

            if curReadable and maxReadable then
                if max > 1 then
                    -- PATH A: readable multi-charge spell → cache and branch
                    chargeSpellCache[spellID] = true
                    if cur < max then
                        return false, "CHG-A:recharging(" .. cur .. "/" .. max .. ")"
                    end
                    return true, "CHG-A:full(" .. cur .. "/" .. max .. ")"
                end
                -- max == 1 → not a real charge spell, skip charge logic
            elseif chargeSpellCache[spellID] then
                -- PATH B: secret values, but we previously confirmed max > 1
                local rechargeDetected = false
                if C_Spell.GetSpellChargesCooldownDuration then
                    local ok2, chargeDObj = pcall(C_Spell.GetSpellChargesCooldownDuration, spellID)
                    if ok2 and chargeDObj then
                        local isNearZero = IsDurationNearZero(chargeDObj)
                        if isNearZero == true then
                            return true, "CHG-B:full(near-zero)"
                        elseif isNearZero == false then
                            rechargeDetected = true
                        end
                    end
                end
                if rechargeDetected then
                    return false, "CHG-B:recharging(API)"
                end
                return false, "CHG-B:unknown=>show"
            end
            -- Not cached and not readable as multi-charge → fall through to PATH 1
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
                return isOnGCD == true, "P1:isOnGCD=" .. tostring(isOnGCD)
            end

            -- isOnGCD is secret; check duration if readable
            local durReadable = duration ~= nil
                and type(duration) == "number"
                and not (issecretvalue and issecretvalue(duration))
            if durReadable then
                if duration < 0.5 then return false, "P1:dur=" .. duration .. "<0.5" end
                if duration <= 1.0 then return true, "P1:dur=" .. duration .. "<=1.0" end
                local gcd = GetGCDDuration()
                if gcd and gcd > 0 and math.abs(duration - gcd) < 0.01 then
                    return true, "P1:dur=" .. duration .. "=gcd"
                end
                return false, "P1:dur=" .. duration .. ">gcd"
            end
        end
    end

    -- ==================================================================
    -- PATH 2: Raw duration from SetCooldown hook  (works outside combat)
    -- ==================================================================
    if hookDur ~= nil then
        local isSecret = issecretvalue and issecretvalue(hookDur)
        if not isSecret and type(hookDur) == "number" then
            if hookDur <= 0 then return false, "P2:dur=" .. hookDur .. "<=0" end
            if hookDur <= 1.8 then return true, "P2:dur=" .. hookDur .. "<=1.8" end
            local gcd = GetGCDDuration()
            if gcd and gcd > 0 and math.abs(hookDur - gcd) < 0.05 then
                return true, "P2:dur=" .. hookDur .. "=gcd"
            end
            return false, "P2:dur=" .. hookDur .. ">gcd"
        end
    end

    -- ==================================================================
    -- PATH 3: Curve-based check on Duration Object  (fully secret-safe)
    -- ==================================================================
    if durationObject then
        local isLong = IsDurationLongerThanGCD(durationObject)
        if isLong == true then
            return false, "P3:curve>2s"
        elseif isLong == false then
            return true, "P3:curve<=2s"
        end
    end

    -- ==================================================================
    -- PATH 4: Can't determine → default to showing sweep (don't hide)
    -- ==================================================================
    return false, "P4:unknown=>show"
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
        local parentIcon = self._HGS_icon
        local spellID = parentIcon and GetSpellIDFromIcon(parentIcon)
        local dObj
        if spellID and C_Spell and C_Spell.GetSpellCooldownDuration then
            local ok, d = pcall(C_Spell.GetSpellCooldownDuration, spellID)
            if ok then dObj = d end
        end

        local result, reason = IsGCD(spellID, dObj, dur)
        D("SetCD ", spellID, " dur=", dur, " ", reason, result and " => HIDE" or "")
        if result then
            SuppressSweep(self)
        end
    end)

    -- ---------- SetCooldownFromDurationObject (Midnight API) ----------
    if cd.SetCooldownFromDurationObject then
        hooksecurefunc(cd, "SetCooldownFromDurationObject", function(self, dObj)
            local parentIcon = self._HGS_icon
            local spellID = parentIcon and GetSpellIDFromIcon(parentIcon)
            local result, reason = IsGCD(spellID, dObj, nil)
            D("SetCDObj ", spellID, " ", reason, result and " => HIDE" or "")
            if result then
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

        local result, reason = IsGCD(spellID, dObj, nil)
        D("Swipe+ ", spellID, " ", reason, result and " => RE-HIDE" or "")
        if result then
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

            local result, reason = IsGCD(spellID, dObj, nil)
            D("Edge+ ", spellID, " ", reason, result and " => RE-HIDE" or "")
            if result then
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
        -- Cache charge spell status from the icon's actual spellID
        local sid = GetSpellIDFromIcon(icon)
        if sid and type(sid) == "number"
           and not (issecretvalue and issecretvalue(sid))
           and C_Spell and C_Spell.GetSpellCharges then
            local cOk, cInfo = pcall(C_Spell.GetSpellCharges, sid)
            if cOk and cInfo then
                local m = cInfo.maxCharges
                if m and type(m) == "number"
                   and not (issecretvalue and issecretvalue(m))
                   and m > 1 then
                    if not chargeSpellCache[sid] then
                        chargeSpellCache[sid] = true
                        D("Cached charge spell", sid, "max=", m)
                    end
                end
            end
        end

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
            PreScanChargeSpells()
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

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        wipe(chargeSpellCache)
        C_Timer.After(0.5, function()
            PreScanChargeSpells()
            ProcessAllViewers()
        end)

    elseif event == "SPELL_DATA_LOAD_RESULT" then
        C_Timer.After(0.5, ProcessAllViewers)
    end
end)
