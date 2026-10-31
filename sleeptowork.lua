-- Sleep To Work: after 14 hours of work the farmer must sleep before driving again.
-- Author: FS Modding
SleepToWork = {}

-- settings
SleepToWork.WORK_LIMIT_HOURS = 14     -- hours of work before you must sleep
SleepToWork.MIN_SLEEP_HOURS = 6       -- a sleep this long resets the work hours
SleepToWork.WARN_HOURS = {}           -- no warnings before the limit: one message when you are exhausted
SleepToWork.SLEEP_HOURS = 8           -- how long you sleep when you press R
SleepToWork.SLEEP_TIMESCALE = 600     -- how fast time runs while you sleep
SleepToWork.SKIP_MINUTES = 90         -- a time jump this big counts as sleep (in-game minutes)
SleepToWork.SHOW_HUD = true

-- state
SleepToWork.workMinutes = 0
SleepToWork.lastAbs = nil
SleepToWork.warned = {}
SleepToWork.exhausted = false
SleepToWork.loaded = false
SleepToWork.saveTimer = 0
SleepToWork.sleeping = false

local function notify(text)
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, text)
end

local function bigMessage(title, text)
    local hud = g_currentMission.hud
    if hud ~= nil and hud.showInGameMessage ~= nil then
        hud:showInGameMessage(title, text, 8000)
    else
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, title .. ": " .. text)
    end
end

local function getControlledVehicle()
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local v = g_localPlayer:getCurrentVehicle()
        if v ~= nil then return v end
    end
    local m = g_currentMission
    if m ~= nil and m.controlledVehicle ~= nil then return m.controlledVehicle end
    return nil
end

-- in-game time in minutes since the start of the save
local function absoluteMinutes()
    local env = g_currentMission.environment
    if env == nil or env.currentDay == nil or env.dayTime == nil then return nil end
    return env.currentDay * 1440 + env.dayTime / 60000
end

local function formatHours(minutes)
    local h = math.floor(minutes / 60)
    local m = math.floor(minutes % 60)
    return string.format("%dh %02dm", h, m)
end

-- ---------------------------------------------------------------- save per savegame

local function saveFile()
    local info = g_currentMission.missionInfo
    if info == nil or info.savegameDirectory == nil then return nil end
    return info.savegameDirectory .. "/sleepToWork.xml"
end

function SleepToWork:load()
    local path = saveFile()
    if path == nil or not fileExists(path) then return end
    local xml = loadXMLFile("sleepToWork", path)
    if xml == nil or xml == 0 then return end
    self.workMinutes = getXMLFloat(xml, "sleepToWork#workMinutes") or 0
    delete(xml)
    self.exhausted = self.workMinutes >= self.WORK_LIMIT_HOURS * 60
end

function SleepToWork:save()
    local path = saveFile()
    if path == nil then return end
    local xml = createXMLFile("sleepToWork", path, "sleepToWork")
    if xml == nil or xml == 0 then return end
    setXMLFloat(xml, "sleepToWork#workMinutes", self.workMinutes)
    saveXMLFile(xml)
    delete(xml)
end

-- ---------------------------------------------------------------- sleep

function SleepToWork:onSlept(minutes)
    local hours = minutes / 60
    if hours >= self.MIN_SLEEP_HOURS then
        self.workMinutes = 0
        bigMessage(g_i18n:getText("stw_title"), string.format(g_i18n:getText("stw_rested"), hours))
    else
        -- short nap: every hour of sleep gives back two hours of work
        self.workMinutes = math.max(0, self.workMinutes - minutes * 2)
        notify(string.format(g_i18n:getText("stw_nap"), hours, formatHours(self.WORK_LIMIT_HOURS * 60 - self.workMinutes)))
    end
    self.exhausted = false
    self.warned = {}
    self:save()
    Logging.info("[SleepToWork] slept %.1f h, work time now %s", hours, formatHours(self.workMinutes))
end

-- ---------------------------------------------------------------- work blocking

