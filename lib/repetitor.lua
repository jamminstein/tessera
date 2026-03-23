-- repetitor.lua
-- 4-channel algorithmic trigger generator
-- inspired by Noise Engineering Multi Repetitor
--
-- modes: euclidean, fibonacci, prime, golden ratio, + traditional patterns
-- per-channel: steps, pulses, offset, accent generation

local Repetitor = {}
Repetitor.__index = Repetitor

----------------------------------------------------------------
-- bjorklund algorithm for euclidean patterns
----------------------------------------------------------------

local function bjorklund(steps, pulses)
  if pulses >= steps then
    local p = {}
    for i = 1, steps do p[i] = 1 end
    return p
  end
  if pulses == 0 then
    local p = {}
    for i = 1, steps do p[i] = 0 end
    return p
  end

  local pattern = {}
  local counts = {}
  local remainders = {}
  local level = 0

  remainders[0] = pulses
  local divisor = steps - pulses

  repeat
    counts[level] = math.floor(divisor / remainders[level])
    local newR = divisor % remainders[level]
    divisor = remainders[level]
    remainders[level + 1] = newR
    level = level + 1
  until remainders[level] <= 1

  counts[level] = divisor

  local function build(lev)
    if lev == -1 then
      pattern[#pattern + 1] = 0
    elseif lev == -2 then
      pattern[#pattern + 1] = 1
    else
      for _ = 1, counts[lev] do
        build(lev - 1)
      end
      if remainders[lev] > 0 then
        build(lev - 2)
      end
    end
  end

  build(level)
  return pattern
end

----------------------------------------------------------------
-- mathematical pattern generators
----------------------------------------------------------------

local function fibonacci_pattern(steps)
  local p = {}
  for i = 1, steps do p[i] = 0 end
  local a, b = 1, 1
  while a <= steps do
    p[a] = 1
    a, b = b, a + b
  end
  return p
end

local function prime_pattern(steps)
  local p = {}
  for i = 1, steps do p[i] = 0 end
  for i = 2, steps do
    local is_prime = true
    for j = 2, math.floor(math.sqrt(i)) do
      if i % j == 0 then is_prime = false; break end
    end
    if is_prime then p[i] = 1 end
  end
  return p
end

local function golden_pattern(steps)
  local p = {}
  for i = 1, steps do p[i] = 0 end
  local phi = (1 + math.sqrt(5)) / 2
  local pos = 0
  while pos < steps do
    pos = pos + phi
    local idx = math.floor(pos)
    if idx >= 1 and idx <= steps then p[idx] = 1 end
  end
  return p
end

----------------------------------------------------------------
-- traditional drum patterns (16-step)
----------------------------------------------------------------

local TRADITIONAL = {
  {name = "4floor", pattern = {1,0,0,0, 1,0,0,0, 1,0,0,0, 1,0,0,0}},
  {name = "backbt", pattern = {0,0,0,0, 1,0,0,0, 0,0,0,0, 1,0,0,0}},
  {name = "clave",  pattern = {1,0,0,1, 0,0,1,0, 0,0,1,0, 1,0,0,0}},
  {name = "tresl",  pattern = {1,0,0,1, 0,0,1,0, 0,0,0,0, 0,0,0,0}},
  {name = "bomba",  pattern = {1,0,0,0, 0,0,1,0, 0,0,1,0, 0,0,0,0}},
  {name = "shuff",  pattern = {1,0,0,1, 0,0,1,0, 0,1,0,0, 1,0,1,0}},
  {name = "halft",  pattern = {1,0,0,0, 0,0,0,0, 1,0,0,0, 0,0,0,0}},
  {name = "8ths",   pattern = {1,0,1,0, 1,0,1,0, 1,0,1,0, 1,0,1,0}},
}

----------------------------------------------------------------
-- accent generation
-- downbeats get full accent, other hits get softer accents
----------------------------------------------------------------

local function generate_accents(pattern)
  local accents = {}
  for i = 1, #pattern do
    if pattern[i] == 1 then
      -- downbeat positions (1, 5, 9, 13) get full accent
      accents[i] = ((i - 1) % 4 == 0) and 1.0 or 0.65
    else
      accents[i] = 0
    end
  end
  return accents
end

----------------------------------------------------------------
-- module
----------------------------------------------------------------

function Repetitor.new()
  local self = setmetatable({}, Repetitor)
  self.channels = {}
  for i = 1, 4 do
    self.channels[i] = {
      mode = 1,       -- 1=euclidean 2=fib 3=prime 4=golden 5+=traditional
      steps = 16,
      pulses = 4,
      offset = 0,
      pattern = {},
      accents = {},
      position = 0,
      muted = false,
    }
  end
  -- set varied defaults
  self.channels[1].pulses = 4
  self.channels[2].mode = 2   -- fibonacci
  self.channels[3].pulses = 3
  self.channels[4].mode = 4   -- golden
  self.channels[4].pulses = 5

  for i = 1, 4 do self:regenerate(i) end
  return self
end

function Repetitor:regenerate(ch)
  local c = self.channels[ch]
  local raw

  if c.mode == 1 then
    raw = bjorklund(c.steps, c.pulses)
  elseif c.mode == 2 then
    raw = fibonacci_pattern(c.steps)
  elseif c.mode == 3 then
    raw = prime_pattern(c.steps)
  elseif c.mode == 4 then
    raw = golden_pattern(c.steps)
  else
    -- traditional pattern
    local tidx = c.mode - 4
    if tidx >= 1 and tidx <= #TRADITIONAL then
      raw = {}
      local src = TRADITIONAL[tidx].pattern
      for i = 1, c.steps do
        raw[i] = src[((i - 1) % #src) + 1]
      end
    else
      raw = bjorklund(c.steps, c.pulses)
    end
  end

  -- apply rotation offset
  if c.offset ~= 0 then
    local rotated = {}
    for i = 1, #raw do
      rotated[i] = raw[((i - 1 + c.offset) % #raw) + 1]
    end
    raw = rotated
  end

  c.pattern = raw
  c.accents = generate_accents(raw)
end

-- advance one step, return (hit, accent)
function Repetitor:advance(ch)
  local c = self.channels[ch]
  c.position = (c.position % c.steps) + 1
  if c.muted then return false, 0 end
  local hit = c.pattern[c.position] == 1
  local accent = c.accents[c.position] or 0.65
  return hit, accent
end

function Repetitor:reset(ch)
  if ch then
    self.channels[ch].position = 0
  else
    for i = 1, 4 do self.channels[i].position = 0 end
  end
end

function Repetitor:get_mode_name(ch)
  local mode = self.channels[ch].mode
  if mode == 1 then return "EUCL"
  elseif mode == 2 then return "FIB"
  elseif mode == 3 then return "PRIM"
  elseif mode == 4 then return "GOLD"
  else
    local tidx = mode - 4
    if tidx >= 1 and tidx <= #TRADITIONAL then
      return TRADITIONAL[tidx].name:upper()
    end
    return "????"
  end
end

function Repetitor:get_num_modes()
  return 4 + #TRADITIONAL
end

return Repetitor
