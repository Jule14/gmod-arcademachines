AM = AM or {
    QueuedSounds = {}
}

include("shared.lua")
include("cl_hooks.lua")

local Debug = CreateClientConVar("arcademachine_debug", 0, true, false)
AM.FOV = CreateClientConVar("arcademachine_fov", 70, true, false)
AM.DisableBloom = CreateClientConVar("arcademachine_disable_bloom", 1, true, false)
AM.DisablePAC = CreateClientConVar("arcademachine_disable_pac", 1, true, false)
--AM.DisableOutfitter = CreateClientConVar("arcademachine_disable_outfitter", 1, true, false)
AM.DisableOthers = CreateClientConVar("arcademachine_disable_others_when_active", 0, true, false)

local MaxDist = 200

local ScreenWidth = 512
local ScreenHeight = 512
local MarqueeWidth = 512
local MarqueeHeight = 179

local PressedWalk = false
local PressedUse = false
local PressedUseAt = 0

local BloomWasDisabled = false
local PACWasDisabled = false
--local OutfitterWasDisabled = false

local LoadedLibs = {}

surface.CreateFont("AMInfoFont", {
    font = "Tahoma",
    extended = true,
    size = 16
})

surface.CreateFont("AMInfoFontBold", {
    font = "Tahoma",
    extended = true,
    size = 16,
    weight = 1000
})

local function DebugPrint(...)
    if Debug:GetBool() then
        print("[ARCADE]", ...)
    end
end

concommand.Add("arcademachine_reload_machines", function()
    for _, v in ipairs(ents.FindByClass("arcademachine")) do
        if v:GetCurrentGame() then
            v:SetGame(v:GetCurrentGame())
        elseif v.Game then
            if v.Game.Destroy then
                v.Game:Destroy()
            end
            if v.Game.Init then
                v.Game:Init()
            end
        end
    end
end)

concommand.Add("arcademachine_clear_cache", function()
    local paths = {
        "images",
        "files"
    }

    local base = "arcademachines/cache/"

    for _, v in ipairs(paths) do
        for _, fv in ipairs(file.Find(base .. v .. "/*", "DATA")) do
            file.Delete(base .. v .. "/" .. fv)
        end
    end
end)

local BG = {
    BG_GENERIC_JOYSTICK = 0,
    BG_GENERIC_TRACKBALL = 1,
    BG_GENERIC_RECESSED_JOYSTICK = 2,
    BG_GENERIC_RECESSED_TRACKBALL = 3,
    BG_DRIVING = 4
}

local Bodygroups = {
    [BG.BG_GENERIC_JOYSTICK] = { 0, 0 },
    [BG.BG_GENERIC_TRACKBALL] = { 0, 2 },
    [BG.BG_GENERIC_RECESSED_JOYSTICK] = { 1, 0 },
    [BG.BG_GENERIC_RECESSED_TRACKBALL] = { 1, 2 },
    [BG.BG_DRIVING] = { 2, 3 }
}

local function WrappedInclusion(path, upvalues)
    local gameMeta = setmetatable(upvalues, { __index = _G, __newindex = _G })

    local gameFunc = (isfunction(path) and path or CompileFile(path))
    setfenv(gameFunc, gameMeta)
    return gameFunc()
end

ENT.Initialized = false

