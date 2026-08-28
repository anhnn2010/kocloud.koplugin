local Test = {
    cases = {},
}

local function formatValue(value)
    if type(value) == "string" then
        return string.format("%q", value)
    end

    return tostring(value)
end

local function deepEqual(left, right, seen)
    if type(left) ~= type(right) then
        return false
    end

    if type(left) ~= "table" then
        return left == right
    end

    seen = seen or {}
    seen[left] = seen[left] or {}

    if seen[left][right] then
        return true
    end

    seen[left][right] = true

    for key, value in pairs(left) do
        if not deepEqual(value, right[key], seen) then
            return false
        end
    end

    for key, _value in pairs(right) do
        if left[key] == nil then
            return false
        end
    end

    return true
end

function Test.test(name, callback)
    table.insert(Test.cases, {
        name = name,
        callback = callback,
    })
end

function Test.assertTrue(value, message)
    if value ~= true then
        error(message or "Expected true", 2)
    end
end

function Test.assertFalse(value, message)
    if value ~= false then
        error(message or "Expected false", 2)
    end
end

function Test.assertNil(value, message)
    if value ~= nil then
        error(message or "Expected nil", 2)
    end
end

function Test.assertNotNil(value, message)
    if value == nil then
        error(message or "Expected non-nil value", 2)
    end
end

function Test.assertEqual(actual, expected, message)
    if actual ~= expected then
        error(
            message
                or string.format(
                    "Expected %s, got %s",
                    formatValue(expected),
                    formatValue(actual)
                ),
            2
        )
    end
end

function Test.assertDeepEqual(actual, expected, message)
    if not deepEqual(actual, expected) then
        error(message or "Tables are not deeply equal", 2)
    end
end

function Test.run()
    local failures = 0

    for _, case in ipairs(Test.cases) do
        local ok, error_message = pcall(case.callback)

        if ok then
            io.write("[PASS] ", case.name, "\n")
        else
            failures = failures + 1
            io.write("[FAIL] ", case.name, "\n")
            io.write("       ", tostring(error_message), "\n")
        end
    end

    io.write(string.format(
        "\n%d tests, %d failures\n",
        #Test.cases,
        failures
    ))

    if failures > 0 then
        os.exit(1)
    end
end

return Test
