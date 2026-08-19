local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Log = require 'Log'

local Panel = {}

local MAX_SETTINGS = 20
local MAX_RISKS = 10
local MAX_CALIBRATION_PHOTOS = 20
local MAX_CALIBRATION_POINTS = 60
local STYLEPILOT_PARAMETER_RANGES = {
    Exposure2012 = { -5, 5 },
    Contrast2012 = { -100, 100 },
    Highlights2012 = { -100, 100 },
    Shadows2012 = { -100, 100 },
    Whites2012 = { -100, 100 },
    Blacks2012 = { -100, 100 },
    Texture = { -100, 100 },
    Clarity2012 = { -100, 100 },
    Dehaze = { -100, 100 },
    Vibrance = { -100, 100 },
    Saturation = { -100, 100 },
}
local currentRequest
local propertyTable
local dialogControls
local panelOpen = false
local panelStarting = false

local function requireString(value, name, maxLength)
    if type(value) ~= "string" or value == "" then
        error(name .. " is required")
    end
    if maxLength and #value > maxLength then
        error(name .. " must contain at most " .. tostring(maxLength) .. " characters")
    end
end

local function requireNumber(value, name, minimum, maximum)
    if type(value) ~= "number" or value ~= value
        or value == math.huge or value == -math.huge then
        error(name .. " must be a finite number")
    end
    if value < minimum or value > maximum then
        error(name .. " must be between " .. tostring(minimum) .. " and " .. tostring(maximum))
    end
end

local function requireInteger(value, name, minimum, maximum)
    requireNumber(value, name, minimum, maximum)
    if value % 1 ~= 0 then error(name .. " must be an integer") end
end

local function copySettings(settings)
    if type(settings) ~= "table" then error("settings is required") end
    local copied = {}
    local count = 0
    for key, value in pairs(settings) do
        requireString(key, "settings key", 100)
        requireNumber(value, "settings." .. key, -1000, 1000)
        copied[key] = value
        count = count + 1
    end
    if count == 0 then error("settings is required") end
    if count > MAX_SETTINGS then error("settings must contain at most 20 entries") end
    return copied
end

local function copyRisks(risks)
    if type(risks) ~= "table" then error("risks is required") end
    local copied = {}
    for index, risk in ipairs(risks) do
        if index > MAX_RISKS then error("risks must contain at most 10 entries") end
        requireString(risk, "risks[" .. tostring(index) .. "]", 500)
        table.insert(copied, risk)
    end
    if #copied == 0 then table.insert(copied, "No major technical risk detected.") end
    return copied
end

local function copyStrings(values, name, maximum, maxLength)
    if type(values) ~= "table" then error(name .. " is required") end
    local copied = {}
    for index, value in ipairs(values) do
        if index > maximum then
            error(name .. " must contain at most " .. tostring(maximum) .. " entries")
        end
        requireString(value, name .. "[" .. tostring(index) .. "]", maxLength)
        table.insert(copied, value)
    end
    if #copied == 0 then error(name .. " is required") end
    return copied
end

local function copyCalibrationParameters(parameters)
    if type(parameters) ~= "table" then error("parameters is required") end
    local copied = {}
    local seenParameters = {}
    local totalPoints = 0
    for index, item in ipairs(parameters) do
        if index > MAX_SETTINGS then error("parameters must contain at most 20 entries") end
        if type(item) ~= "table" then
            error("parameters[" .. tostring(index) .. "] must be an object")
        end
        requireString(item.parameter, "parameters.parameter", 100)
        local range = STYLEPILOT_PARAMETER_RANGES[item.parameter]
        if not range then error("Unsupported StylePilot parameter: " .. item.parameter) end
        if seenParameters[item.parameter] then
            error("Calibration parameters must be unique")
        end
        seenParameters[item.parameter] = true
        if type(item.values) ~= "table" then error("parameters.values is required") end
        local values = {}
        local seenValues = {}
        for valueIndex, value in ipairs(item.values) do
            if valueIndex > 21 then error("parameter values must contain at most 21 entries") end
            requireNumber(value, item.parameter, range[1], range[2])
            if seenValues[value] then error(item.parameter .. " values must be unique") end
            seenValues[value] = true
            table.insert(values, value)
            totalPoints = totalPoints + 1
        end
        if #values == 0 then error("parameter values are required") end
        table.insert(copied, { parameter = item.parameter, values = values })
    end
    if #copied == 0 then error("parameters is required") end
    if totalPoints > MAX_CALIBRATION_POINTS then
        error("Calibration must contain at most 60 sample points per photo")
    end
    return copied, totalPoints
end

local function formatSettings(settings)
    local keys = {}
    for key in pairs(settings) do table.insert(keys, key) end
    table.sort(keys)

    local lines = {}
    for _, key in ipairs(keys) do
        table.insert(lines, string.format("%s: %.2f", key, settings[key]))
    end
    return table.concat(lines, "\n")
end

