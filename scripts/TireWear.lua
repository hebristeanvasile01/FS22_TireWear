-- TireWear specialization (FS22)
-- Tires wear with distance driven; worn tires lose grip. Replace them for money.

TireWear = {}

TireWear.MOD_NAME = g_currentModName
TireWear.MOD_DIR = g_currentModDirectory

------------------------------------------------------------------------------
-- SETTINGS - edit these to taste
------------------------------------------------------------------------------
TireWear.LIFETIME_KM         = 300    -- km driven until tires hit 100% wear (same rate as FS25 Use Up Your Tyres at 1x)
TireWear.MAX_FRICTION_LOSS   = 0.50   -- grip lost at 100% wear (0.50 = -50%). Loss grows with wear^3, so it is barely noticeable until ~60% wear
TireWear.REPLACE_COST        = 0.03   -- price of new tires = this fraction of the vehicle's price
TireWear.MIN_WEAR_TO_REPLACE = 0.10   -- tires can only be replaced above this wear (0.10 = 10%)
TireWear.WARN_LEVELS         = {0.80, 0.95}
TireWear.VISUAL_ENABLED      = true   -- visual tread wear (custom shader). Set to false if it causes problems
TireWear.TREAD_DEPTH_RATIO   = 0.06   -- tread depth that can wear away, as a fraction of the tire radius
TireWear.MIN_VISUAL_WEAR     = 0.60   -- visual tread wear starts at this wear (0.60 = 60%); below it the original tire material is used
TireWear.RADIUS_MARGIN       = 0.15   -- safety margin (fraction of tread depth) so new tires are never cut
------------------------------------------------------------------------------

function TireWear.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Motorized, specializations)
        and SpecializationUtil.hasSpecialization(Wheels, specializations)
end

function TireWear.initSpecialization()
    local schemaSavegame = Vehicle.xmlSchemaSavegame
    schemaSavegame:register(XMLValueType.FLOAT, "vehicles.vehicle(?)." .. TireWear.MOD_NAME .. ".tireWear#wear", "Tire wear (0-1)")
end

function TireWear.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "setTireWear", TireWear.setTireWear)
    SpecializationUtil.registerFunction(vehicleType, "applyTireWear", TireWear.applyTireWear)
    SpecializationUtil.registerFunction(vehicleType, "replaceTires", TireWear.replaceTires)
    SpecializationUtil.registerFunction(vehicleType, "getTireReplaceCost", TireWear.getTireReplaceCost)
end

function TireWear.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "showInfo", TireWear.showInfo)
end

function TireWear.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", TireWear)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", TireWear)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", TireWear)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", TireWear)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", TireWear)
    SpecializationUtil.registerEventListener(vehicleType, "onReadUpdateStream", TireWear)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteUpdateStream", TireWear)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", TireWear)

    -- the wheel meshes are linked after onPostLoad, so also try again on onLoadFinished when it exists
    if vehicleType.eventListeners ~= nil and vehicleType.eventListeners["onLoadFinished"] ~= nil then
        SpecializationUtil.registerEventListener(vehicleType, "onLoadFinished", TireWear)
    end
end

------------------------------------------------------------------------------
-- Load / save
------------------------------------------------------------------------------

function TireWear:onLoad(savegame)
    self.tireWear = {
        wear = 0,
        permille = 0,
        shownPermille = -1,
        warnLevel = 0,
        dirtyFlag = self:getNextDirtyFlag(),
        actionEvents = {},
        replaceEventId = nil
    }
end

function TireWear:onPostLoad(savegame)
    local spec = self.tireWear

    if savegame ~= nil then
        local key = savegame.key .. "." .. TireWear.MOD_NAME .. ".tireWear"
        spec.wear = MathUtil.clamp(savegame.xmlFile:getValue(key .. "#wear", 0), 0, 1)
    end

    spec.permille = math.floor(spec.wear * 1000 + 0.5)
    self:applyTireWear()

    TireWear.initVisuals(self)
