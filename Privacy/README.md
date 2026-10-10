# Privacy UI masking helper

`PrivacyTextMask.lua` is an opt-in helper for **your own ScreenGui**. It places opaque black sibling frames over matching TextLabel, TextButton, and TextBox text.

## Example

```lua
local PrivacyTextMask = require(path.to.PrivacyTextMask)

local mask = PrivacyTextMask.new(playerGui:WaitForChild("MyOwnedScreenGui"), {
    Enabled = true,
    Allowlist = {
        ["Public status"] = true,
    },
    ShouldMask = function(text, textObject)
        -- Keep this predicate narrow to avoid masking ordinary UI labels.
        return text:match("^@[%w_]+$") ~= nil
            or text:match("^[Uu]ser[Ii][Dd]%s*:%s*%d%d%d%d%d+") ~= nil
            or text:match("^[Pp]layer[Ii][Dd]%s*:%s*%d%d%d%d%d+") ~= nil
    end,
})

-- Toggle when needed:
mask:SetEnabled(false)
mask:SetEnabled(true)

-- Clean up when the owning UI is removed:
mask:Destroy()
```

## Scope and limitations

- Only inspects text objects inside the ScreenGui supplied by your own code.
- It does not OCR rendered pixels, inspect other applications, or guarantee detection of every username/ID.
- Detection is heuristic; use a narrow `ShouldMask` predicate and test against your actual UI.
- The black cover is a UI privacy aid, not a security boundary. It does not prevent screenshots or capture by external software.
- This helper is intentionally independent of gameplay overlays and does not implement spectator-specific concealment.
