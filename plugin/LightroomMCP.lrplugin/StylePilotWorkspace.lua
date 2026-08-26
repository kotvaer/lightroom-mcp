local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrUUID = import 'LrUUID'
local LrView = import 'LrView'

local JSON = require 'JSON'
local Log = require 'Log'

local Workspace = {}

local propertyTable
local dialogControls
local panelOpen = false
local panelStarting = false
local jobRunning = false
local lastState = {
    status = "Idle",
    message = "Select one photo, then analyze it with the configured StylePilot runtime.",
    photo = "-",
    scene = "-",
    suitability = "-",
    settings = "-",
    verification = "-",
    configuration = "Not checked",
}

local function configPath()
    local home = LrPathUtils.getStandardFilePath("home")
    return LrPathUtils.child(
        LrPathUtils.child(LrPathUtils.child(home, ".config"), "stylepilot"),
        "lightroom-runtime.json"
    )
end

local function readFile(path)
    local handle, openError = io.open(path, "r")
    if not handle then error("Cannot open " .. path .. ": " .. tostring(openError)) end
    local payload = handle:read("*a")
    handle:close()
    return payload
end

local function readJson(path, label)
    local ok, payload = pcall(function() return JSON:decode(readFile(path)) end)
    if not ok or type(payload) ~= "table" then
        error(label .. " is not valid JSON: " .. tostring(payload))
    end
    return payload
end

local function requireFile(path, label)
    if type(path) ~= "string" or path == "" then error(label .. " is required") end
    if LrFileUtils.exists(path) ~= "file" then
        error(label .. " does not exist: " .. path)
    end
end

local function loadRuntimeConfig()
    local path = configPath()
    local config = readJson(path, "StylePilot runtime configuration")
    if config.schema_version ~= "stylepilot-lightroom-panel-runtime-v1" then
        error("Unsupported StylePilot runtime configuration schema")
    end
    if config.platform ~= "macos" and config.platform ~= "windows" then
        error("Unsupported StylePilot runtime platform")
    end
    requireFile(config.runtime_executable, "StylePilot runtime executable")
    requireFile(config.env_file, "StylePilot dotenv configuration")
    if config.default_profile ~= nil then
        requireFile(config.default_profile, "Default Style Profile")
    end
    if type(config.preview_root) ~= "string" or config.preview_root == "" then
        error("StylePilot preview_root is required")
    end
    if type(config.result_directory) ~= "string" or config.result_directory == "" then
        error("StylePilot result_directory is required")
    end
    LrFileUtils.createAllDirectories(config.preview_root)
    LrFileUtils.createAllDirectories(config.result_directory)
    return config, path
end