end

function TireWear:onLoadFinished(savegame)
    TireWear.initVisuals(self)
end

function TireWear:saveToXMLFile(xmlFile, key, usedModNames)
    xmlFile:setValue(key .. "#wear", self.tireWear.wear)
end

------------------------------------------------------------------------------
-- Multiplayer sync
------------------------------------------------------------------------------

function TireWear:onWriteStream(streamId, connection)
    streamWriteUIntN(streamId, self.tireWear.permille, 10)
end

function TireWear:onReadStream(streamId, connection)
    local spec = self.tireWear
    spec.permille = streamReadUIntN(streamId, 10)
    spec.wear = spec.permille / 1000

    TireWear.updateVisuals(self)
end

function TireWear:onWriteUpdateStream(streamId, connection, dirtyMask)
    if not connection:getIsServer() then
        local spec = self.tireWear
        if streamWriteBool(streamId, bitAND(dirtyMask, spec.dirtyFlag) ~= 0) then
            streamWriteUIntN(streamId, spec.permille, 10)
        end
    end
end

function TireWear:onReadUpdateStream(streamId, timestamp, connection)
    if connection:getIsServer() then
        if streamReadBool(streamId) then
            local spec = self.tireWear
            spec.permille = streamReadUIntN(streamId, 10)
            spec.wear = spec.permille / 1000

            TireWear.updateVisuals(self)
        end
    end
end

------------------------------------------------------------------------------
-- Wear logic
------------------------------------------------------------------------------

