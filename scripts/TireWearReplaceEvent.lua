-- Client -> server: request to replace the tires of a vehicle.

TireWearReplaceEvent = {}
local TireWearReplaceEvent_mt = Class(TireWearReplaceEvent, Event)

InitEventClass(TireWearReplaceEvent, "TireWearReplaceEvent")

function TireWearReplaceEvent.emptyNew()
    return Event.new(TireWearReplaceEvent_mt)
end

function TireWearReplaceEvent.new(vehicle)
    local self = TireWearReplaceEvent.emptyNew()
    self.vehicle = vehicle
    return self
end

function TireWearReplaceEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self:run(connection)
end

function TireWearReplaceEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
end

function TireWearReplaceEvent:run(connection)
    if self.vehicle ~= nil and self.vehicle:getIsSynchronized() then
        self.vehicle:replaceTires()
    end
end
