-- tests/L1/helpers.lua
--
-- Minimal pure-Lua test harness for L1. Per dev-docs/test-strategy.md
-- §Deviations 1, busted is the planned framework "if/when L1 lands";
-- this lighter harness is chosen because (a) busted is not installed,
-- (b) only ~10 assertions are needed across the L1 suite, (c) installing
-- luarocks would be the first Lua dev dep and the strategy doc allows
-- "plain Lua + a minimal assertion harness if busted introduces too
-- much friction."
--
-- This file provides:
--   describe(name, fn)  — group of tests
--   it(name, fn)        — one test; fn errors on failure
--   eq(actual, expected, msg)         — assert ==
--   neq(actual, expected, msg)        — assert ~=
--   istrue(actual, msg)               — assert == true
--   isfalse(actual, msg)              — assert == false
--   tableq(actual, expected, msg)     — recursive table equality
--   throws(fn, pattern, msg)          — assert fn() raises matching message
--   raise(msg)                        — fail explicitly
--
-- run_tests() executes all registered tests, prints a summary,
-- and returns os.exit(0) on full pass / os.exit(1) on any failure.

local M = {}

local groups = {}
local current_group = nil

function M.describe(name, fn)
  current_group = { name = name, tests = {} }
  table.insert(groups, current_group)
  fn()
  current_group = nil
end

function M.it(name, fn)
  if not current_group then
    error("it() must be inside describe()")
  end
  table.insert(current_group.tests, { name = name, fn = fn })
end

local function format_value(v)
  if type(v) == "table" then
    -- Compact table-to-string for diagnostics.
    local parts = {}
    for k, val in pairs(v) do
      table.insert(parts, tostring(k) .. "=" .. tostring(val))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(v)
end

function M.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "eq failed") ..
          ": expected " .. format_value(expected) ..
          ", got " .. format_value(actual), 2)
  end
end

function M.neq(actual, expected, msg)
  if actual == expected then
    error((msg or "neq failed") ..
          ": both equal " .. format_value(actual), 2)
  end
end

function M.istrue(actual, msg)
  if actual ~= true then
    error((msg or "istrue failed") ..
          ": got " .. format_value(actual), 2)
  end
end

function M.isfalse(actual, msg)
  if actual ~= false then
    error((msg or "isfalse failed") ..
          ": got " .. format_value(actual), 2)
  end
end

local function table_equal(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end
  -- a ⊆ b
  for k, v in pairs(a) do
    if not table_equal(v, b[k]) then return false end
  end
  -- b ⊆ a
  for k, v in pairs(b) do
    if not table_equal(v, a[k]) then return false end
  end
  return true
end

function M.tableq(actual, expected, msg)
  if not table_equal(actual, expected) then
    error((msg or "tableq failed") ..
          ": expected " .. format_value(expected) ..
          ", got " .. format_value(actual), 2)
  end
end

function M.throws(fn, pattern, msg)
  local ok, err = pcall(fn)
  if ok then
    error((msg or "throws failed") .. ": fn did not raise", 2)
  end
  if pattern and not tostring(err):match(pattern) then
    error((msg or "throws failed") ..
          ": error '" .. tostring(err) ..
          "' does not match pattern '" .. pattern .. "'", 2)
  end
end

function M.raise(msg)
  error(msg or "raise()", 2)
end

-- Run every registered test. Print one line per test (PASS / FAIL with
-- error). Print summary. Return false if any failed (caller decides exit).
function M.run_tests()
  local passed = 0
  local failed = 0
  local failures = {}
  for _, group in ipairs(groups) do
    print("── " .. group.name)
    for _, t in ipairs(group.tests) do
      local ok, err = pcall(t.fn)
      if ok then
        passed = passed + 1
        print("  PASS " .. t.name)
      else
        failed = failed + 1
        print("  FAIL " .. t.name .. ": " .. tostring(err))
        table.insert(failures, group.name .. " / " .. t.name)
      end
    end
  end
  print("")
  if failed == 0 then
    print(string.format("L1 OK — %d passed, 0 failed", passed))
    return true
  else
    print(string.format("L1 FAIL — %d passed, %d failed", passed, failed))
    for _, f in ipairs(failures) do print("  - " .. f) end
    return false
  end
end

return M