function TireWear:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = self.tireWear

    if self.isServer then
        local speed = math.abs(self:getLastSpeed()) -- km/h

        if speed > 0.5 and spec.wear < 1 then
            local distKm = speed * dt / 3600000

            spec.wear = math.min(spec.wear + distKm / TireWear.LIFETIME_KM, 1)

            local permille = math.floor(spec.wear * 1000 + 0.5)
            if permille ~= spec.permille then
                spec.permille = permille
                self:applyTireWear()
                self:raiseDirtyFlags(spec.dirtyFlag)
            end
        end
    end

    -- tires are not linked to the wheels right after loading: retry a few times, once per second
    if self.isClient and TireWear.VISUAL_ENABLED and (spec.visualAttempts or 0) < 4
        and (spec.tires == nil or #spec.tires == 0) and g_time >= (spec.nextVisualAttempt or 0) then
        spec.nextVisualAttempt = g_time + 1000
        TireWear.initVisuals(self)
        self:raiseActive()
    end

    if self.isClient and spec.permille ~= spec.shownPermille then
        spec.shownPermille = spec.permille

        TireWear.updateVisuals(self)

        if spec.replaceEventId ~= nil then
            g_inputBinding:setActionEventText(spec.replaceEventId, string.format(g_i18n:getText("tireWear_replaceFmt"), spec.permille / 10))
        end

        local wear = spec.permille / 1000
        local level = 0
        for i, threshold in ipairs(TireWear.WARN_LEVELS) do
            if wear >= threshold then
                level = i
            end
        end

        if level > spec.warnLevel and isActiveForInputIgnoreSelection and g_currentMission ~= nil then
            g_currentMission:showBlinkingWarning(g_i18n:getText("tireWear_warn" .. level), 4000)
        end
        spec.warnLevel = level
    end
end

-- Applies the current wear to the wheel friction (physics runs on the server).
function TireWear:applyTireWear()
    local spec = self.tireWear

    if not self.isServer or self.getWheels == nil then
        return
    end

    local wheels = self:getWheels()
    if wheels == nil then
        return
    end

    local factor = 1 - TireWear.MAX_FRICTION_LOSS * spec.wear ^ 3

    for _, wheel in ipairs(wheels) do
        -- FS22 keeps wheel values directly on the wheel table (FS25 moved them to wheel.physics)
        local physics = wheel.physics or wheel

        if physics.frictionScale ~= nil then
            if wheel.tireWearBaseFriction == nil then
                wheel.tireWearBaseFriction = physics.frictionScale
            end

            physics.frictionScale = wheel.tireWearBaseFriction * factor

            if self.updateWheelTireFriction ~= nil then
                self:updateWheelTireFriction(wheel)
            else
                physics.isFrictionDirty = true
            end
        end
    end
end

function TireWear:setTireWear(value)
    if not self.isServer then
        return
    end

    local spec = self.tireWear
    spec.wear = MathUtil.clamp(value, 0, 1)
    spec.permille = math.floor(spec.wear * 1000 + 0.5)

    self:applyTireWear()
    self:raiseDirtyFlags(spec.dirtyFlag)
end

------------------------------------------------------------------------------
-- Replacing tires
------------------------------------------------------------------------------

function TireWear:getTireReplaceCost()
    local price = 0
    if self.getPrice ~= nil then
        price = self:getPrice()
    else
        price = self.price or 0
    end

    return math.floor(math.max(price, 10000) * TireWear.REPLACE_COST)
end

-- Server only: charges the farm and resets wear.
function TireWear:replaceTires()
    if not self.isServer then
        return
    end

    local spec = self.tireWear
    if spec.wear < TireWear.MIN_WEAR_TO_REPLACE then
        return
    end

    local cost = self:getTireReplaceCost()
    local farmId = self:getOwnerFarmId()
    local farm = g_farmManager:getFarmById(farmId)

    if farm == nil or farm.money < cost then
        return
    end

    g_currentMission:addMoney(-cost, farmId, MoneyType.VEHICLE_REPAIR, true, true)
    self:setTireWear(0)
end

function TireWear:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    if self.isClient then
        local spec = self.tireWear

        self:clearActionEventsTable(spec.actionEvents)
        spec.replaceEventId = nil

        if isActiveForInputIgnoreSelection then
            local _, eventId = self:addActionEvent(spec.actionEvents, InputAction.TIREWEAR_REPLACE, self, TireWear.actionEventReplace, false, true, false, true, nil)

            spec.replaceEventId = eventId
            g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_NORMAL)
            g_inputBinding:setActionEventText(eventId, string.format(g_i18n:getText("tireWear_replaceFmt"), spec.permille / 10))
        end
    end
end

function TireWear.actionEventReplace(self, actionName, inputValue, callbackState, isAnalog)
    local spec = self.tireWear

    if spec.wear < TireWear.MIN_WEAR_TO_REPLACE then
        g_currentMission:showBlinkingWarning(g_i18n:getText("tireWear_stillGood"), 2500)
        return
    end

    if math.abs(self:getLastSpeed()) > 1 then
        g_currentMission:showBlinkingWarning(g_i18n:getText("tireWear_stopFirst"), 2500)
        return
    end

    local cost = self:getTireReplaceCost()
    local farm = g_farmManager:getFarmById(self:getOwnerFarmId())

    if farm == nil or farm.money < cost then
        local text = string.format(g_i18n:getText("tireWear_noMoney"), g_i18n:formatMoney(cost, 0, true, true))
        g_currentMission:showBlinkingWarning(text, 3000)
        return
    end

    if g_server ~= nil then
        self:replaceTires()
    else
        g_client:getServerConnection():sendEvent(TireWearReplaceEvent.new(self))
    end
end

------------------------------------------------------------------------------
-- Visual wear (custom shader). Client only and fully optional:
-- if anything fails, the visual part is switched off and the rest keeps working.
------------------------------------------------------------------------------

TireWear.holderMaterialId = nil
TireWear.holderFailed = false

-- shader parameters that have to survive the material swap
TireWear.SAVED_PARAMETERS = {
    "RDT", "dirtColor", "morphPosition", "prevMorphPosition",
    "colorMat0", "colorMat1", "colorMat2", "colorMat3", "colorMat4", "colorMat5", "colorMat6", "colorMat7"
}

