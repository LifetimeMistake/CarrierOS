local utils = {}

function utils.clamp(value, min, max)
    return math.max(min, math.min(value, max))
end

function utils.calculateAirPressure(height)
    local offset = math.exp(-1.3333333333333333) -- Precomputed constant
    local base_altitude, decay_rate = 64.0, 192.0
    local pressure = (math.exp(-(height - base_altitude) / decay_rate) - offset) / (1.0 - offset)
    return utils.clamp(pressure, 0.0, 1.0)
end

function utils.formatForce(newtons)
    if type(newtons) ~= "number" then return "Invalid input: force must be a number." end
    if newtons == 0 then return "0 N" end
    local absNewtons = math.abs(newtons)
    local suffix, formattedForce = "N", newtons
    if absNewtons >= 1e9 then
        formattedForce, suffix = newtons / 1e9, "GN"
    elseif absNewtons >= 1e6 then
        formattedForce, suffix = newtons / 1e6, "MN"
    elseif absNewtons >= 1e3 then
        formattedForce, suffix = newtons / 1e3, "kN"
    elseif absNewtons < 1e-3 then
        formattedForce, suffix = newtons * 1e3, "mN"
    end
    return string.format("%.2f %s", formattedForce, suffix)
end

return utils