function ENT:Initialize()
    self.Initialized = true
    self.MarqueeHasDrawn = false

    local num = math.random(9999)

    self.ScreenTexture = GetRenderTargetEx(
        "ArcadeMachine_Screen_" .. self:EntIndex() .. "_" .. num,
        ScreenWidth,
        ScreenHeight,
        RT_SIZE_DEFAULT,
        MATERIAL_RT_DEPTH_NONE,
        1,
        CREATERENDERTARGETFLAGS_HDR,
        IMAGE_FORMAT_DEFAULT
    )
    self.ScreenMaterial = CreateMaterial(
        "ArcadeMachine_Screen_Material_" .. self:EntIndex() .. "_" .. num,
        "VertexLitGeneric",
        {
            ["$basetexture"] = self.ScreenTexture:GetName(),
            ["$model"] = 1,
            ["$selfillum"] = 1,
            ["$selfillummask"] = "dev/reflectivity_30b"
        }
    )

    self.MarqueeTexture = GetRenderTargetEx(
        "ArcadeMachine_Marquee_" .. self:EntIndex() .. "_" .. num,
        MarqueeWidth,
        256, -- Not the same as the drawable area
        RT_SIZE_DEFAULT,
        MATERIAL_RT_DEPTH_NONE,
        16,
        CREATERENDERTARGETFLAGS_HDR,
        IMAGE_FORMAT_DEFAULT
    )
    self.MarqueeMaterial = CreateMaterial(
        "ArcadeMachine_Marquee_Material_" .. self:EntIndex() .. "_" .. num,
        "VertexLitGeneric",
        {
            ["$basetexture"] = self.MarqueeTexture:GetName(),
            ["$model"] = 1,
            ["$nodecal"] = 1,
            ["$selfillum"] = 1,
            ["$selfillummask"] = "dev/reflectivity_30b"
        }
    )

    self.InRange = self.InRange or false
    self.Game = self.Game or nil
    self.LoadedSounds = self.LoadedSounds or {}
    
    -- Used to work around network variable spamming being changed from
    -- empty to a game and back again when loaded into room on MS
    self.AllowGameChangeAt = 0

    if self:GetCurrentGame() and not self.Game then
        self:SetGame(self:GetCurrentGame())
    end

    self:UpdateMarquee()
    self:UpdateScreen()
end

function ENT:OnRemove()
    if self.Game and self.Game.Destroy then
        self.Game:Destroy()
    end

    self:StopSounds()
end

function ENT:Think()
    -- Work around init not being called on the client sometimes
    if not self.Initialized then
        self:Initialize()
    end

    -- Workaround network var notify not triggering for null entity
    if self.LastPlayer and self.LastPlayer ~= self:GetPlayer() then
        self:OnPlayerChange("Player", self.LastPlayer, self:GetPlayer())
    end

    -- If we weren't nearby when the machine was spawned we won't get notified
    -- when the seat was created so manually call
    if IsValid(self:GetSeat()) and not self:GetSeat().ArcadeMachine then
        self:OnSeatCreated("Seat", nil, self:GetSeat())
    end

    if self.LastGameNWVar ~= nil and self.AllowGameChangeAt - RealTime() <= 0 then
        DebugPrint(self:EntIndex(), "change game to", self.LastGameNWVar, "at", RealTime())
        self:SetGame(self.LastGameNWVar)
        self.LastGameNWVar = nil
        self.AllowGameChangeAt = RealTime() + 1
    end

    -- Used to work around GetCoins not returning the correct value after the
    -- network var notify was called
    if self.CoinChange and self.CoinChange.new == self:GetCoins() and IsValid(self:GetPlayer()) then
        if self.Game then
            if self.CoinChange.new > self.CoinChange.old and self.Game.OnCoinsInserted then
                self.Entity:EmitSound("ambient/levels/labs/coinslot1.wav", 50)
                self.Game:OnCoinsInserted(self:GetPlayer(), self.CoinChange.old, self.CoinChange.new)
            end
        
            if self.CoinChange.new < self.CoinChange.old and self.Game.OnCoinsLost then
                self.Game:OnCoinsLost(self:GetPlayer(), self.CoinChange.old, self.CoinChange.new)
            end
        end
        
        self.CoinChange = nil
    end

    if self.Game and self.Game.Bodygroup and Bodygroups[self.Game.Bodygroup] then
        self.Entity:SetBodygroup(0, Bodygroups[self.Game.Bodygroup][1])
        self.Entity:SetBodygroup(1, Bodygroups[self.Game.Bodygroup][2])
    end

    if AM.DisableOthers:GetBool() and AM.CurrentMachine and AM.CurrentMachine ~= self then
        return
    end

    if LocalPlayer() and LocalPlayer():GetPos():DistToSqr(self.Entity:GetPos()) > MaxDist * MaxDist then
        if self.InRange then
            self.InRange = false
            self:OnLeftRange()
        end
    else
        if not self.InRange then
            self.InRange = true
            self:OnEnteredRange()
        end
    end

    if self.InRange and self.Game then
        if IsValid(self:GetPlayer()) and self:GetPlayer() == LocalPlayer() then
            local pressed = input.LookupBinding("+walk") and self:GetPlayer():KeyDown(IN_WALK) or input.IsKeyDown(KEY_LALT)

            if pressed then
                if not PressedWalk then
                    PressedWalk = true

                    local cost = self:GetMSCoinCost()

                    if cost > 0 and LocalPlayer().GetCoins and LocalPlayer():GetCoins() < cost then
                        notification.AddLegacy("You don't have enough coins!", NOTIFY_ERROR, 5)
                        return
                    end

                    net.Start("arcademachine_insertcoin")
                    net.SendToServer()
                end
            else
                PressedWalk = false
            end
        end

        for _, v in pairs(self.LoadedSounds) do
            if IsValid(v) then
                v:SetPos(self.Entity:GetPos())
            end
        end

        self.Game:Update()
    end
