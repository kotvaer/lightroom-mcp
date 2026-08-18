local StylePilotPanel = require 'StylePilotPanel'

local Handler = {}

function Handler.requestApproval(args)
    return StylePilotPanel.requestApproval(args)
end

function Handler.requestCalibrationApproval(args)
    return StylePilotPanel.requestCalibrationApproval(args)
end

function Handler.getApproval(args)
    return StylePilotPanel.getApproval(args)
end

function Handler.cancelApproval(args)
    return StylePilotPanel.cancelApproval(args)
end

return Handler
