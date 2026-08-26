local helper = require 'spec_helper'

local function fakeFactory()
    local factory = {
        control_spacing = function() return 6 end,
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

local function shellQuote(value)
    return "'" .. value:gsub("'", [['"'"']]) .. "'"
end

local function writeFile(path, payload)
    local handle = assert(io.open(path, "w"))
    handle:write(payload)
    handle:close()
end

local function setup(options)
    options = options or {}
    local root = os.tmpname()
    os.remove(root)
    assert(os.execute("mkdir -p " .. shellQuote(root .. "/.config/stylepilot")))
    assert(os.execute("mkdir -p " .. shellQuote(root .. "/results")))
    local configFile = root .. "/.config/stylepilot/lightroom-runtime.json"
    if options.withConfig ~= false then
        writeFile(configFile, [[{
            "schema_version":"stylepilot-lightroom-panel-runtime-v1",
            "platform":"macos",
            "runtime_executable":"/runtime/stylepilot",
            "env_file":"/config/.env",
            "default_profile":null,
            "preview_root":"]] .. root .. [[/previews",
            "result_directory":"]] .. root .. [[/results"
        }]])
    end
    local requestId = "request1"
    local resultFile = root .. "/results/" .. requestId .. ".json"
    writeFile(resultFile, options.result or [[{
        "schema_version":"stylepilot-lightroom-panel-result-v1",
        "request_id":"request1",
        "status":"completed",
        "result":{
            "status":"planned",
            "message":"A guarded Lightroom Develop plan is ready.",
            "photo":{"id":"38953","filename":"source.arw"},
            "metrics":{"scene_type":"portrait","scene_confidence":0.95},
            "suitability":{"score":83.07,"eligible":true,"recommended_strength":0.98},
            "plan":{"settings":{"values":{"Exposure2012":0.13,"Highlights2012":-23.5}}},
            "verification":null
        }
    }]])

    local photo = helper.fakePhoto({
        id = "38953",
        fileName = "source.arw",
        path = "/photos/source.arw",
    })
    local catalog = helper.fakeCatalog({ photos = { photo }, targetPhotos = { photo } })
    local capturedDialog
    local capturedCommand
    local properties
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrBinding = {
            makePropertyTable = function()
                properties = {}
                return properties
            end,
        },
        LrDialogs = {
            presentFloatingDialog = function(_, args)
                capturedDialog = args
                if args.onShow then args.onShow({ toFront = function() end }) end
            end,
        },
        LrFileUtils = {
            exists = function(path)
                if path == "/runtime/stylepilot" or path == "/config/.env" then
                    return "file"
                end
                local handle = io.open(path, "r")
                if handle then handle:close() return "file" end
                return false
            end,
            createAllDirectories = function(path)
                os.execute("mkdir -p " .. shellQuote(path))
            end,
        },
        LrFunctionContext = {
            callWithContext = function(_, fn) fn({}) end,
        },
        LrPathUtils = {
            child = function(parent, child) return parent .. "/" .. child end,
            getStandardFilePath = function(kind)
                if kind == "home" then return root end
                return root
            end,
        },
        LrTasks = {
            startAsyncTask = function(fn) fn() end,
            pcall = pcall,
            execute = function(command)
                capturedCommand = command
                return 0
            end,
        },
        LrUUID = { generateUUID = function() return "request-1" end },
        LrView = {
            bind = function(key) return { binding = key } end,
            osFactory = fakeFactory,
        },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.Log = nil
    package.loaded.StylePilotWorkspace = nil
    local Workspace = require 'StylePilotWorkspace'
    Workspace.show()
    return {
        workspace = Workspace,
        dialog = capturedDialog,
        properties = properties,
        getCommand = function() return capturedCommand end,
        cleanup = function() os.execute("rm -rf " .. shellQuote(root)) end,
    }
end

describe("StylePilotWorkspace", function()
    it("launches a read-only panel job and renders its result", function()
        local fixture = setup()
        local analyze = findButton(fixture.dialog.contents, "Analyze selected photo")

        analyze.action()
        local state = fixture.workspace.getStateForTests()

        assert.is_not_nil(analyze)
        assert.matches("lightroom.*panel%-run", fixture.getCommand())
        assert.not_matches("apply%-to%-virtual%-copy", fixture.getCommand())
        assert.are.equal("planned", state.status)
        assert.matches("portrait", state.scene)
        assert.matches("83.1 / 100", state.suitability)
        assert.matches("Exposure2012: 0.13", state.settings)
        assert.are.equal("Not applied", state.verification)
        fixture.cleanup()
    end)

    it("keeps the guarded apply entry point behind the existing approval flow", function()
        local fixture = setup()
        local apply = findButton(fixture.dialog.contents, "Apply to virtual copy...")

        apply.action()
        local _, running = fixture.workspace.getStateForTests()

        assert.matches("%-%-apply%-to%-virtual%-copy", fixture.getCommand())
        assert.is_false(running)
        fixture.cleanup()
    end)

    it("shows configuration failures inside Lightroom", function()
        local fixture = setup({ withConfig = false })
        local analyze = findButton(fixture.dialog.contents, "Analyze selected photo")

        analyze.action()
        local state = fixture.workspace.getStateForTests()

        assert.are.equal("Failed", state.status)
        assert.matches("lightroom%-runtime.json", state.message)
        fixture.cleanup()
    end)

    it("rejects a result for a photo other than the one selected at launch", function()
        local fixture = setup({ result = [[{
            "schema_version":"stylepilot-lightroom-panel-result-v1",
            "request_id":"request1",
            "status":"completed",
            "result":{
                "status":"planned",
                "message":"ready",
                "photo":{"id":"another-photo","filename":"other.arw"}
            }
        }]] })
        local analyze = findButton(fixture.dialog.contents, "Analyze selected photo")

        analyze.action()
        local state = fixture.workspace.getStateForTests()

        assert.are.equal("Failed", state.status)
        assert.matches("different Lightroom photo", state.message)
        fixture.cleanup()
    end)

    it("quotes apostrophes without shell interpolation", function()
        local fixture = setup()
        local command = fixture.workspace.commandForTests({
            platform = "macos",
            runtime_executable = "/App's/stylepilot",
            env_file = "/Config/.env",
            preview_root = "/Preview Root",
            result_directory = "/results",
        }, "job1", "/results/job1.json", false)

        assert.matches("'\"'\"'", command)
        assert.matches("'/Preview Root'", command)
        fixture.cleanup()
    end)

    it("quotes Windows paths using the configured runtime platform", function()
        local fixture = setup()
        local command = fixture.workspace.commandForTests({
            platform = "windows",
            runtime_executable = "C:\\Style Pilot\\stylepilot.exe",
            env_file = "C:\\Style Pilot\\.env",
            preview_root = "C:\\Style Pilot\\previews",
            result_directory = "C:\\results",
        }, "job1", "C:\\results\\job1.json", false)

        assert.is_not_nil(command:find('"C:\\Style Pilot\\stylepilot.exe"', 1, true))
        assert.is_not_nil(command:find('"C:\\Style Pilot\\.env"', 1, true))
        fixture.cleanup()
    end)
end)