function TireWear.getHolderMaterial()
    if TireWear.holderMaterialId ~= nil then
        return TireWear.holderMaterialId
    end

    if TireWear.holderFailed then
        return nil
    end

    TireWear.holderFailed = true

    local nodeId = g_i3DManager:loadSharedI3DFile(TireWear.MOD_DIR .. "material/tireMaterialHolder.i3d", false, false)
    if nodeId ~= nil and nodeId > 0 then
        local materialNode = I3DUtil.indexToObject(nodeId, "0|0")
        if materialNode ~= nil then
            TireWear.holderMaterialId = getMaterial(materialNode, 0)
            TireWear.holderFailed = false
        end
    end

    if TireWear.holderMaterialId == nil then
        print("[TireWear] Could not load material/tireMaterialHolder.i3d - visual wear is disabled.")
    end

    return TireWear.holderMaterialId
end

-- Finds all deformable tire meshes (the ones with the morphPosition shader parameter) under a node.
function TireWear.collectTireNodes(node, result, depth)
    if node == nil or node == 0 or depth > 16 then
        return
    end

    -- shader parameters can only be queried on shapes (transform groups give a warning)
    if getHasClassId(node, ClassIds.SHAPE) and getHasShaderParameter(node, "morphPosition") then
        table.insert(result, node)
    end

    for i = 0, getNumOfChildren(node) - 1 do
        TireWear.collectTireNodes(getChildAt(node, i), result, depth + 1)
    end
end

-- Swaps the tire material for our shader material and returns the data needed to wear it.
-- reads the texture file names of a material
function TireWear.getTexturePaths(material)
    local paths = {}

    -- generated single-color textures ("gen_...") are no real files and cannot be loaded again
    local function realFile(path)
        if path == nil or path == "" or string.sub(path, 1, 4) == "gen_" or string.find(path, "gen_singleColorTexture", 1, true) then
            return nil
        end
        return path
    end

    if getMaterialDiffuseMapFilename ~= nil then
        paths.diffuse = realFile(getMaterialDiffuseMapFilename(material))
    end
    if getMaterialNormalMapFilename ~= nil then
        paths.normal = realFile(getMaterialNormalMapFilename(material))
    end
    if getMaterialGlossMapFilename ~= nil then
        paths.gloss = realFile(getMaterialGlossMapFilename(material))
    end

    return paths
end

-- creates the worn-tire material with the textures of the original tire
function TireWear.buildWornMaterial(holderMaterial, paths)
    local material = holderMaterial

    if paths.diffuse ~= nil and paths.diffuse ~= "" and setMaterialDiffuseMapFromFile ~= nil then
        material = setMaterialDiffuseMapFromFile(material, paths.diffuse, false, true, false)
    end
    if paths.normal ~= nil and paths.normal ~= "" and setMaterialNormalMapFromFile ~= nil then
        material = setMaterialNormalMapFromFile(material, paths.normal, false, false, false)
    end
    if paths.gloss ~= nil and paths.gloss ~= "" and setMaterialGlossMapFromFile ~= nil then
        material = setMaterialGlossMapFromFile(material, paths.gloss, false, false, false)
    end

    return material
end

-- Switches a tire between its original material (new tire) and the worn-tire shader material.
function TireWear.setTireMaterial(tire, worn)
    if tire.isWorn == worn then
        return
    end

    -- read the current parameters (dirt, pressure, colors) before the swap resets them
    local saved = {}
    for _, name in ipairs(TireWear.SAVED_PARAMETERS) do
        if getHasShaderParameter(tire.node, name) then
            saved[name] = {getShaderParameter(tire.node, name)}
        end
    end

    local material = tire.originalMaterial
    if worn then
        material = TireWear.buildWornMaterial(TireWear.getHolderMaterial(), tire.texturePaths)
    end

    setMaterial(tire.node, material, 0)

    for name, values in pairs(saved) do
        setShaderParameter(tire.node, name, values[1], values[2], values[3], values[4], false)
    end

    tire.isWorn = worn