local function isPlayerDriving(vehicle)
    return vehicle ~= nil and vehicle.getIsEntered ~= nil and vehicle:getIsEntered()
        and not (vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive())
end

function SleepToWork:blockVehicle(vehicle)
    if vehicle.getIsMotorStarted ~= nil and vehicle:getIsMotorStarted() and vehicle.stopMotor ~= nil then
        vehicle:stopMotor()
    end
end

-- the motor of a vehicle you drive yourself will not start while you are exhausted
if Motorized ~= nil and Motorized.startMotor ~= nil then
    Motorized.startMotor = Utils.overwrittenFunction(Motorized.startMotor, function(vehicle, superFunc, ...)
        if (SleepToWork.exhausted or SleepToWork.sleeping) and isPlayerDriving(vehicle) then
            return
        end
        return superFunc(vehicle, ...)
    end)
end

-- ---------------------------------------------------------------- sleeping with R

local function getTimeScale()
    local info = g_currentMission.missionInfo
    return (info ~= nil and info.timeScale) or 1
end

local function setTimeScale(scale)
    if g_currentMission.setTimeScale ~= nil then
        g_currentMission:setTimeScale(scale)
    elseif g_currentMission.missionInfo ~= nil then
        g_currentMission.missionInfo.timeScale = scale
    end
end

-- finds a farmhouse of your farm and starts its sleep, like at the bed
function SleepToWork:useFarmhouseBed()
    local system = g_currentMission.placeableSystem
    if system == nil or system.placeables == nil then return false end
    local farmId = g_currentMission.getFarmId ~= nil and g_currentMission:getFarmId() or 1
    for _, placeable in ipairs(system.placeables) do
        local spec = placeable.spec_farmhouse
        local owner = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or nil
        if spec ~= nil and (owner == nil or owner == farmId) then
            if not self.loggedFarmhouse then
                self.loggedFarmhouse = true
                local keys = {}
                for k, v in pairs(spec) do table.insert(keys, tostring(k) .. ":" .. type(v)) end
                table.sort(keys)
                Logging.info("[SleepToWork] farmhouse spec: %s", table.concat(keys, ", "))
            end
            -- the sleeping trigger has an activatable with run() that opens the game's sleep dialog
            for key, value in pairs(spec) do
                if type(value) == "table" and type(value.run) == "function" then
                    value:run()
                    Logging.info("[SleepToWork] game sleep started through farmhouse %s:run()", tostring(key))
                    return true
                end
            end
            if placeable.onSleepTrigger ~= nil then
                placeable:onSleepTrigger()
                return true
            end
        end
    end
    return false
end

-- R: open the game's own sleep (same as the bed). Our own fast-forward is only a fallback.
function SleepToWork:onSleepKey()
    if g_currentMission == nil or self.sleeping or not self.exhausted then return end
    local vehicle = getControlledVehicle()
    if vehicle ~= nil then self:blockVehicle(vehicle) end

    -- 1) the sleeping trigger of your farmhouse (<farmhouse><sleeping triggerNode=.../>): run its activatable,
    --    exactly like pressing the key at the bed
    if self:useFarmhouseBed() then return end

    local sm = g_sleepManager
    if sm ~= nil then
        if not self.loggedSleepApi then
            self.loggedSleepApi = true
            local names = {}
            local mt = getmetatable(sm)
            local class = mt ~= nil and type(mt.__index) == "table" and mt.__index or sm
            for k, v in pairs(class) do
                if type(v) == "function" and type(k) == "string" then table.insert(names, k) end
            end
            table.sort(names)
            Logging.info("[SleepToWork] g_sleepManager functions: %s", table.concat(names, ", "))
        end
        -- the dialog the bed opens ("sleep until ...")
        for _, name in ipairs({ "showDialog", "showSleepDialog", "openSleepDialog", "onSleepRequest", "requestSleep" }) do
            if sm[name] ~= nil then
                sm[name](sm)
                Logging.info("[SleepToWork] game sleep opened with g_sleepManager:%s()", name)
                return
            end
        end
    end

    -- fallback: fast forward ourselves
    local now = absoluteMinutes()
    if now == nil then return end
    self.sleeping = true
    self.sleepEnd = now + self.SLEEP_HOURS * 60
    self.oldTimeScale = getTimeScale()
    setTimeScale(self.SLEEP_TIMESCALE)
    Logging.info("[SleepToWork] game sleep not found, own fast forward %d h, time scale %s -> %s",
        self.SLEEP_HOURS, tostring(self.oldTimeScale), tostring(getTimeScale()))
