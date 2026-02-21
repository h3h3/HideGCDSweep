-- HideGCDSweep – hide the GCD-only swipe/edge on Cooldown Manager icons
--
-- When a spell is merely on the Global Cooldown (not a real ability cooldown)
-- the sweep animation is suppressed.  Real cooldown sweeps are left intact.
--
-- Hooks CooldownFrame_Set globally and checks if the parent frame is a
-- CooldownViewer cooldown item whose .isOnGCD flag is true.

local DEBUG = false

local function dbg(fmt, ...)
    if DEBUG then
        print("[HGS] " .. fmt:format(...))
    end
end

dbg("[HGS] loaded")

hooksecurefunc("CooldownFrame_Set", function(self)
    local parent = self:GetParent()
    -- Only act on CooldownViewer cooldown items (Essential / Utility)
    if not parent or not parent.RefreshSpellCooldownInfo then return end

    -- When the visual is driven by charge recharge data, isOnGCD can be
    -- stale from the prior GCD cycle.  Never suppress charge cooldowns.
    if parent.isOnGCD and not parent.wasSetFromCharges then
        self:SetDrawSwipe(false)
        self:SetDrawEdge(false)
        if DEBUG then
            local spellID = parent.GetSpellID and parent:GetSpellID()
            local name = spellID and C_Spell.GetSpellName(spellID) or "?"
            dbg("GCD swipe HIDDEN - %s (id %s, dur %.2f)",
                name, tostring(spellID), parent.cooldownDuration or 0)
        end
    else
        if DEBUG then
            local spellID = parent.GetSpellID and parent:GetSpellID()
            local name = spellID and C_Spell.GetSpellName(spellID) or "?"
            dbg("Real CD kept - %s (id %s, dur %.2f, active %s, charges %s)",
                name, tostring(spellID), parent.cooldownDuration or 0,
                tostring(parent.isOnActualCooldown), tostring(parent.wasSetFromCharges))
        end
    end
end)