local function quoteArgument(value, platform)
    value = tostring(value)
    if value:find("[\r\n]") then error("StylePilot command arguments cannot contain newlines") end
    if platform == "windows" then
        if value:find('"') then error("StylePilot Windows paths cannot contain double quotes") end
        return '"' .. value .. '"'
    end
    return "'" .. value:gsub("'", [['"'"']]) .. "'"
end

local function commandFor(config, requestId, resultPath, apply)
    local arguments = {
        config.runtime_executable,
        "lightroom",
        "panel-run",
        "--request-id",
        requestId,
        "--result-file",
        resultPath,
        "--env-file",
        config.env_file,
        "--preview-root",
        config.preview_root,
    }
    if config.default_profile ~= nil then
        table.insert(arguments, "--profile")
        table.insert(arguments, config.default_profile)
    end
    if apply then table.insert(arguments, "--apply-to-virtual-copy") end

    local quoted = {}
    for _, argument in ipairs(arguments) do
        table.insert(quoted, quoteArgument(argument, config.platform))
    end
    return table.concat(quoted, " ")
end

local function formatSettings(settings)
    if type(settings) ~= "table" then return "-" end
    local keys = {}
    for key in pairs(settings) do table.insert(keys, key) end
    table.sort(keys)
    if #keys == 0 then return "-" end
    local lines = {}
    for _, key in ipairs(keys) do
        local value = settings[key]
        if type(value) == "number" then
            table.insert(lines, string.format("%s: %.2f", key, value))
        end
    end
    return #lines > 0 and table.concat(lines, "\n") or "-"
end

local function formatScene(metrics)
    if type(metrics) ~= "table" then return "-" end
    local scene = metrics.scene_type or "unknown"
    local confidence = tonumber(metrics.scene_confidence) or 0
    return string.format("%s (%.0f%% confidence)", scene, confidence * 100)
end

local function formatSuitability(suitability)
    if type(suitability) ~= "table" then return "-" end
    return string.format(
        "%.1f / 100 | %s | strength %.0f%%",
        tonumber(suitability.score) or 0,
        suitability.eligible and "eligible" or "not eligible",
        (tonumber(suitability.recommended_strength) or 0) * 100
    )
end

local function formatVerification(result)
    local verification = result.verification
    if type(verification) ~= "table" then return "Not applied" end
    local improvement = tonumber(verification.improvement_ratio)
    local summary = verification.passed and "Passed" or "Failed"
    if improvement then
        summary = summary .. string.format(" | style gain %.1f%%", improvement * 100)
    end
    if type(verification.issues) == "table" and #verification.issues > 0 then
        summary = summary .. "\n- " .. table.concat(verification.issues, "\n- ")
    end
    return summary
end

local function refreshProperties()
    if not propertyTable then return end
    for key, value in pairs(lastState) do propertyTable[key] = value end
    propertyTable.canRun = not jobRunning
end

local function showError(message)
    lastState.status = "Failed"
    lastState.message = tostring(message)
    refreshProperties()
    Log.error("StylePilot workspace job failed: " .. tostring(message))
end

local function selectedPhotoIdentity()
    local catalog = LrApplication.activeCatalog()
    local selected = catalog:getTargetPhotos()
    if #selected ~= 1 then
        error("Select exactly one Lightroom photo before starting StylePilot")
    end
    local photoId
    local filename
    catalog:withReadAccessDo(function()
        photoId = tostring(selected[1].localIdentifier)
        filename = selected[1]:getFormattedMetadata('fileName')
    end)
    if not filename or filename == "" then filename = "Selected photo" end
    return photoId, filename
end

local function applyResult(envelope, expectedPhotoId)
    if envelope.schema_version ~= "stylepilot-lightroom-panel-result-v1" then
        error("Unsupported StylePilot panel result schema")
    end
    if envelope.status ~= "completed" then
        error(envelope.error or "StylePilot runtime failed without an error message")
    end
    local result = envelope.result
    if type(result) ~= "table" then error("StylePilot runtime result is missing") end
    local photo = result.photo or {}
    if tostring(photo.id or "") ~= expectedPhotoId then
        error("StylePilot analyzed a different Lightroom photo; run the request again")
    end
    lastState.status = result.status or "Completed"
    lastState.message = result.message or "StylePilot completed."
    lastState.photo = (photo.filename or "Selected photo") .. " [" .. tostring(photo.id or "-") .. "]"
    lastState.scene = formatScene(result.metrics)
    lastState.suitability = formatSuitability(result.suitability)
    local plan = result.plan or {}
    local settings = plan.settings or {}
    lastState.settings = formatSettings(settings.values)
    lastState.verification = formatVerification(result)
end

local function runJob(apply)
    if jobRunning then return end
    jobRunning = true
    lastState.status = "Starting"
    lastState.message = "Loading the StylePilot runtime configuration."
    refreshProperties()

    LrTasks.startAsyncTask(function()
        local ok, jobError = LrTasks.pcall(function()
            local config, loadedConfigPath = loadRuntimeConfig()
            local photoId, filename = selectedPhotoIdentity()
            local requestId = LrUUID.generateUUID():gsub("-", "")
            local resultPath = LrPathUtils.child(
                config.result_directory,
                requestId .. ".json"
            )
            lastState.configuration = loadedConfigPath
            lastState.photo = filename .. " [" .. photoId .. "]"
            lastState.status = apply and "Analyzing before approval" or "Analyzing"
            lastState.message = apply
                and "Preparing a guarded virtual-copy proposal. Approval will still be required."
                or "Rendering and analyzing the selected photo. No Develop settings will be written."
            refreshProperties()

            local command = commandFor(config, requestId, resultPath, apply)
            Log.info("StylePilot workspace launching request " .. requestId)
            local exitStatus = LrTasks.execute(command)
            if LrFileUtils.exists(resultPath) ~= "file" then
                error("StylePilot runtime exited without a result file (status "
                    .. tostring(exitStatus) .. ")")
            end
            local envelope = readJson(resultPath, "StylePilot panel result")
            if envelope.request_id ~= requestId then
                error("StylePilot runtime returned a result for the wrong request")
            end
            applyResult(envelope, photoId)
            Log.info("StylePilot workspace completed request " .. requestId)
        end)
        jobRunning = false
        if not ok then showError(jobError) else refreshProperties() end
    end)
end

local function buildContents(factory)
    return factory:column {
        bind_to_object = propertyTable,
        spacing = factory:control_spacing(),
        margin = factory:dialog_spacing(),
        fill_horizontal = 1,
        factory:static_text {
            title = "Analyze and safely edit the selected Lightroom photo",
            width_in_chars = 58,
        },
        factory:row {
            spacing = factory:control_spacing(),
            factory:push_button {
                title = "Analyze selected photo",
                enabled = LrView.bind('canRun'),
                action = function() runJob(false) end,
            },
            factory:push_button {
                title = "Apply to virtual copy...",
                enabled = LrView.bind('canRun'),
                action = function() runJob(true) end,
            },
            factory:static_text { title = LrView.bind('status') },
        },
        factory:separator { fill_horizontal = 1 },
        factory:static_text { title = "Photo" },
        factory:static_text { title = LrView.bind('photo'), width_in_chars = 58 },
        factory:static_text { title = "Scene" },
        factory:static_text { title = LrView.bind('scene'), width_in_chars = 58 },
        factory:static_text { title = "Suitability" },
        factory:static_text { title = LrView.bind('suitability'), width_in_chars = 58 },
        factory:static_text { title = "Proposed Develop settings" },
        factory:static_text {
            title = LrView.bind('settings'),
            width_in_chars = 58,
            height_in_lines = 6,
        },
        factory:static_text { title = "Verification" },
        factory:static_text {
            title = LrView.bind('verification'),
            width_in_chars = 58,
            height_in_lines = 4,
        },
        factory:static_text { title = "Status details" },
        factory:static_text {
            title = LrView.bind('message'),
            width_in_chars = 58,
            height_in_lines = 3,
        },
        factory:static_text {
            title = "Runtime configuration: " .. configPath(),
            width_in_chars = 58,
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
        local ok, panelError = LrTasks.pcall(function()
            LrFunctionContext.callWithContext("StylePilot workspace", function(context)
                propertyTable = LrBinding.makePropertyTable(context)
                refreshProperties()
                local factory = LrView.osFactory()
                panelOpen = true
                panelStarting = false
                LrDialogs.presentFloatingDialog(_PLUGIN, {
                    title = "StylePilot",
                    contents = buildContents(factory),
                    blockTask = true,
                    save_frame = "stylepilotWorkspace",
                    onShow = function(controls)
                        dialogControls = controls
                        if controls.toFront then controls.toFront() end
                    end,
                    windowWillClose = function()
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
        if not ok then Log.error("StylePilot workspace panel failed: " .. tostring(panelError)) end
    end)
end

function Workspace.show()
    startPanel()
end

function Workspace.getStateForTests()
    return lastState, jobRunning
end

function Workspace.commandForTests(config, requestId, resultPath, apply)
    return commandFor(config, requestId, resultPath, apply)
end

return Workspace
