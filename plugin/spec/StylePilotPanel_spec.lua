local helper = require 'spec_helper'

local function fakeFactory()
    local factory = {
        control_spacing = function() return 6 end,
        label_spacing = function() return 4 end,
        dialog_spacing = function() return 10 end,
    }
    return setmetatable(factory, {
        __index = function(_, kind)
            return function(_, args)
                args.kind = kind
                return args
            end
        end,
    })
end

local function findButton(node, title)
    if type(node) ~= "table" then return nil end
    if node.kind == "push_button" and node.title == title then return node end
    for _, child in ipairs(node) do
        local matched = findButton(child, title)
        if matched then return matched end
    end
    return nil
end

local function setup()
    local capturedDialog
    helper.installImport({
        LrBinding = {
            makePropertyTable = function() return {} end,
        },
        LrDialogs = {
            presentFloatingDialog = function(_, args)
                capturedDialog = args
                if args.onShow then
                    args.onShow({
                        toFront = function() end,
                        close = function()
                            if args.windowWillClose then args.windowWillClose() end
                        end,
                    })
                end
            end,
        },
        LrFunctionContext = {
            callWithContext = function(_, fn) fn({}) end,
        },
        LrTasks = {
            startAsyncTask = function(fn) fn() end,
            pcall = pcall,
        },
        LrView = {
            bind = function(key) return { binding = key } end,
            osFactory = fakeFactory,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.Log = nil
    package.loaded.StylePilotPanel = nil
    local Panel = require 'StylePilotPanel'
    return Panel, function() return capturedDialog end
end

local function approvalArgs(requestId)
    return {
        request_id = requestId or "request-1",
        photo_id = "37246",
        filename = "source.dng",
        style_name = "Bright Clean",
        suitability_score = 85.7,
        recommended_strength = 0.9,
        settings = { Exposure2012 = 1.2, Vibrance = 25 },
        risks = { "Brightness shift is material." },
    }
end

local function calibrationArgs(requestId)
    return {
        request_id = requestId or "calibration-1",
        experiment_id = "basic-tone-smoke",
        experiment_name = "Basic tone smoke",
        photo_ids = { "37246", "37247" },
        filenames = { "one.dng", "two.dng" },
        baseline_repeats = 3,
        sample_count = 6,
        render_count = 20,
        parameters = {
            { parameter = "Contrast2012", values = { -20, 0, 20 } },
        },
        risks = { "Creates two virtual copies." },
    }
end

describe("StylePilotPanel", function()
    it("opens a blocking floating review panel and returns pending", function()
        local Panel, getDialog = setup()

        local result = Panel.requestApproval(approvalArgs())
        local dialog = getDialog()

        assert.is_true(result.success)
        assert.are.equal("request-1", result.request_id)
        assert.are.equal("pending", result.status)
        assert.are.equal("StylePilot — Review Operation", dialog.title)
        assert.is_true(dialog.blockTask)
        assert.is_not_nil(findButton(dialog.contents, "Reject"))
        assert.is_not_nil(findButton(dialog.contents, "Approve virtual-copy operation"))
    end)

    it("binds approval to the request id", function()
        local Panel, getDialog = setup()
        Panel.requestApproval(approvalArgs("request-approve"))
        local approve = findButton(getDialog().contents, "Approve virtual-copy operation")

        approve.action()
        local result = Panel.getApproval({ request_id = "request-approve" })

        assert.are.equal("approved", result.status)
        assert.are.equal("user_approved", result.reason)
        assert.are.equal(
            "unknown",
            Panel.getApproval({ request_id = "different-request" }).status
        )
    end)

    it("records explicit rejection", function()
        local Panel, getDialog = setup()
        Panel.requestApproval(approvalArgs("request-reject"))
        local reject = findButton(getDialog().contents, "Reject")

        reject.action()
        local result = Panel.getApproval({ request_id = "request-reject" })

        assert.are.equal("rejected", result.status)
        assert.are.equal("user_rejected", result.reason)
    end)

    it("cancels a pending request when its client times out", function()
        local Panel, getDialog = setup()
        Panel.requestApproval(approvalArgs("request-timeout"))

        local result = Panel.cancelApproval({ request_id = "request-timeout" })

        assert.are.equal("rejected", result.status)
        assert.are.equal("client_cancelled", result.reason)
        assert.are.equal(
            "unknown",
            Panel.cancelApproval({ request_id = "different-request" }).status
        )
        assert.is_not_nil(getDialog())
    end)

    it("treats closing a pending review as rejection", function()
        local Panel, getDialog = setup()
        Panel.requestApproval(approvalArgs("request-close"))

        getDialog().windowWillClose()
        local result = Panel.getApproval({ request_id = "request-close" })

        assert.are.equal("rejected", result.status)
        assert.are.equal("window_closed", result.reason)
    end)

    it("does not replace a different pending request", function()
        local Panel = setup()
        Panel.requestApproval(approvalArgs("request-1"))

        assert.has_error(function()
            Panel.requestApproval(approvalArgs("request-2"))
        end, "Another StylePilot approval request is already pending")

        assert.are.equal(
            "pending",
            Panel.getApproval({ request_id = "request-1" }).status
        )
    end)

    it("validates bounded approval payloads", function()
        local Panel = setup()
        local invalidScore = approvalArgs()
        invalidScore.suitability_score = 101
        local invalidSettings = approvalArgs()
        invalidSettings.settings = { Exposure2012 = "1.2" }

        assert.has_error(function() Panel.requestApproval(invalidScore) end)
        assert.has_error(function() Panel.requestApproval(invalidSettings) end)
    end)

    it("opens one request-bound batch calibration approval", function()
        local Panel, getDialog = setup()

        local result = Panel.requestCalibrationApproval(calibrationArgs())
        local approve = findButton(
            getDialog().contents,
            "Approve virtual-copy operation"
        )
        approve.action()

        assert.is_true(result.success)
        assert.are.equal("pending", result.status)
        assert.are.equal(
            "approved",
            Panel.getApproval({ request_id = "calibration-1" }).status
        )
    end)

    it("rejects inconsistent or out-of-range calibration scope", function()
        local Panel = setup()
        local wrongCount = calibrationArgs("wrong-count")
        wrongCount.sample_count = 5
        local unsafeValue = calibrationArgs("unsafe-value")
        unsafeValue.parameters[1].values = { -20, 0, 101 }

        assert.has_error(function()
            Panel.requestCalibrationApproval(wrongCount)
        end)
        assert.has_error(function()
            Panel.requestCalibrationApproval(unsafeValue)
        end)
    end)
end)