local function formatCalibrationSettings(parameters)
    local lines = {}
    for _, item in ipairs(parameters) do
        local values = {}
        for _, value in ipairs(item.values) do
            table.insert(values, string.format("%.2f", value))
        end
        table.insert(lines, item.parameter .. ": " .. table.concat(values, ", "))
    end
    return table.concat(lines, "\n")
end

local function formatRisks(risks)
    local lines = {}
    for _, risk in ipairs(risks) do table.insert(lines, "- " .. risk) end
    return table.concat(lines, "\n")
end

local function refreshProperties()
    if not propertyTable then return end
    local request = currentRequest
    if not request then
        propertyTable.photo = "Waiting for a StylePilot plan"
        propertyTable.style = "No active request"
        propertyTable.suitability = "-"
        propertyTable.settings = "-"
        propertyTable.risks = "-"
        propertyTable.status = "Idle"
        propertyTable.approvalPending = false
        return
    end

    propertyTable.photo = request.photo_label
        or (request.filename .. "  [" .. request.photo_id .. "]")
    propertyTable.style = request.style_name
    propertyTable.suitability = request.scope_text or string.format(
            "%.1f / 100   |   recommended strength %.0f%%",
            request.suitability_score,
            request.recommended_strength * 100
        )
    propertyTable.settings = request.settings_text or formatSettings(request.settings)
    propertyTable.risks = formatRisks(request.risks)
    propertyTable.status = request.status
    propertyTable.approvalPending = request.status == "pending"
end

local function markDecision(status, reason)
    if not currentRequest or currentRequest.status ~= "pending" then return end
    currentRequest.status = status
    currentRequest.reason = reason
    refreshProperties()
    Log.info(string.format("StylePilot approval %s for request %s",
        status, currentRequest.request_id))
    if dialogControls and dialogControls.close then dialogControls.close() end
end

local function buildContents(factory)
    return factory:column {
        bind_to_object = propertyTable,
        spacing = factory:control_spacing(),
        margin = factory:dialog_spacing(),
        fill_horizontal = 1,
        factory:static_text {
            title = "Review the proposed Lightroom operation",
            width_in_chars = 52,
        },
        factory:separator { fill_horizontal = 1 },
        factory:row {
            spacing = factory:label_spacing(),
            factory:static_text { title = "Photo:", width = 105 },
            factory:static_text {
                title = LrView.bind('photo'),
                width_in_chars = 38,
            },
        },
        factory:row {
            spacing = factory:label_spacing(),
            factory:static_text { title = "Operation:", width = 105 },
            factory:static_text { title = LrView.bind('style') },
        },
        factory:row {
            spacing = factory:label_spacing(),
            factory:static_text { title = "Scope:", width = 105 },
            factory:static_text { title = LrView.bind('suitability') },
        },
        factory:separator { fill_horizontal = 1 },
        factory:static_text { title = "Develop settings / calibration values" },
        factory:static_text {
            title = LrView.bind('settings'),
            width_in_chars = 52,
            height_in_lines = 6,
        },
        factory:static_text { title = "Risk and compatibility notes" },
        factory:static_text {
            title = LrView.bind('risks'),
            width_in_chars = 52,
            height_in_lines = 4,
        },
        factory:row {
            spacing = factory:control_spacing(),
            factory:push_button {
                title = "Reject",
                enabled = LrView.bind('approvalPending'),
                action = function() markDecision("rejected", "user_rejected") end,
            },
            factory:push_button {
                title = "Approve virtual-copy operation",
                enabled = LrView.bind('approvalPending'),
                action = function() markDecision("approved", "user_approved") end,
            },
            factory:static_text { title = LrView.bind('status') },
        },
    }
end

local function startPanel()
    if panelOpen or panelStarting then
        if dialogControls and dialogControls.toFront then dialogControls.toFront() end
        refreshProperties()
        return
    end

    panelStarting = true
    LrTasks.startAsyncTask(function()
        local ok, err = LrTasks.pcall(function()
            LrFunctionContext.callWithContext("StylePilot approval panel", function(context)
                propertyTable = LrBinding.makePropertyTable(context)
                refreshProperties()
                local factory = LrView.osFactory()
                panelOpen = true
                panelStarting = false
                LrDialogs.presentFloatingDialog(_PLUGIN, {
                    title = "StylePilot — Review Operation",
                    contents = buildContents(factory),
                    blockTask = true,
                    save_frame = "stylepilotApprovalPanel",
                    onShow = function(controls)
                        dialogControls = controls
                        if controls.toFront then controls.toFront() end
                    end,
                    windowWillClose = function()
                        if currentRequest and currentRequest.status == "pending" then
                            local requestId = currentRequest.request_id
                            currentRequest.status = "rejected"
                            currentRequest.reason = "window_closed"
                            Log.info("StylePilot approval rejected by window close for request "
                                .. requestId)
                        end
                        panelOpen = false
                        dialogControls = nil
                    end,
                })
            end)
        end)
        panelOpen = false
        panelStarting = false
        propertyTable = nil
        dialogControls = nil
        if not ok then Log.error("StylePilot panel failed: " .. tostring(err)) end
    end)