end

function ENT:OnEnteredRange()
    self:UpdateScreen()
end

function ENT:OnLeftRange()
    self:UpdateScreen()
end

function ENT:Draw()
    local marqueeIndex = self.Entity:GetBodygroup(0)

    if IsValid(AM.CurrentMachine) and AM.CurrentMachine == self and not LocalPlayer():ShouldDrawLocalPlayer() then
        cam.IgnoreZ(true)
    end

    -- To prevent using string table slots, don't set the submaterial on the server
    -- and just override it here
    render.MaterialOverrideByIndex(marqueeIndex == 2 and 7 or 3, self.MarqueeMaterial)
    render.MaterialOverrideByIndex(4, self.ScreenMaterial)
    self.Entity:DrawModel()
    render.MaterialOverrideByIndex()

    if IsValid(AM.CurrentMachine) and AM.CurrentMachine == self and not LocalPlayer():ShouldDrawLocalPlayer() then
        cam.IgnoreZ(false)
    end

    if not self.InRange or not self.Game or (AM.DisableOthers:GetBool() and AM.CurrentMachine and AM.CurrentMachine ~= self) then
        return
    end

    self:UpdateScreen()
end

-- Isn't called when player becomes nil...
function ENT:OnPlayerChange(name, old, new)
    if IsValid(new) then
        if old ~= new then
            if old and self.Game then
                self.Game:OnStopPlaying(old)
            end

            if self.Game then
                self.Game:OnStartPlaying(new)
            end
            
            self.LastPlayer = new

            if new == LocalPlayer() then
                self:OnLocalPlayerEntered()
            end
        end
    else
        if self.Game then
            self.Game:OnStopPlaying(old)
        end

        self.LastPlayer = nil

        if old == LocalPlayer() then
            self:OnLocalPlayerLeft()
        end
    end
end

function ENT:OnLocalPlayerEntered()
    AM.CurrentMachine = self

    if AM.DisableBloom:GetBool() and not cvars.Bool("mat_disable_bloom") then
        LocalPlayer():ConCommand("mat_disable_bloom 1")
        BloomWasDisabled = true
    end

    if AM.DisablePAC:GetBool() and pac and pac.IsEnabled() then
        pac.Disable()
        PACWasDisabled = true
    else
        PACWasDisabled = false
    end

    --[[if AM.DisableOutfitter:GetBool() and outfitter then
        outfitter.SetHighPerf(true, true)
        outfitter.DisableEverything()
        OutfitterWasDisabled = true
    else
        OutfitterWasDisabled = false
    end--]]
end

function ENT:OnLocalPlayerLeft()
    AM.CurrentMachine = nil

    if AM.DisableBloom:GetBool() and BloomWasDisabled then
        LocalPlayer():ConCommand("mat_disable_bloom 0")
    end

    if AM.DisablePAC:GetBool() and PACWasDisabled then
        pac.Enable()
    end

    --[[if AM.DisableOutfitter:GetBool() and OutfitterWasDisabled then
        outfitter.SetHighPerf(false, true)
        outfitter.EnableEverything()
    end--]]
end

function ENT:UpdateMarquee()
    if self.MarqueeHasDrawn then return end

    render.PushRenderTarget(self.MarqueeTexture)
        cam.Start2D()
            surface.SetDrawColor(0, 0, 0, 255)
            surface.DrawRect(0, 0, MarqueeWidth, MarqueeHeight)

            if self.Game and self.Game.DrawMarquee then
                self.Game:DrawMarquee()
                self.MarqueeHasDrawn = true
            else
                surface.SetFont("DermaLarge")
                local w, h = surface.GetTextSize(self.Game and self.Game.Name or "Arcade Machine")
                surface.SetTextColor(255, 255, 255, 255)
                surface.SetTextPos((MarqueeWidth / 2) - (w / 2), (MarqueeHeight / 2) - (h / 2))
                surface.DrawText(self.Game and self.Game.Name or "Arcade Machine")
            end
        cam.End2D()
    render.PopRenderTarget()
