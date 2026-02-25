-- HideGCDSweep – hide the GCD-only swipe/edge on Cooldown Manager icons
--
-- When a spell is merely on the Global Cooldown (not a real ability cooldown)
-- the sweep animation is suppressed.  Real cooldown sweeps are left intact.
--
-- Hooks CooldownFrame_Set globally and checks if the parent frame is a
-- CooldownViewer cooldown item whose RefreshSpellCooldownInfo/isOnGCD flag is true.

local DEBUG = false

local function dbg(fmt, ...)
    if DEBUG then
        print("[HGS] " .. fmt:format(...))
    end
end

hooksecurefunc("CooldownFrame_Set", function(self)
    if not self then return end
    local parent = self:GetParent()
    if not parent or not parent.RefreshSpellCooldownInfo then return end

    if parent.isOnGCD and not parent.wasSetFromCharges then
        self:SetDrawSwipe(false)
        self:SetDrawEdge(false)

        if DEBUG then
            local spellID = parent.GetSpellID and parent:GetSpellID()
            local name = spellID and C_Spell.GetSpellName(spellID) or "?"
            dbg("HIDDEN - %s (id %s, dur %.2f)", name, tostring(spellID), parent.cooldownDuration or 0)
        end
    end
end)