end

function SleepToWork:wakeUp()
    self.sleeping = false
    setTimeScale(self.oldTimeScale or 1)
    self.workMinutes = 0
    self.exhausted = false
    self.warned = {}
    self:save()
    bigMessage(g_i18n:getText("stw_title"), string.format(g_i18n:getText("stw_rested"), self.SLEEP_HOURS))
    Logging.info("[SleepToWork] woke up")
end

-- ---------------------------------------------------------------- loop

function SleepToWork:update(dt)
    if g_currentMission == nil then return end
    local now = absoluteMinutes()
    if now == nil then return end

    if not self.loaded then
        self.loaded = true
        self:load()
        self.lastAbs = now
        Logging.info("[SleepToWork] loaded, work time %s of %d h", formatHours(self.workMinutes), self.WORK_LIMIT_HOURS)
        return
    end

    local delta = now - self.lastAbs
    self.lastAbs = now

    if self.sleeping then
        if now >= self.sleepEnd then self:wakeUp() end
        return
    end

    -- the game's own sleep (bed or R): measure how long it lasted
    local sm = g_sleepManager
    if sm ~= nil and sm.getIsSleeping ~= nil then
        if sm:getIsSleeping() then
            if self.gameSleepStart == nil then self.gameSleepStart = now - math.max(delta, 0) end
            return
        elseif self.gameSleepStart ~= nil then
            local slept = now - self.gameSleepStart
            self.gameSleepStart = nil
            self:onSlept(slept)
            return
        end
    end
    if delta <= 0 then return end

    -- a big jump in time = the farmer slept
    if delta >= self.SKIP_MINUTES then
        self:onSlept(delta)
        return
    end

    -- count work: you sit in a vehicle with the motor running
    local vehicle = getControlledVehicle()
    if isPlayerDriving(vehicle) and vehicle.getIsMotorStarted ~= nil and vehicle:getIsMotorStarted() then
        self.workMinutes = self.workMinutes + delta

        for _, h in ipairs(self.WARN_HOURS) do
            if not self.warned[h] and self.workMinutes >= h * 60 then
                self.warned[h] = true
                bigMessage(g_i18n:getText("stw_title"),
                    string.format(g_i18n:getText("stw_warn"), h, self.WORK_LIMIT_HOURS - h))
            end
        end

        if not self.exhausted and self.workMinutes >= self.WORK_LIMIT_HOURS * 60 then
            self.exhausted = true
            bigMessage(g_i18n:getText("stw_title"), g_i18n:getText("stw_exhausted"))
            if vehicle ~= nil then self:blockVehicle(vehicle) end
            self:save()
            Logging.info("[SleepToWork] work limit reached")
        end
    end

    if self.exhausted and isPlayerDriving(vehicle) then
        self:blockVehicle(vehicle)
    end

    -- save every in-game hour
    self.saveTimer = self.saveTimer + delta
    if self.saveTimer >= 60 then
        self.saveTimer = 0
        self:save()
    end
end