end

function ENT:UpdateScreen()
    render.PushRenderTarget(self.ScreenTexture)
        cam.Start2D()
            surface.SetDrawColor(0, 0, 0, 255)
            surface.DrawRect(0, 0, ScreenWidth, ScreenHeight)

            if self.InRange then
                if self.Game then
                    self.Game:Draw()
                else
                    surface.SetFont("DermaLarge")
                    local w, h = surface.GetTextSize("NO GAME LOADED")
                    surface.SetTextColor(255, 255, 255, 255)
                    surface.SetTextPos((ScreenWidth / 2) - (w / 2), ScreenHeight / 2)
                    surface.DrawText("NO GAME LOADED")
                end
            end
        cam.End2D()
    render.PopRenderTarget()
end

function ENT:OnCoinsChange(name, old, new)
    self.CoinChange = { old = old, new = new }
end

function ENT:OnGameChange(name, old, new)
    if old == new then return end

    DebugPrint(
        self:EntIndex(),
        "new", new,
        "old", old,
        "at", RealTime(),
        "remain", self.AllowGameChangeAt ~= 0 and self.AllowGameChangeAt - RealTime() or "(first load)"
    )

    self.LastGameNWVar = new

    if self.AllowGameChangeAt == 0 or self.AllowGameChangeAt - RealTime() > 0 then
        self.AllowGameChangeAt = RealTime() + 1
        DebugPrint(self:EntIndex(), "delaying game change until", self.AllowGameChangeAt)
    end
end

function ENT:StopSounds()
    for k, v in pairs(self.LoadedSounds) do
        if IsValid(v) then
            v:Stop()
        end
    end

    table.Empty(self.LoadedSounds)
    if AM.QueuedSounds[self:EntIndex()] then
        AM.QueuedSounds[self:EntIndex()] = nil
    end
end

function ENT:GetUpvalues(game)
    local upvalues = {
        SCREEN_WIDTH = ScreenWidth,
        SCREEN_HEIGHT = ScreenHeight,
        MARQUEE_WIDTH = MarqueeWidth,
        MARQUEE_HEIGHT = MarqueeHeight
    }

    for k, v in pairs(BG) do
        upvalues[k] = v
    end

    if LoadedLibs[game] and not forceLibLoad then
        upvalues.COLLISION = LoadedLibs[game].COLLISION
        upvalues.IMAGE = LoadedLibs[game].IMAGE
        upvalues.FONT = LoadedLibs[game].FONT
        upvalues.FILE = LoadedLibs[game].FILE
    else
        LoadedLibs[game] = {
            COLLISION = include("arcademachine_lib/collision.lua"),
            IMAGE = include("arcademachine_lib/image.lua"),
            FONT = include("arcademachine_lib/font.lua"),
            FILE = include("arcademachine_lib/file.lua")
        }

        upvalues.COLLISION = LoadedLibs[game].COLLISION
        upvalues.IMAGE = LoadedLibs[game].IMAGE
        upvalues.FONT = LoadedLibs[game].FONT
        upvalues.FILE = LoadedLibs[game].FILE
    end

    -- Allow each instance to have its own copy of sound library in case they want to
    -- play the same sound at the same time (needs to emit from the machine)
    upvalues.SOUND = WrappedInclusion("arcademachine_lib/sound.lua", { MACHINE = self, QUEUE = AM.QueuedSounds })

    upvalues.COINS = WrappedInclusion("arcademachine_lib/coins.lua", { MACHINE = self })
    upvalues.MARQUEE = WrappedInclusion("arcademachine_lib/marquee.lua", { MACHINE = self })

    return upvalues
end

function ENT:SetGame(game, forceLibLoad)
    if self.Game then
        if self.Game.Destroy then
            self.Game:Destroy()
        end
        self.Game = nil
    end

    self:StopSounds()

    if game and game ~= "" then
        self.Game = WrappedInclusion(isfunction(game) and game or "arcademachine_games/" .. game .. ".lua", self:GetUpvalues(game))

        if self.Game.Init then
            self.Game:Init()
        end

        if IsValid(self:GetPlayer()) then
            self.Game:OnStartPlaying(self:GetPlayer())
        end
    end

    self.MarqueeHasDrawn = false
    if not self.Game or (self.Game and not self.Game.LateUpdateMarquee) then
        self:UpdateMarquee()
    end
    self:UpdateScreen()
end