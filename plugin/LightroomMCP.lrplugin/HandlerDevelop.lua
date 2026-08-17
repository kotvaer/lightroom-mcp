local LrApplication = import 'LrApplication'

local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local DevelopHandler = {}

local MAX_BULK_PHOTO_IDS = 1000

local ALLOWED_DEVELOP_SETTING_KEYS = {
    "WhiteBalance",
    "Temperature",
    "Tint",
    "Exposure2012",
    "Contrast2012",
    "Highlights2012",
    "Shadows2012",
    "Whites2012",
    "Blacks2012",
    "Texture",
    "Clarity2012",
    "Dehaze",
    "Vibrance",
    "Saturation",
    "SaturationAdjustmentRed",
    "SaturationAdjustmentOrange",
    "SaturationAdjustmentYellow",
    "SaturationAdjustmentGreen",
    "SaturationAdjustmentAqua",
    "SaturationAdjustmentBlue",
    "SaturationAdjustmentPurple",
    "SaturationAdjustmentMagenta",
    "HueAdjustmentRed",
    "HueAdjustmentOrange",
    "HueAdjustmentYellow",
    "HueAdjustmentGreen",
    "HueAdjustmentAqua",
    "HueAdjustmentBlue",
    "HueAdjustmentPurple",
    "HueAdjustmentMagenta",
    "LuminanceAdjustmentRed",
    "LuminanceAdjustmentOrange",
    "LuminanceAdjustmentYellow",
    "LuminanceAdjustmentGreen",
    "LuminanceAdjustmentAqua",
    "LuminanceAdjustmentBlue",
    "LuminanceAdjustmentPurple",
    "LuminanceAdjustmentMagenta",
    "ParametricShadows",
    "ParametricDarks",
    "ParametricLights",
    "ParametricHighlights",
    "ParametricShadowSplit",
    "ParametricMidtoneSplit",
    "ParametricHighlightSplit",
    "ToneCurveName2012",
    "ConvertToGrayscale",
    "Sharpness",
    "SharpenRadius",
    "SharpenDetail",
    "SharpenEdgeMasking",
    "LuminanceSmoothing",
    "LuminanceNoiseReductionDetail",
    "LuminanceNoiseReductionContrast",
    "ColorNoiseReduction",
    "ColorNoiseReductionDetail",
    "ColorNoiseReductionSmoothness",
    "LensProfileEnable",
    "LensManualDistortionAmount",
    "PerspectiveVertical",
    "PerspectiveHorizontal",
    "PerspectiveRotate",
    "PerspectiveScale",
    "PerspectiveAspect",
    "PerspectiveUpright",
    "PostCropVignetteAmount",
    "PostCropVignetteMidpoint",
    "PostCropVignetteRoundness",
    "PostCropVignetteFeather",
    "PostCropVignetteStyle",
    "GrainAmount",
    "GrainSize",
    "GrainFrequency",
    "CropTop",
    "CropLeft",
    "CropBottom",
    "CropRight",
    "CropAngle",
}

local ALLOWED_DEVELOP_SETTING_LOOKUP = {}
for _, key in ipairs(ALLOWED_DEVELOP_SETTING_KEYS) do
    ALLOWED_DEVELOP_SETTING_LOOKUP[key] = true
end

