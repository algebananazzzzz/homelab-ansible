-- Docker's journald driver sets PRIORITY from stdout or stderr, not from the message, so container lines are left for Loki to detect a level from their text.
local levels = { ["0"] = "critical", ["1"] = "critical", ["2"] = "critical", ["3"] = "error", ["4"] = "warning", ["5"] = "info", ["6"] = "info", ["7"] = "debug" }

function set_level(tag, timestamp, record)
  if record["CONTAINER_NAME"] == nil then
    record["level"] = levels[record["PRIORITY"]]
  end
  return 2, timestamp, record
end