end

function Panel.requestApproval(args)
    requireString(args.request_id, "request_id", 100)
    requireString(args.photo_id, "photo_id", 255)
    requireString(args.filename, "filename", 500)
    requireString(args.style_name, "style_name", 255)
    requireNumber(args.suitability_score, "suitability_score", 0, 100)
    requireNumber(args.recommended_strength, "recommended_strength", 0, 1)

    if currentRequest and currentRequest.status == "pending"
        and currentRequest.request_id ~= args.request_id then
        error("Another StylePilot approval request is already pending")
    end
    if currentRequest and currentRequest.request_id == args.request_id then
        startPanel()
        return {
            success = true,
            request_id = currentRequest.request_id,
            status = currentRequest.status,
        }
    end

    currentRequest = {
        request_id = args.request_id,
        photo_id = args.photo_id,
        filename = args.filename,
        style_name = args.style_name,
        suitability_score = args.suitability_score,
        recommended_strength = args.recommended_strength,
        settings = copySettings(args.settings),
        risks = copyRisks(args.risks),
        status = "pending",
        reason = nil,
    }
    refreshProperties()
    startPanel()
    Log.info("Opened StylePilot approval request " .. args.request_id)

    return {
        success = true,
        request_id = args.request_id,
        status = "pending",
    }
end

function Panel.requestCalibrationApproval(args)
    requireString(args.request_id, "request_id", 100)
    requireString(args.experiment_id, "experiment_id", 100)
    requireString(args.experiment_name, "experiment_name", 255)
    requireInteger(args.baseline_repeats, "baseline_repeats", 2, 5)
    requireInteger(args.sample_count, "sample_count", 1, 1200)
    requireInteger(args.render_count, "render_count", 1, 2520)

    local photoIds = copyStrings(
        args.photo_ids, "photo_ids", MAX_CALIBRATION_PHOTOS, 255
    )
    local filenames = copyStrings(
        args.filenames, "filenames", MAX_CALIBRATION_PHOTOS, 500
    )
    if #photoIds ~= #filenames then
        error("photo_ids and filenames must contain the same number of entries")
    end
    local parameters, pointsPerPhoto = copyCalibrationParameters(args.parameters)
    local expectedSamples = #photoIds * pointsPerPhoto
    local expectedRenders = #photoIds
        * (args.baseline_repeats + 1 + (2 * pointsPerPhoto))
    if args.sample_count ~= expectedSamples then
        error("sample_count does not match the declared photos and parameter values")
    end
    if args.render_count ~= expectedRenders then
        error("render_count does not match the declared calibration plan")
    end

    if currentRequest and currentRequest.status == "pending"
        and currentRequest.request_id ~= args.request_id then
        error("Another StylePilot approval request is already pending")
    end
    if currentRequest and currentRequest.request_id == args.request_id then
        startPanel()
        return {
            success = true,
            request_id = currentRequest.request_id,
            status = currentRequest.status,
        }
    end

    local photoLines = {}
    for index, filename in ipairs(filenames) do
        table.insert(photoLines, filename .. " [" .. photoIds[index] .. "]")
    end
    currentRequest = {
        request_id = args.request_id,
        photo_id = args.experiment_id,
        filename = args.experiment_name,
        photo_label = table.concat(photoLines, "\n"),
        style_name = "Actuator calibration: " .. args.experiment_name,
        scope_text = string.format(
            "%d photos | %d virtual copies | %d samples | %d renders",
            #photoIds,
            #photoIds,
            args.sample_count,
            args.render_count
        ),
        settings = {},
        settings_text = formatCalibrationSettings(parameters),
        risks = copyRisks(args.risks),
        status = "pending",
        reason = nil,
    }
    refreshProperties()
    startPanel()
    Log.info("Opened StylePilot calibration approval " .. args.request_id)

    return {
        success = true,
        request_id = args.request_id,
        status = "pending",
    }
end

function Panel.getApproval(args)
    requireString(args.request_id, "request_id", 100)
    if not currentRequest or currentRequest.request_id ~= args.request_id then
        return {
            success = true,
            request_id = args.request_id,
            status = "unknown",
        }
    end
    return {
        success = true,
        request_id = currentRequest.request_id,
        status = currentRequest.status,
        reason = currentRequest.reason,
    }
end

function Panel.cancelApproval(args)
    requireString(args.request_id, "request_id", 100)
    if not currentRequest or currentRequest.request_id ~= args.request_id then
        return {
            success = true,
            request_id = args.request_id,
            status = "unknown",
        }
    end
    if currentRequest.status == "pending" then
        markDecision("rejected", "client_cancelled")
    end
    return {
        success = true,
        request_id = currentRequest.request_id,
        status = currentRequest.status,
        reason = currentRequest.reason,
    }
end

function Panel.show()
    startPanel()
end

return Panel