function SleepToWork:draw()
    if g_currentMission == nil or renderText == nil then return end

    if self.sleeping then
        if drawFilledRect ~= nil then drawFilledRect(0, 0, 1, 1, 0, 0, 0, 0.85) end
        local env = g_currentMission.environment
        local minutes = env ~= nil and env.dayTime ~= nil and env.dayTime / 60000 or 0
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextBold(true)
        renderText(0.5, 0.52, 0.04, g_i18n:getText("stw_sleeping"))
        setTextBold(false)
        renderText(0.5, 0.46, 0.025, string.format("%02d:%02d", math.floor(minutes / 60) % 24, math.floor(minutes % 60)))
        setTextAlignment(RenderText.ALIGN_LEFT)
        return
    end

    if self.exhausted then
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(1, 0.3, 0.3, 1)
        setTextBold(true)
        renderText(0.5, 0.80, 0.022, g_i18n:getText("stw_pressR"))
        setTextBold(false)
        setTextColor(1, 1, 1, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
    end

    if not self.SHOW_HUD then return end
    if not isPlayerDriving(getControlledVehicle()) then return end
    local limit = self.WORK_LIMIT_HOURS * 60
    local text = string.format(g_i18n:getText("stw_hud"), formatHours(self.workMinutes), self.WORK_LIMIT_HOURS)
    setTextAlignment(RenderText.ALIGN_RIGHT)
    if self.workMinutes >= limit then
        setTextColor(1, 0.25, 0.25, 1)
    elseif self.workMinutes >= (self.WORK_LIMIT_HOURS - 2) * 60 then
        setTextColor(1, 0.8, 0.1, 1)
    else
        setTextColor(1, 1, 1, 0.85)
    end
    renderText(0.985, 0.30, 0.016, text)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

-- ---------------------------------------------------------------- console

function SleepToWork:consoleStatus()
    local self = SleepToWork
    return string.format("work time %s of %d h, exhausted: %s", formatHours(self.workMinutes), self.WORK_LIMIT_HOURS, tostring(self.exhausted))
end
addConsoleCommand("stwStatus", "Show work hours", "consoleStatus", SleepToWork)

function SleepToWork:consoleSet(hours)
    local self = SleepToWork
    local h = tonumber(hours)
    if h == nil then return "usage: stwSet 13.5" end
    self.workMinutes = h * 60
    self.exhausted = self.workMinutes >= self.WORK_LIMIT_HOURS * 60
    self.warned = {}
    self:save()
    return "work time set to " .. formatHours(self.workMinutes)
end
addConsoleCommand("stwSet", "Set work hours (for testing)", "consoleSet", SleepToWork)

function SleepToWork:consoleLimit(hours)
    local self = SleepToWork
    local h = tonumber(hours)
    if h == nil then return "usage: stwLimit 14" end
    self.WORK_LIMIT_HOURS = h
    self.exhausted = self.workMinutes >= h * 60
    return "work limit " .. h .. " h"
end
addConsoleCommand("stwLimit", "Set the work limit in hours", "consoleLimit", SleepToWork)

local function registerSleepKey(register)
    local _, id = register(InputAction.STW_SLEEP, SleepToWork, SleepToWork.onSleepKey)
    if id ~= nil then
        g_inputBinding:setActionEventTextPriority(id, GS_PRIO_HIGH)
        g_inputBinding:setActionEventTextVisibility(id, false)
    end
end

PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
    PlayerInputComponent.registerGlobalPlayerActionEvents, function()
        registerSleepKey(function(action, target, func)
            return g_inputBinding:registerActionEvent(action, target, func, false, true, false, true)
        end)
    end)

if Enterable ~= nil and Enterable.onRegisterActionEvents ~= nil then
    Enterable.onRegisterActionEvents = Utils.appendedFunction(Enterable.onRegisterActionEvents,
        function(vehicle, isActiveForInput, isActiveForInputIgnoreSelection)
            if vehicle.isClient and isActiveForInputIgnoreSelection then
                local spec = vehicle.spec_enterable
                if spec ~= nil and spec.actionEvents ~= nil then
                    registerSleepKey(function(action, target, func)
                        return vehicle:addActionEvent(spec.actionEvents, action, target, func, false, true, false, true, nil)
                    end)
                end
            end
        end)
end

function SleepToWork:deleteMap()
    if SleepToWork.sleeping then setTimeScale(SleepToWork.oldTimeScale or 1) end
    if SleepToWork.loaded then SleepToWork:save() end
end

addModEventListener(SleepToWork)
