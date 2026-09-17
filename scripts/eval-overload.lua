-- Evaluate the overload selector against a real corpus.
--
-- Answers three questions, in the order they actually bite:
--   1. Coverage.  How many corpus entries even reach a choice?  An entry with
--      0 or 1 candidates is a *parser* problem; no selector can fix it.
--   2. Agreement.  Where there is a real choice, does Jev agree with the
--      deterministic heuristic, and where does it differ?
--   3. Threshold.  What does the confidence distribution look like, so
--      `min_confidence` comes from your data instead of from a docs example?
--
-- Usage:
--   mkdir -p corpus && …harvest messages into corpus/*.txt…
--   TYPESAFE_API_KEY=sk-… nvim --headless --noplugin \
--     -u tests/minimal_init.lua -c "luafile scripts/eval-overload.lua" -c q
--
-- With no key it still runs and reports coverage only, which is the half that
-- finds bugs.

local parse = require("effect-error-pretty.parse")
local typesafe = require("effect-error-pretty.typesafe")

local CORPUS = vim.env.CORPUS or "corpus"
local TIMEOUT_MS = 20000

local function read_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

-- Ask Jev for one entry and block until it answers.  Sequential on purpose: an
-- eval run is not latency sensitive, and serial output is far easier to read.
local function ask(msg, candidates)
  local body = typesafe.build_request({ diagnostic = msg }, { overload = typesafe.overload_question(candidates) })
  local done, answer = false, nil
  typesafe.request(body, function(decoded)
    answer = decoded and decoded.answers and decoded.answers.overload
    done = true
  end)
  vim.wait(TIMEOUT_MS, function()
    return done
  end, 50)
  return answer
end

local files = vim.fn.glob(CORPUS .. "/*.txt", false, true)
if #files == 0 then
  print("No corpus found at " .. CORPUS .. "/*.txt")
  return
end

typesafe.setup({ enabled = true })
local keyed = typesafe.available()
print(("Corpus: %d entries from %s/  (Jev: %s)\n"):format(#files, CORPUS, keyed and "on" or "off, coverage only"))

local stats = { skipped = 0, none = 0, single = 0, choosable = 0, agree = 0, differ = 0, declined = 0, failed = 0 }
local confidences = {}
local disagreements = {}

for _, path in ipairs(files) do
  local msg = read_file(path)
  local name = vim.fn.fnamemodify(path, ":t")
  if msg then
    local candidates = parse.candidate_reports(msg)
    -- A message that is not TS2769 at all has no overloads to choose between,
    -- so it is not evidence of a parser gap.  Separating the two keeps the
    -- "no candidates" number meaning only the thing worth investigating.
    local is_overload = msg:find("No overload matches this call", 1, true) ~= nil

    if not is_overload then
      stats.skipped = stats.skipped + 1
      print(("  %-28s  not a TS2769, skipped"):format(name))
    elseif #candidates == 0 then
      stats.none = stats.none + 1
      print(("  %-28s  NO CANDIDATES      <- parser gap, selector never runs"):format(name))
    elseif #candidates == 1 then
      stats.single = stats.single + 1
      print(("  %-28s  1 candidate        <- nothing to choose"):format(name))
    else
      stats.choosable = stats.choosable + 1
      local heuristic = parse.heuristic_index(candidates)

      if not keyed then
        print(("  %-28s  %d candidates, heuristic -> #%d"):format(name, #candidates, heuristic))
      else
        local answer = ask(msg, candidates)
        if not answer then
          stats.failed = stats.failed + 1
          print(("  %-28s  REQUEST FAILED"):format(name))
        elseif answer.choice == "none" then
          stats.declined = stats.declined + 1
          print(("  %-28s  Jev declined (conf %.2f)"):format(name, answer.confidence or 0))
        else
          local jev = tonumber(answer.choice)
          local conf = answer.confidence or 0
          table.insert(confidences, conf)
          if jev == heuristic then
            stats.agree = stats.agree + 1
            print(("  %-28s  agree   -> #%d   conf %.2f"):format(name, heuristic, conf))
          else
            stats.differ = stats.differ + 1
            print(("  %-28s  DIFFER  heuristic #%s vs Jev #%s   conf %.2f"):format(name, heuristic, jev, conf))
            table.insert(disagreements, {
              name = name,
              conf = conf,
              heuristic = candidates[heuristic] and candidates[heuristic].body or "?",
              jev = candidates[jev] and candidates[jev].body or "?",
            })
          end
        end
      end
    end
  end
end

print("\n── Coverage " .. string.rep("─", 50))
print(("  not TS2769    : %d   <- ignored, nothing to select"):format(stats.skipped))
print(("  no candidates : %d   <- fix the parser, not the prompt"):format(stats.none))
print(("  one candidate : %d   <- selector is a no-op here"):format(stats.single))
print(("  choosable     : %d"):format(stats.choosable))

if keyed then
  print("\n── Selector " .. string.rep("─", 50))
  print(("  agree    : %d"):format(stats.agree))
  print(("  differ   : %d"):format(stats.differ))
  print(("  declined : %d"):format(stats.declined))
  print(("  failed   : %d"):format(stats.failed))

  if #confidences > 0 then
    table.sort(confidences)
    local sum = 0
    for _, c in ipairs(confidences) do
      sum = sum + c
    end
    print("\n── Confidence " .. string.rep("─", 48))
    print(
      ("  min %.2f   median %.2f   mean %.2f   max %.2f"):format(
        confidences[1],
        confidences[math.ceil(#confidences / 2)],
        sum / #confidences,
        confidences[#confidences]
      )
    )
    -- Pick min_confidence from this, not from a docs example.  A threshold is
    -- only useful if it separates the answers you'd accept from the rest.
    for _, bar in ipairs({ 0.5, 0.6, 0.7, 0.8, 0.9 }) do
      local kept = 0
      for _, c in ipairs(confidences) do
        if c >= bar then
          kept = kept + 1
        end
      end
      print(("  >= %.1f : %d/%d answers kept"):format(bar, kept, #confidences))
    end
  end

  if #disagreements > 0 then
    print("\n── Disagreements, label these by hand " .. string.rep("─", 23))
    for _, d in ipairs(disagreements) do
      print(("\n  %s  (conf %.2f)"):format(d.name, d.conf))
      print("    heuristic: " .. d.heuristic:sub(1, 100))
      print("    jev      : " .. d.jev:sub(1, 100))
    end
    print("\n  Jev only earns the integration if it wins most of these.")
  end
end