-- StylePilot deliberately uses a much smaller numeric-only surface than the
-- general MCP develop tool. These ranges mirror the Python domain model and
-- provide an independent guard at the final Lightroom write boundary.
local STYLEPILOT_DEVELOP_PARAMETER_RANGES = {
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

local function requireString(value, name)
    if type(value) ~= "string" or value == "" then
        error(name .. " is required")
    end
end

local function requireBoundedString(value, name)
    requireString(value, name)
    if #value > 255 then
        error(name .. " must contain at most 255 characters")
    end
end

local function requireStringArray(value, name, maxItems)
    if type(value) ~= "table" then
        error(name .. " is required")
    end

    local count = 0
    for key, item in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            error(name .. " must be an array")
        end
        if type(item) ~= "string" or item == "" then
            error(name .. "[" .. tostring(key) .. "] must be a non-empty string")
        end
        count = count + 1
    end

    if count == 0 then
        error(name .. " is required")
    end
    if count ~= #value then
        error(name .. " must be an array")
    end
    if maxItems and count > maxItems then
        error(name .. " must contain at most " .. tostring(maxItems) .. " items")
    end
end

local function requireAllowedDevelopSettingKey(key)
    if not ALLOWED_DEVELOP_SETTING_LOOKUP[key] then
        error("Unsupported develop setting key: " .. tostring(key))
    end
end

local function requireDevelopSettingValue(key, value)
    local valueType = type(value)
    if valueType ~= "number" and valueType ~= "string" and valueType ~= "boolean" then
        error("Unsupported value for develop setting key: " .. tostring(key))
    end
end

local function requireDevelopSettingsObject(settings)
    if type(settings) ~= "table" then
        error("settings is required")
    end

    local count = 0
    for key, value in pairs(settings) do
        if type(key) ~= "string" then
            error("settings keys must be strings")
        end
        requireAllowedDevelopSettingKey(key)
        requireDevelopSettingValue(key, value)
        count = count + 1
    end

    if count == 0 then
        error("settings is required")
    end
end

local function requireStylePilotDevelopSettings(settings)
    if type(settings) ~= "table" then
        error("settings is required")
    end

    local count = 0
    for key, value in pairs(settings) do
        local valueRange = STYLEPILOT_DEVELOP_PARAMETER_RANGES[key]
        if not valueRange then
            error("Unsupported StylePilot develop setting key: " .. tostring(key))
        end
        if type(value) ~= "number" or value ~= value
            or value == math.huge or value == -math.huge then
            error("StylePilot develop setting " .. key .. " must be a finite number")
        end
        if value < valueRange[1] or value > valueRange[2] then
            error(string.format(
                "StylePilot develop setting %s must be between %s and %s",
                key,
                tostring(valueRange[1]),
                tostring(valueRange[2])
            ))
        end
        count = count + 1
    end

    if count == 0 then
        error("settings is required")
    end
end

local function requireVirtualCopy(photo, photoId)
    if photo:getRawMetadata('isVirtualCopy') ~= true then
        error("Refusing StylePilot write: photo is not a virtual copy: " .. photoId)
    end
end

local function findDevelopSnapshotByName(photo, snapshotName)
    local matched
    for _, snapshot in ipairs(photo:getDevelopSnapshots() or {}) do
        if snapshot.name == snapshotName then
            if matched then
                error("Multiple Develop snapshots have the same name: " .. snapshotName)
            end
            matched = snapshot
        end
    end
    return matched
end

local function requireDevelopSettingWhitelist(settings)
    if settings == nil then
        return
    end

    requireStringArray(settings, "settings", #ALLOWED_DEVELOP_SETTING_KEYS)
    for _, key in ipairs(settings) do
        requireAllowedDevelopSettingKey(key)
    end
end

local function findPresetByName(name)
    for _, folder in ipairs(LrApplication.developPresetFolders()) do
        for _, preset in ipairs(folder:getDevelopPresets()) do
            if preset:getName() == name then
                return preset, folder:getName()
            end
        end
    end
    return nil, nil
end

function DevelopHandler.listDevelopPresets(_)
    local out = {}
    for _, folder in ipairs(LrApplication.developPresetFolders()) do
        local fname = folder:getName()
        for _, preset in ipairs(folder:getDevelopPresets()) do
            table.insert(out, { name = preset:getName(), folder = fname })
        end
    end

    Log.info(string.format("Listed %d develop presets", #out))

    return {
        success = true,
        presets = out,
        count = #out,
    }
end

function DevelopHandler.applyDevelopPreset(args)
    requireStringArray(args.photo_ids, "photo_ids", MAX_BULK_PHOTO_IDS)
    requireString(args.preset_name, "preset_name")

    local preset, folder = findPresetByName(args.preset_name)
    if not preset then
        error("Preset not found: " .. args.preset_name)
    end

    local catalog = LrApplication.activeCatalog()
    local appliedCount = 0

    catalog:withWriteAccessDo("Apply Develop Preset", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                entry.photo:applyDevelopPreset(preset)
                appliedCount = appliedCount + 1
            end
        end
    end)

    Log.info(string.format("Applied preset %s to %d photos", args.preset_name, appliedCount))

    return {
        success = true,
        applied = appliedCount,
        preset = args.preset_name,
        folder = folder,
        message = string.format("Applied preset %s to %d photos", args.preset_name, appliedCount),
    }
end

function DevelopHandler.copyDevelopSettings(args)
    requireString(args.source_id, "source_id")
    requireStringArray(args.target_ids, "target_ids", MAX_BULK_PHOTO_IDS)
    requireDevelopSettingWhitelist(args.settings)

    local catalog = LrApplication.activeCatalog()
    local sourceSettings

    catalog:withReadAccessDo(function()
        local source = PhotoLookup.resolveOne(catalog, args.source_id)
        if not source then
            error("Source photo not found: " .. args.source_id)
        end
        sourceSettings = source:getDevelopSettings()
    end)

    local toApply = sourceSettings
    if args.settings then
        toApply = {}
        for _, key in ipairs(args.settings) do
            toApply[key] = sourceSettings[key]
        end
    end

    local copiedCount = 0

    catalog:withWriteAccessDo("Copy Develop Settings", function()
        local resolved = PhotoLookup.resolveMany(catalog, args.target_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                entry.photo:applyDevelopSettings(toApply)
                copiedCount = copiedCount + 1
            end
        end
    end)

    Log.info(string.format("Copied develop settings from %s to %d photos", args.source_id, copiedCount))

    return {
        success = true,
        copied = copiedCount,
        source = args.source_id,
        message = string.format("Copied develop settings from %s to %d photos", args.source_id, copiedCount),
    }
end

function DevelopHandler.createVirtualCopy(args)
    requireString(args.photo_id, "photo_id")
    requireBoundedString(args.copy_name, "copy_name")

    local catalog = LrApplication.activeCatalog()
    local source = PhotoLookup.resolveOne(catalog, args.photo_id)
    if not source then
        error("Photo not found: " .. args.photo_id)
    end

    -- Lightroom's SDK only creates virtual copies for the current selection.
    -- Narrow the selection to the resolved source so an unrelated filmstrip
    -- selection can never receive a copy by accident.
    catalog:setSelectedPhotos(source, {})
    local copies = catalog:createVirtualCopies(args.copy_name)
    if not copies or #copies ~= 1 then
        error("Expected Lightroom to create exactly one virtual copy")
    end

    local virtualCopy = copies[1]
    Log.info(string.format("Created virtual copy %s from photo %s",
        tostring(virtualCopy.localIdentifier), tostring(source.localIdentifier)))

    return {
        success = true,
        source_photo_id = source.localIdentifier,
        virtual_copy = {
            id = virtualCopy.localIdentifier,
            path = virtualCopy:getRawMetadata('path'),
            filename = virtualCopy:getFormattedMetadata('fileName'),
            copy_name = args.copy_name,
        },
    }
end

function DevelopHandler.createDevelopSnapshot(args)
    requireString(args.photo_id, "photo_id")
    requireBoundedString(args.snapshot_name, "snapshot_name")

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, args.photo_id)
    if not photo then
        error("Photo not found: " .. args.photo_id)
    end
    requireVirtualCopy(photo, args.photo_id)

    local created = false
    catalog:withWriteAccessDo("Create StylePilot Develop Snapshot", function()
        created = photo:createDevelopSnapshot(args.snapshot_name, false)
    end)
    if not created then
        error("Develop snapshot already exists: " .. args.snapshot_name)
    end

    local snapshot = findDevelopSnapshotByName(photo, args.snapshot_name)
    if not snapshot or not snapshot.snapshotID then
        error("Created Develop snapshot could not be resolved: " .. args.snapshot_name)
    end

    Log.info(string.format("Created Develop snapshot %s on photo %s",
        args.snapshot_name, args.photo_id))

    return {
        success = true,
        photo_id = args.photo_id,
        snapshot = {
            id = snapshot.snapshotID,
            global_id = snapshot.id_global,
            name = snapshot.name,
        },
    }
end

function DevelopHandler.restoreDevelopSnapshot(args)
    requireString(args.photo_id, "photo_id")
    requireBoundedString(args.snapshot_name, "snapshot_name")

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, args.photo_id)
    if not photo then
        error("Photo not found: " .. args.photo_id)
    end
    requireVirtualCopy(photo, args.photo_id)

    local snapshot = findDevelopSnapshotByName(photo, args.snapshot_name)
    if not snapshot or not snapshot.snapshotID then
        error("Develop snapshot not found: " .. args.snapshot_name)
    end

    -- Snapshot application has historically been sensitive to the active
    -- photo. Select the resolved virtual copy so another filmstrip photo can
    -- never receive the rollback.
    catalog:setSelectedPhotos(photo, {})
    catalog:withWriteAccessDo("Restore StylePilot Develop Snapshot", function()
        photo:applyDevelopSnapshot(snapshot.snapshotID)
    end)

    Log.info(string.format("Restored Develop snapshot %s on photo %s",
        args.snapshot_name, args.photo_id))

    return {
        success = true,
        photo_id = args.photo_id,
        snapshot_id = snapshot.snapshotID,
        snapshot_name = snapshot.name,
    }
end

function DevelopHandler.setStylePilotDevelopSettings(args)
    requireString(args.photo_id, "photo_id")
    requireBoundedString(args.history_name, "history_name")
    requireStylePilotDevelopSettings(args.settings)

    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.resolveOne(catalog, args.photo_id)
    if not photo then
        error("Photo not found: " .. args.photo_id)
    end
    requireVirtualCopy(photo, args.photo_id)

    catalog:withWriteAccessDo(args.history_name, function()
        photo:applyDevelopSettings(args.settings, args.history_name)
    end)

    Log.info(string.format("Set guarded StylePilot settings on virtual copy %s", args.photo_id))

    return {
        success = true,
        photo_id = args.photo_id,
    }
end

function DevelopHandler.setDevelopSettings(args)
    requireString(args.photo_id, "photo_id")
    requireDevelopSettingsObject(args.settings)

    local catalog = LrApplication.activeCatalog()
    local applied = false

    catalog:withWriteAccessDo("Set Develop Settings", function()
        local photo = PhotoLookup.resolveOne(catalog, args.photo_id)
        if not photo then
            error("Photo not found: " .. args.photo_id)
        end
        photo:applyDevelopSettings(args.settings)
        applied = true
    end)

    Log.info(string.format("Set develop settings on photo %s", args.photo_id))

    return {
        success = applied,
        photo_id = args.photo_id,
    }
end

return DevelopHandler
