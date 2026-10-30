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
