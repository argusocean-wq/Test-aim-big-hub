-- Reference external loader for the Crescent Hub private/offline-server project.
-- Keep executor/API settings and compatibility behavior unchanged.
-- This file is separate from the main entrypoint and is not called by the main file.

local SOURCE_URL = "https://raw.githubusercontent.com/argusocean-wq/Test-aim-big-hub/main/CrescentHub.lua"
local MAX_FETCH_ATTEMPTS = 3
local MIN_SOURCE_LENGTH = 500

local function report(message)
    if type(warn) == "function" then
        warn("[Crescent Hub Loader] " .. tostring(message))
    end
end

local function waitBeforeRetry(seconds)
    if task and type(task.wait) == "function" then
        task.wait(seconds)
    elseif type(wait) == "function" then
        wait(seconds)
    end
end

local function fetchSource()
    local lastError = "unknown fetch error"

    for attempt = 1, MAX_FETCH_ATTEMPTS do
        local ok, result = pcall(function()
            return game:HttpGet(SOURCE_URL)
        end)

        if ok and type(result) == "string" and #result >= MIN_SOURCE_LENGTH then
            return result
        end

        if not ok then
            lastError = result
        elseif type(result) ~= "string" then
            lastError = "HTTP request did not return text"
        else
            lastError = "downloaded source is unexpectedly short (" .. tostring(#result) .. " bytes)"
        end

        if attempt < MAX_FETCH_ATTEMPTS then
            report("download attempt " .. tostring(attempt) .. " failed; retrying")
            waitBeforeRetry(attempt)
        end
    end

    return nil, lastError
end

local function loading()
    -- Prevent overlapping calls without changing the executor's APIs.
    if _G.__ARGUS_LOADER_RUNNING then
        return false, "loader is already running"
    end
    _G.__ARGUS_LOADER_RUNNING = true

    local ok, result, detail = pcall(function()
        local source, fetchError = fetchSource()
        if not source then
            return false, "unable to download source: " .. tostring(fetchError)
        end

        if type(loadstring) ~= "function" then
            return false, "loadstring is unavailable in this environment"
        end

        local compileOk, chunk, compileError = pcall(loadstring, source)
        if not compileOk then
            return false, "source compilation raised an error: " .. tostring(chunk)
        end
        if type(chunk) ~= "function" then
            return false, "source compilation failed: " .. tostring(compileError or "no compiled function returned")
        end

        -- Do not retry execution: a runtime failure may occur after partial initialization.
        local runOk, runError = pcall(chunk)
        if not runOk then
            return false, "entrypoint raised a runtime error: " .. tostring(runError)
        end

        return true, "entrypoint executed"
    end)

    _G.__ARGUS_LOADER_RUNNING = nil

    if not ok then
        report(result)
        return false, result
    end
    if not result then
        report(detail)
        return false, detail
    end

    return true, detail
end

-- Keep the familiar loading() call style.
local loaded, loadMessage = loading()
if not loaded then
    report(loadMessage)
end