end

function TireWear.convertTire(node, wheel, holderMaterial)
    local previousMaterial = getMaterial(node, 0)
    if previousMaterial == nil then
        return nil
    end

    if getMaterialCustomShaderVariation ~= nil and getMaterialCustomShaderVariation(previousMaterial) ~= "tirePressureDeformation" then
        return nil
    end

    -- remember the parameters of the node, the swap resets them
    local saved = {}
    for _, name in ipairs(TireWear.SAVED_PARAMETERS) do
        if getHasShaderParameter(node, name) then
            saved[name] = {getShaderParameter(node, name)}
        end
    end

    -- a hidden copy of the node keeps the original material alive, so it can be restored later
    local keeper = clone(node, true, false, false)
    link(getParent(node), keeper)
    setVisibility(keeper, false)

    local texturePaths = TireWear.getTexturePaths(previousMaterial)
    local newMaterial = TireWear.buildWornMaterial(holderMaterial, texturePaths)

    setMaterial(node, newMaterial, 0)

    for name, values in pairs(saved) do
        setShaderParameter(node, name, values[1], values[2], values[3], values[4], false)
    end

    -- tires that had no pressure deformation: make sure the new shader does not push the tire up
    if saved.morphPosition == nil then
        setShaderParameter(node, "morphPosition", -0.45, -0.915, 0.5, 0, false)
        setShaderParameter(node, "prevMorphPosition", -0.45, -0.915, 0.5, 0, false)
    end

    -- measure the tire: the shader works in the local space of the mesh, so use its local bounding box
    local physics = wheel.physics or wheel
    local physicsRadius = physics.radius or 0.5
    local width = physics.width or 0.5
    local radius = physicsRadius
    local boxRadius, boxWidth

    if getShapeBoundingBox ~= nil then
        local ok, minX, minY, minZ, maxX, maxY, maxZ = pcall(getShapeBoundingBox, node)
        if ok and maxZ ~= nil then
            boxRadius = math.max(maxY - minY, maxZ - minZ) * 0.5
            boxWidth = maxX - minX
        end
    end

    if boxRadius ~= nil and boxRadius > 0.1 and boxRadius < 3 then
        radius = boxRadius
        if boxWidth ~= nil and boxWidth > 0.05 then
            width = boxWidth
        end
    elseif getShapeWorldBoundingSphere ~= nil then
        local flatTire = clone(node, false, false, false)
        setScale(flatTire, 0, 1, 1)
        link(getRootNode(), flatTire)
        local _, _, _, sphereRadius = getShapeWorldBoundingSphere(flatTire)
        unlink(flatTire)
        delete(flatTire)

        if sphereRadius ~= nil and sphereRadius > 0.1 then
            radius = (sphereRadius + physicsRadius) * 0.5
        end
    end

    TireWear.radiusLogCount = (TireWear.radiusLogCount or 0) + 1
    if TireWear.radiusLogCount <= 6 then
        print(string.format("[TireWear] tire radius: box=%s physics=%.3f width=%.3f used=%.3f", tostring(boxRadius), physicsRadius, width, radius))
    end

    return {
        node = node,
        radius = radius,
        width = width,
        usage = radius * TireWear.TREAD_DEPTH_RATIO,
        originalMaterial = previousMaterial,
        texturePaths = texturePaths,
        keeper = keeper,
        isWorn = true
    }
end

