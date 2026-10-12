-- Reference external loader for the Argus private/offline-server project.
-- Pinned release source: v0.0.01 at commit 5a7b1a1d592bb8e082074141ac6ca6f5aa76846f.
-- Keep executor/API settings and compatibility behavior unchanged.
-- This file is separate from the main entrypoint and is not called by the main file.

local SOURCE_VERSION = "v0.0.01"
local SOURCE_COMMIT = "5a7b1a1d592bb8e082074141ac6ca6f5aa76846f"
local SOURCE_URL = "https://raw.githubusercontent.com/argusocean-wq/Test-aim-big-hub/" .. SOURCE_COMMIT .. "/Best黑鬼腳本_MobileTouchAim_AllHeadLock_Dodge_FINAL_1.lua"
local EXPECTED_SHA256 = "ecb775682b293f5d9698c20e875886725826271389d2b49de85cf4f86d9e5991"
local MAX_FETCH_ATTEMPTS = 3
local MIN_SOURCE_LENGTH = 500

local function report(stage, message)
    if type(warn) == "function" then
        warn("[Argus Loader][" .. tostring(stage) .. "] " .. tostring(message))
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
            lastError = tostring(result)
        elseif type(result) ~= "string" then
            lastError = "HTTP request did not return text"
        else
            lastError = "downloaded source is unexpectedly short (" .. tostring(#result) .. " bytes)"
        end

        if attempt < MAX_FETCH_ATTEMPTS then
            report("download", "attempt " .. tostring(attempt) .. " failed; retrying")
            waitBeforeRetry(attempt)
        end
    end

    return nil, lastError
end

local function verifySource(source)
    local versionPattern = '_G%.ArgusVersion%s*=%s*"' .. SOURCE_VERSION:gsub("%.", "%%.") .. '"'
    if not source:match(versionPattern) then
        return false, "source version marker mismatch; expected " .. SOURCE_VERSION
    end

    -- Fail closed when the current runtime cannot calculate SHA-256.
    -- Do not silently downgrade to a length-only or version-only check.
    if type(crypt) ~= "table" or type(crypt.hash) ~= "function" then
        return false, "SHA-256 verification unavailable (crypt.hash is required)"
    end

    local hashOk, digest = pcall(crypt.hash, source, "sha256")
    if not hashOk or type(digest) ~= "string" then
        return false, "SHA-256 calculation failed: " .. tostring(digest)
    end

    digest = string.lower(digest)
    if digest ~= EXPECTED_SHA256 then
        return false, "SHA-256 mismatch; refusing to compile or execute source"
    end

    return true, "version and SHA-256 verified"
end

local function loading()
    if _G.__ARGUS_LOADER_RUNNING then
        return false, "state", "loader is already running"
    end
    _G.__ARGUS_LOADER_RUNNING = true

    -- Reset only the loader handshake marker before each attempt.
    _G.__ARGUS_INIT_STATUS = nil

    local callOk, loaded, stage, detail = pcall(function()
        local source, fetchError = fetchSource()
        if not source then
            return false, "download", "unable to download source: " .. tostring(fetchError)
        end

        local verified, verifyMessage = verifySource(source)
        if not verified then
            return false, "integrity", verifyMessage
        end

        if type(loadstring) ~= "function" then
            return false, "compile", "loadstring is unavailable in this environment"
        end

        local compileOk, chunk, compileError = pcall(loadstring, source)
        if not compileOk then
            return false, "compile", "compiler raised an error: " .. tostring(chunk)
        end
        if type(chunk) ~= "function" then
            return false, "compile", tostring(compileError or "no compiled function returned")
        end

        -- Never retry execution: it may have partially initialized the UI or event handlers.
        _G.__ARGUS_INIT_STATUS = "starting"
        local runOk, runError = pcall(chunk)
        if not runOk then
            return false, "runtime", "entrypoint raised an error: " .. tostring(runError)
        end

        if _G.__ARGUS_INIT_STATUS ~= "ready" then
            return false, "initialization", "entrypoint returned without reporting ready (status: " .. tostring(_G.__ARGUS_INIT_STATUS) .. ")"
        end

        return true, "complete", "release " .. SOURCE_VERSION .. " loaded; version and SHA-256 verified"
    end)

    -- Always release the re-entry lock after ordinary Lua errors or returned failures.
    _G.__ARGUS_LOADER_RUNNING = nil

    if not callOk then
        report("internal", loaded)
        return false, "internal", tostring(loaded)
    end
    if not loaded then
        report(stage, detail)
        return false, stage, detail
    end

    report("complete", detail)
    return true, stage, detail
end

-- Preserve the familiar loading() call style.
local loaded, stage, loadMessage = loading()
if not loaded then
    report(stage, loadMessage)
end
