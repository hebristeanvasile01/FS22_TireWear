-- Registers the TireWear specialization and adds it to all motorized vehicles with wheels.

TireWearRegister = {}

local modName = g_currentModName
local modDirectory = g_currentModDirectory

g_specializationManager:addSpecialization("tireWear", "TireWear", modDirectory .. "scripts/TireWear.lua", modName)

local function addToVehicleTypes(typeManager)
    if typeManager.typeName ~= "vehicle" then
        return
    end

    local specName = modName .. ".tireWear"

    for typeName, typeEntry in pairs(typeManager:getTypes()) do
        local specs = typeEntry.specializations
        local isLocomotive = Locomotive ~= nil and SpecializationUtil.hasSpecialization(Locomotive, specs)

        if not isLocomotive
            and SpecializationUtil.hasSpecialization(Motorized, specs)
            and SpecializationUtil.hasSpecialization(Wheels, specs) then
            typeManager:addSpecialization(typeName, specName)
        end
    end
end

TypeManager.finalizeTypes = Utils.prependedFunction(TypeManager.finalizeTypes, addToVehicleTypes)

-- Console command: tireWearSet <0-100>  (sets wear of the vehicle you are driving)
function TireWearRegister:consoleSet(value)
    local vehicle = g_currentMission ~= nil and g_currentMission.controlledVehicle or nil

    if vehicle == nil or vehicle.tireWear == nil then
        return "Enter a motorized vehicle first."
    end

    local percent = tonumber(value)
    if percent == nil then
        return "Usage: tireWearSet <0-100>"
    end

    percent = math.max(0, math.min(100, percent))

    vehicle:setTireWear(percent / 100)

    return string.format("Tire wear set to %d%%", percent)
end

addConsoleCommand("tireWearSet", "Sets tire wear (0-100) of the current vehicle", "consoleSet", TireWearRegister)

-- Console command: tireWearRate <km>  (km driven until tires are fully worn, for testing)
function TireWearRegister:consoleRate(value)
    if TireWear == nil then
        return "TireWear is not loaded."
    end

    local km = tonumber(value)
    if km == nil or km <= 0 then
        return string.format("Usage: tireWearRate <km until fully worn> (current: %s)", tostring(TireWear.LIFETIME_KM))
    end

    TireWear.LIFETIME_KM = km

    return string.format("Tires now wear out fully after %s km", tostring(km))
end

addConsoleCommand("tireWearRate", "Sets how many km until tires are fully worn (e.g. 2 = about 5 minutes at 20 km/h)", "consoleRate", TireWearRegister)

------------------------------------------------------------------------------
-- Workshop: extra "Replace tires" button next to Repair (click or key R)
------------------------------------------------------------------------------

local REPLACE_KEY = Input ~= nil and Input.KEY_r or nil
local dumped = false

local function dumpButton(button)
    if dumped then
        return
    end
    dumped = true

    for key, value in pairs(button) do
        local t = type(value)
        if t == "string" or t == "number" or t == "boolean" or t == "function" then
            print(string.format("[TireWear] repairButton.%s (%s) = %s", tostring(key), t, t == "function" and "" or tostring(value)))
        end
    end
end

local function getTireButton(screen)
    if screen.tireWearButton ~= nil then
        return screen.tireWearButton
    end

    local source = screen.repairButton
    if source == nil or source.clone == nil or source.parent == nil then
        return nil
    end

    dumpButton(source)

    local button = source:clone(source.parent)

    -- the clone must not share the key of the repair button
    button.inputActionName = nil
    if button.setInputAction ~= nil then
        pcall(button.setInputAction, button, nil)
    end

    button.onClickCallback = function(target)
        TireWearRegister.onReplaceClicked(screen)
    end
    button.onClickCallbackName = nil
    button.target = screen

    screen.tireWearButton = button

    if source.parent.invalidateLayout ~= nil then
        source.parent:invalidateLayout()
    end

    return button
end

function TireWearRegister.onReplaceClicked(screen)
    local vehicle = screen.vehicle

    if vehicle == nil or vehicle.tireWear == nil then
        return
    end

    if vehicle.tireWear.wear < TireWear.MIN_WEAR_TO_REPLACE then
        g_gui:showInfoDialog({text = g_i18n:getText("tireWear_stillGood", modName)})
        return
    end

    local cost = vehicle:getTireReplaceCost()
    local farm = g_farmManager:getFarmById(vehicle:getOwnerFarmId())

    if farm == nil or farm.money < cost then
        g_gui:showInfoDialog({text = string.format(g_i18n:getText("tireWear_noMoney", modName), g_i18n:formatMoney(cost, 0, true, true))})
        return
    end

    if g_server ~= nil then
        vehicle:replaceTires()
    else
        g_client:getServerConnection():sendEvent(TireWearReplaceEvent.new(vehicle))
    end

    if screen.updateButtons ~= nil then
        screen:updateButtons()
    end
end

local function updateTireButton(screen)
    local ok, err = pcall(function()
        local vehicle = screen.vehicle
        local hasSpec = vehicle ~= nil and vehicle.tireWear ~= nil

        local button = getTireButton(screen)
        if button == nil then
            return
        end

        button:setVisible(hasSpec)

        if hasSpec then
            local worn = vehicle.tireWear.wear >= TireWear.MIN_WEAR_TO_REPLACE
            local text = string.format("%s (%s)  [R]", g_i18n:getText("tireWear_btnTires", modName), g_i18n:formatMoney(vehicle:getTireReplaceCost(), 0, true, true))

            button:setText(text)
            button:setDisabled(not worn)
        end
    end)

    if not ok and not TireWearRegister.loggedError then
        TireWearRegister.loggedError = true
        print("[TireWear] Could not update the workshop button: " .. tostring(err))
    end
end

if WorkshopScreen ~= nil then
    if WorkshopScreen.updateButtons ~= nil then
        WorkshopScreen.updateButtons = Utils.appendedFunction(WorkshopScreen.updateButtons, updateTireButton)
    elseif WorkshopScreen.setVehicle ~= nil then
        WorkshopScreen.setVehicle = Utils.appendedFunction(WorkshopScreen.setVehicle, updateTireButton)
    else
        print("[TireWear] WorkshopScreen has no updateButtons/setVehicle, workshop button not added.")
    end

    -- key R
    if WorkshopScreen.keyEvent ~= nil and REPLACE_KEY ~= nil then
        WorkshopScreen.keyEvent = Utils.appendedFunction(WorkshopScreen.keyEvent, function(screen, unicode, sym, modifier, isDown)
            if isDown and sym == REPLACE_KEY and screen.tireWearButton ~= nil and screen.tireWearButton:getIsVisible() and not screen.tireWearButton:getIsDisabled() then
                TireWearRegister.onReplaceClicked(screen)
            end
        end)
    end
else
    print("[TireWear] WorkshopScreen not found, workshop button not added.")
end