function TireWear.convertTires(vehicle, isFinalAttempt)
    local spec = vehicle.tireWear
    spec.tires = {}

    local holderMaterial = TireWear.getHolderMaterial()
    if holderMaterial == nil then
        return
    end

    local visited = {}

    for _, wheel in ipairs(vehicle:getWheels()) do
        local found = {}

        for _, root in ipairs({wheel.repr, wheel.driveNode, wheel.node, wheel.linkNode, wheel.wheelTire}) do
            if type(root) == "number" then
                TireWear.collectTireNodes(root, found, 0)
            end
        end

        for _, node in ipairs(found) do
            if not visited[node] then
                visited[node] = true

                local tire = TireWear.convertTire(node, wheel, holderMaterial)
                if tire ~= nil then
                    table.insert(spec.tires, tire)
                end
            end
        end
    end

    if #spec.tires > 0 or isFinalAttempt then
        TireWear.logCount = (TireWear.logCount or 0) + 1
        if TireWear.logCount <= 5 then
            print(string.format("[TireWear] %s: %d tire mesh(es) use the worn-tire shader.", vehicle:getName(), #spec.tires))
        end
    end

    -- nothing found after the last attempt: print the node structure of one vehicle once, so the detection can be fixed
    if #spec.tires == 0 and isFinalAttempt and not TireWear.dumped then
        TireWear.dumped = true

        local ok, err = pcall(TireWear.dumpWheel, vehicle)
        if not ok then
            print("[TireWear][debug] dump failed: " .. tostring(err))
        end
    end

    TireWear.updateVisuals(vehicle)
end

------------------------------------------------------------------------------
-- Debug output (only used when no tire mesh was found)
------------------------------------------------------------------------------

function TireWear.describeNode(node)
    local text = tostring(getName(node))

    if getHasClassId(node, ClassIds.SHAPE) then
        local variation = "n/a"
        if getMaterialCustomShaderVariation ~= nil then
            local material = getMaterial(node, 0)
            if material ~= nil then
                variation = tostring(getMaterialCustomShaderVariation(material))
            end
        end

        text = string.format("%s [SHAPE variation=%s morphPosition=%s RDT=%s colorMat0=%s]", text, variation,
            tostring(getHasShaderParameter(node, "morphPosition")),
            tostring(getHasShaderParameter(node, "RDT")),
            tostring(getHasShaderParameter(node, "colorMat0")))
    end

    return text
end

function TireWear.nodePath(node)
    local path = tostring(getName(node))
    local parent = getParent(node)

    for _ = 1, 5 do
        if parent == nil or parent == 0 then
            break
        end

        path = tostring(getName(parent)) .. " > " .. path
        parent = getParent(parent)
    end

    return path
end

function TireWear.collectShapesByName(node, result, depth)
    if node == nil or node == 0 or depth > 20 or #result >= 60 then
        return
    end

    if getHasClassId(node, ClassIds.SHAPE) then
        local name = string.lower(tostring(getName(node)))

        if string.find(name, "tire", 1, true) or string.find(name, "tyre", 1, true)
            or string.find(name, "wheel", 1, true) or string.find(name, "rim", 1, true) then
            table.insert(result, node)
        end
    end

    for i = 0, getNumOfChildren(node) - 1 do
        TireWear.collectShapesByName(getChildAt(node, i), result, depth + 1)
    end
end

function TireWear.dumpTree(node, depth, maxDepth, lines)
    if node == nil or node == 0 or #lines >= 150 then
        return
    end

    table.insert(lines, string.rep("  ", depth) .. TireWear.describeNode(node))

    if depth < maxDepth then
        for i = 0, getNumOfChildren(node) - 1 do
            TireWear.dumpTree(getChildAt(node, i), depth + 1, maxDepth, lines)
        end
    end
end

function TireWear.dumpWheel(vehicle)
    local wheel = vehicle:getWheels()[1]
    if wheel == nil then
        return
    end

    print("[TireWear][debug] " .. tostring(vehicle:getName()) .. " - first wheel, fields that are nodes:")
    for key, value in pairs(wheel) do
        if type(value) == "number" and value > 0 and entityExists(value) then
            print(string.format("[TireWear][debug]   %s = %s", tostring(key), TireWear.describeNode(value)))
        end
    end

    for _, key in ipairs({"repr", "driveNode"}) do
        local root = wheel[key]
        if type(root) == "number" and root > 0 then
            local lines = {}
            TireWear.dumpTree(root, 0, 6, lines)

            print("[TireWear][debug] tree below wheel." .. key .. ":")
            for _, line in ipairs(lines) do
                print("[TireWear][debug] " .. line)
            end
        end
    end

    -- shapes with morphPosition anywhere in the vehicle
    local found = {}
    for _, component in ipairs(vehicle.components or {}) do
        TireWear.collectTireNodes(component.node, found, 0)
    end

    -- shapes whose name looks like a tire, wheel or rim anywhere in the vehicle
    local byName = {}
    for _, component in ipairs(vehicle.components or {}) do
        TireWear.collectShapesByName(component.node, byName, 0)
    end

    print(string.format("[TireWear][debug] shapes named like tire/wheel/rim in the whole vehicle: %d", #byName))
    for i = 1, math.min(#byName, 25) do
        print("[TireWear][debug]   " .. TireWear.nodePath(byName[i]) .. "  =>  " .. TireWear.describeNode(byName[i]))
    end

    print(string.format("[TireWear][debug] shapes with morphPosition in the whole vehicle: %d", #found))
    for i = 1, math.min(#found, 10) do
        local path = tostring(getName(found[i]))
        local parent = getParent(found[i])
        for _ = 1, 5 do
            if parent == nil or parent == 0 then
                break
            end
            path = tostring(getName(parent)) .. " > " .. path
            parent = getParent(parent)
        end
        print("[TireWear][debug]   " .. path)
    end
end

function TireWear.initVisuals(vehicle)
    local spec = vehicle.tireWear

    if not TireWear.VISUAL_ENABLED or not vehicle.isClient or vehicle.getWheels == nil then
        return
    end

    if spec.tires ~= nil and #spec.tires > 0 then
        return
    end

    spec.visualAttempts = (spec.visualAttempts or 0) + 1

    local ok, err = pcall(TireWear.convertTires, vehicle, spec.visualAttempts >= 4)
    if not ok then
        print("[TireWear] Visual wear init failed: " .. tostring(err))
        vehicle.tireWear.tires = nil
        TireWear.VISUAL_ENABLED = false
    end
end

-- Pushes the current wear into the shader of every converted tire.
function TireWear.updateVisuals(vehicle)
    local spec = vehicle.tireWear
    if spec == nil or spec.tires == nil then
        return
    end

    for _, tire in ipairs(spec.tires) do
        -- a safety margin keeps new tires untouched even if the measured radius is slightly too small
        -- new tires use the original material, so they look exactly like the base game
        local worn = spec.wear >= TireWear.MIN_VISUAL_WEAR
        TireWear.setTireMaterial(tire, worn)

        if worn then
            local margin = tire.usage * TireWear.RADIUS_MARGIN
            -- visual wear grows from 0 at MIN_VISUAL_WEAR to full at 100% wear
            local visualWear = (spec.wear - TireWear.MIN_VISUAL_WEAR) / (1 - TireWear.MIN_VISUAL_WEAR)
            local currentRadius = tire.radius + margin - visualWear * (tire.usage + margin)
            setShaderParameter(tire.node, "usedTire", tire.radius, tire.width, currentRadius, tire.usage, false)
        end
    end
end

------------------------------------------------------------------------------
-- Info box
------------------------------------------------------------------------------

function TireWear:showInfo(superFunc, box)
    superFunc(self, box)

    local spec = self.tireWear
    if spec ~= nil then
        box:addLine(g_i18n:getText("tireWear_info"), string.format("%.1f %%", spec.permille / 10))
    end
end
