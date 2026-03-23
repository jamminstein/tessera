-- tessera
-- algorithmic spectral mosaic
--
-- multi repetitor rhythms
-- ziggurat pitch chains
-- spectraphon resynthesis
-- mimeophon halo delay
--
-- E1: page (rhythm/pitch/spectral)
-- E2: select channel
-- E3: adjust value
-- K2: play/stop
-- K3: hold + E3 for secondary param
--     tap on spectral page = freeze
--
-- grid top 4 rows: rhythm steps
-- grid bottom 4 rows: pitch chain
-- hold grid key + E3 = edit pitch

engine.name = "Tessera"

local musicutil = require "musicutil"
local Repetitor = include "lib/repetitor"
local Ziggurat = include "lib/ziggurat"

----------------------------------------------------------------
-- state
----------------------------------------------------------------

local rep = nil
local zig = nil
local g = grid.connect()
local midi_out = nil

local playing = false
local page = 1           -- 1=rhythm  2=pitch  3=spectral
local sel_ch = 1         -- selected channel 1-4
local sel_param = 1      -- selected param within page

local screen_dirty = true
local grid_dirty = true

local key3_held = false
local grid_held = nil    -- {ch=, step=} when holding a pitch grid key

local engine_freeze = {0, 0, 0, 0}
local engine_smear = {0.5, 0.5, 0.5, 0.5}
local active_notes = {{}, {}, {}, {}}

local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local DIVISIONS = {1/4, 1/8, 1/16, 1/32}
local DIV_NAMES = {"1/4", "1/8", "1/16", "1/32"}

local SPECTRAL_PARAMS = {"partials", "tilt", "spread", "filter", "filter_q", "decay", "delay_send"}

----------------------------------------------------------------
-- init
----------------------------------------------------------------

function init()
  rep = Repetitor.new()
  zig = Ziggurat.new()

  -- global params
  params:add_separator("TESSERA")

  params:add_number("bpm", "BPM", 20, 300, 120)
  params:set_action("bpm", function(v) params:set("clock_tempo", v) end)

  params:add_option("division", "division", DIV_NAMES, 3)

  params:add_option("root", "root note", NOTE_NAMES, 1)
  params:set_action("root", function(v)
    zig:set_scale(v - 1, params:get("scale"))
  end)

  local scale_names = {}
  for i = 1, #musicutil.SCALES do
    scale_names[i] = musicutil.SCALES[i].name
  end
  params:add_option("scale", "scale", scale_names, 1)
  params:set_action("scale", function(v)
    zig:set_scale(params:get("root") - 1, v)
  end)

  -- per-channel engine params
  for ch = 1, 4 do
    params:add_separator("CH " .. ch)

    params:add_number("ch" .. ch .. "_partials", "partials", 1, 16, 5 + ch)
    params:set_action("ch" .. ch .. "_partials", function(v)
      engine.partials(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_tilt", "tilt",
      controlspec.new(0, 3, 'lin', 0.01, 0.5))
    params:set_action("ch" .. ch .. "_tilt", function(v)
      engine.tilt(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_spread", "spread",
      controlspec.new(0, 0.1, 'lin', 0.001, 0.008))
    params:set_action("ch" .. ch .. "_spread", function(v)
      engine.spread(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_filter", "filter",
      controlspec.new(100, 12000, 'exp', 1, 2000 + ch * 500, "hz"))
    params:set_action("ch" .. ch .. "_filter", function(v)
      engine.filter_freq(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_filter_q", "filter q",
      controlspec.new(0.05, 1, 'lin', 0.01, 0.4))
    params:set_action("ch" .. ch .. "_filter_q", function(v)
      engine.filter_q(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_amp", "amp",
      controlspec.new(0, 1, 'lin', 0.01, 0.35))
    params:set_action("ch" .. ch .. "_amp", function(v)
      engine.amp(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_decay", "decay",
      controlspec.new(0.05, 4, 'exp', 0.01, 0.5 + ch * 0.15, "s"))
    params:set_action("ch" .. ch .. "_decay", function(v)
      engine.dec(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_delay_send", "delay send",
      controlspec.new(0, 1, 'lin', 0.01, 0.25))
    params:set_action("ch" .. ch .. "_delay_send", function(v)
      engine.delay_send(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_pan", "pan",
      controlspec.new(-1, 1, 'lin', 0.01, (ch - 2.5) / 3))
    params:set_action("ch" .. ch .. "_pan", function(v)
      engine.pan(ch - 1, v)
    end)
  end

  -- FX
  params:add_separator("FX")

  params:add_control("delay_time", "delay time",
    controlspec.new(0.01, 2.0, 'exp', 0.01, 0.3, "s"))
  params:set_action("delay_time", function(v) engine.delay_time(v) end)

  params:add_control("delay_feedback", "delay fb",
    controlspec.new(0, 0.95, 'lin', 0.01, 0.5))
  params:set_action("delay_feedback", function(v) engine.delay_feedback(v) end)

  params:add_control("delay_color", "delay color",
    controlspec.new(200, 12000, 'exp', 1, 4000, "hz"))
  params:set_action("delay_color", function(v) engine.delay_color(v) end)

  params:add_control("delay_mix", "delay mix",
    controlspec.new(0, 1, 'lin', 0.01, 0.35))
  params:set_action("delay_mix", function(v) engine.delay_mix(v) end)

  params:add_control("halo", "halo",
    controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("halo", function(v) engine.halo(v) end)

  params:add_control("reverb_mix", "reverb mix",
    controlspec.new(0, 1, 'lin', 0.01, 0.25))
  params:set_action("reverb_mix", function(v) engine.reverb_mix(v) end)

  params:add_control("reverb_size", "reverb size",
    controlspec.new(0, 1, 'lin', 0.01, 0.85))
  params:set_action("reverb_size", function(v) engine.reverb_size(v) end)

  -- MIDI
  params:add_separator("MIDI")
  params:add_number("midi_device", "midi device", 1, 4, 1)
  params:set_action("midi_device", function(v)
    midi_out = midi.connect(v)
  end)
  for ch = 1, 4 do
    params:add_number("midi_ch_" .. ch, "ch " .. ch .. " midi ch", 1, 16, ch)
  end
  params:add_option("midi_enabled", "midi out", {"off", "on"}, 1)

  midi_out = midi.connect(params:get("midi_device"))

  -- bang all params to engine
  params:bang()

  -- sequencer clock
  clock.run(step_clock)

  -- screen refresh
  clock.run(function()
    while true do
      clock.sleep(1/15)
      if screen_dirty then
        redraw()
        screen_dirty = false
      end
      if grid_dirty then
        grid_redraw()
        grid_dirty = false
      end
    end
  end)
end

----------------------------------------------------------------
-- sequencer
----------------------------------------------------------------

function step_clock()
  while true do
    clock.sync(DIVISIONS[params:get("division")])
    if playing then
      for ch = 1, 4 do
        local hit, accent = rep:advance(ch)
        if hit then
          local note = zig:advance(ch)
          local freq = musicutil.note_num_to_freq(note)
          local slew = zig.channels[ch].slew

          -- internal engine
          engine.slew(ch - 1, slew)
          engine.hz(ch - 1, freq)
          engine.accent(ch - 1, accent)
          engine.gate(ch - 1, 1)

          -- MIDI out
          if params:get("midi_enabled") == 2 and midi_out then
            local midi_ch = params:get("midi_ch_" .. ch)
            for _, n in ipairs(active_notes[ch]) do
              midi_out:note_off(n, 0, midi_ch)
            end
            local vel = util.clamp(math.floor(accent * 127), 1, 127)
            midi_out:note_on(note, vel, midi_ch)
            active_notes[ch] = {note}
          end
        end
      end
      screen_dirty = true
      grid_dirty = true
    end
  end
end

----------------------------------------------------------------
-- input: encoders
----------------------------------------------------------------

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, 3)
    sel_param = 1

  elseif n == 2 then
    if page == 3 then
      sel_param = util.clamp(sel_param + d, 1, #SPECTRAL_PARAMS)
    else
      sel_ch = util.clamp(sel_ch + d, 1, 4)
    end

  elseif n == 3 then
    -- if holding a grid pitch key, edit that note
    if grid_held then
      local c = zig.channels[grid_held.ch]
      local cur = c.chain[grid_held.step] or 60
      local new = util.clamp(cur + d, c.range_lo, c.range_hi)
      new = zig:quantize(new)
      c.chain[grid_held.step] = new
    elseif page == 1 then
      enc_rhythm(d)
    elseif page == 2 then
      enc_pitch(d)
    elseif page == 3 then
      enc_spectral(d)
    end
  end

  screen_dirty = true
  grid_dirty = true
end

function enc_rhythm(d)
  local c = rep.channels[sel_ch]
  if key3_held then
    -- secondary: adjust pulses (euclidean) or offset
    if c.mode == 1 then
      c.pulses = util.clamp(c.pulses + d, 0, c.steps)
    else
      c.offset = (c.offset + d) % c.steps
    end
  else
    -- primary: cycle rhythm mode
    c.mode = util.clamp(c.mode + d, 1, rep:get_num_modes())
  end
  rep:regenerate(sel_ch)
end

function enc_pitch(d)
  local c = zig.channels[sel_ch]
  if key3_held then
    -- secondary: adjust chain length
    zig:set_chain_length(sel_ch, c.chain_len + d)
  else
    -- primary: cycle advance mode
    c.advance_mode = util.clamp(c.advance_mode + d, 1, zig:get_num_modes())
  end
end

function enc_spectral(d)
  local pname = SPECTRAL_PARAMS[sel_param]
  local pkey = "ch" .. sel_ch .. "_" .. pname
  if params.lookup[pkey] then
    params:delta(pkey, d)
  end
end

----------------------------------------------------------------
-- input: keys
----------------------------------------------------------------

function key(n, z)
  if n == 2 and z == 1 then
    if playing then
      playing = false
      all_notes_off()
      rep:reset()
      zig:reset()
    else
      playing = true
    end

  elseif n == 3 then
    key3_held = z == 1
    if z == 1 and page == 3 then
      -- toggle freeze on selected channel
      engine_freeze[sel_ch] = engine_freeze[sel_ch] == 0 and 1 or 0
      engine.freeze(sel_ch - 1, engine_freeze[sel_ch])
    end
  end
  screen_dirty = true
end

function all_notes_off()
  for ch = 1, 4 do
    engine.gate(ch - 1, 0)
    if midi_out then
      local midi_ch = params:get("midi_ch_" .. ch)
      for _, note in ipairs(active_notes[ch]) do
        midi_out:note_off(note, 0, midi_ch)
      end
      active_notes[ch] = {}
    end
  end
end

----------------------------------------------------------------
-- screen
----------------------------------------------------------------

local PAGE_NAMES = {"RHYTHM", "PITCH", "SPECTRAL"}

function redraw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)

  -- header
  screen.level(playing and 15 or 5)
  screen.move(1, 7)
  screen.text("TESSERA")
  screen.level(8)
  screen.move(128, 7)
  screen.text_right(PAGE_NAMES[page])

  -- divider
  screen.level(2)
  screen.move(1, 9)
  screen.line(128, 9)
  screen.stroke()

  if page == 1 then draw_rhythm()
  elseif page == 2 then draw_pitch()
  elseif page == 3 then draw_spectral()
  end

  -- footer
  screen.level(3)
  screen.move(128, 63)
  screen.text_right(params:string("bpm"))

  screen.update()
end

function draw_rhythm()
  for ch = 1, 4 do
    local c = rep.channels[ch]
    local y = 12 + (ch - 1) * 12
    local is_sel = ch == sel_ch

    -- channel number
    screen.level(is_sel and 15 or 4)
    screen.move(1, y + 7)
    screen.text(ch)

    -- pattern visualization
    local x0 = 10
    local w = math.floor(78 / c.steps)
    for i = 1, c.steps do
      local x = x0 + (i - 1) * w
      local is_play = (i == c.position and playing)
      if c.pattern[i] == 1 then
        screen.level(is_play and 15 or (is_sel and 10 or 5))
        screen.rect(x, y + 1, w - 1, 6)
        screen.fill()
      else
        if is_play then
          screen.level(4)
          screen.rect(x, y + 1, w - 1, 6)
          screen.fill()
        end
      end
    end

    -- mode + info
    screen.level(is_sel and 12 or 4)
    screen.move(92, y + 7)
    screen.text(rep:get_mode_name(ch))
    if c.mode == 1 then
      screen.level(is_sel and 8 or 3)
      screen.move(116, y + 7)
      screen.text_right(c.pulses)
    end
  end
end

function draw_pitch()
  -- scale info in header area
  local rn = NOTE_NAMES[params:get("root")]
  local sn = musicutil.SCALES[params:get("scale")].name
  screen.level(3)
  screen.move(50, 7)
  screen.text_right(rn .. " " .. string.sub(sn, 1, 8))

  for ch = 1, 4 do
    local c = zig.channels[ch]
    local y = 12 + (ch - 1) * 12
    local is_sel = ch == sel_ch

    screen.level(is_sel and 15 or 4)
    screen.move(1, y + 7)
    screen.text(ch)

    -- note chain
    local x = 10
    for i = 1, c.chain_len do
      local note = c.chain[i] or 60
      local name = musicutil.note_num_to_name(note, true)
      if i == c.position and playing then
        screen.level(15)
      else
        screen.level(is_sel and 7 or 3)
      end
      screen.move(x, y + 7)
      screen.text(name)
      x = x + screen.text_extents(name) + 2
      if x > 95 then
        screen.text("..")
        break
      end
    end

    -- advance mode
    screen.level(is_sel and 10 or 4)
    screen.move(116, y + 7)
    screen.text_right(zig:get_mode_name(ch))
  end
end

function draw_spectral()
  for ch = 1, 4 do
    local y = 12 + (ch - 1) * 11
    local is_sel = ch == sel_ch

    screen.level(is_sel and 15 or 4)
    screen.move(1, y + 7)
    screen.text(ch)

    -- partial amplitude bars
    local np = params:get("ch" .. ch .. "_partials")
    local tilt = params:get("ch" .. ch .. "_tilt")
    for i = 1, 16 do
      local h = 0
      if i <= np then
        h = math.floor(8 / (i ^ (tilt * 0.4)))
        h = math.max(h, 1)
      end
      if h > 0 then
        local x = 10 + (i - 1) * 4
        local bright = is_sel and (engine_freeze[ch] == 1 and 15 or 8) or 3
        screen.level(bright)
        screen.rect(x, y + 9 - h, 3, h)
        screen.fill()
      end
    end

    -- freeze indicator
    if engine_freeze[ch] == 1 then
      screen.level(15)
      screen.move(78, y + 7)
      screen.text("FRZ")
    end

    -- filter position marker
    local filt = params:get("ch" .. ch .. "_filter")
    local pct = math.log(filt / 100) / math.log(120)
    local fx = 95 + math.floor(pct * 30)
    screen.level(is_sel and 8 or 3)
    screen.move(fx, y + 2)
    screen.line(fx, y + 9)
    screen.stroke()
  end

  -- selected param indicator
  screen.level(10)
  screen.move(1, 60)
  screen.text(SPECTRAL_PARAMS[sel_param] .. ": ")
  local pkey = "ch" .. sel_ch .. "_" .. SPECTRAL_PARAMS[sel_param]
  if params.lookup[pkey] then
    screen.text(params:string(pkey))
  end
end

----------------------------------------------------------------
-- grid
----------------------------------------------------------------

g.key = function(x, y, z)
  if y >= 1 and y <= 4 then
    -- rhythm rows: toggle steps
    if z == 1 then
      local ch = y
      local c = rep.channels[ch]
      if x >= 1 and x <= c.steps then
        c.pattern[x] = c.pattern[x] == 1 and 0 or 1
        -- update accent
        if c.pattern[x] == 1 then
          c.accents[x] = ((x - 1) % 4 == 0) and 1.0 or 0.65
        else
          c.accents[x] = 0
        end
      end
      sel_ch = ch
      page = 1
    end

  elseif y >= 5 and y <= 8 then
    -- pitch rows: hold to edit note with E3
    local ch = y - 4
    local c = zig.channels[ch]
    if z == 1 then
      if x >= 1 and x <= c.chain_len then
        grid_held = {ch = ch, step = x}
        sel_ch = ch
        page = 2
      elseif x == c.chain_len + 1 and c.chain_len < 16 then
        -- extend chain
        zig:set_chain_length(ch, c.chain_len + 1)
        sel_ch = ch
        page = 2
      end
    else
      if grid_held and grid_held.ch == ch then
        grid_held = nil
      end
    end
  end

  screen_dirty = true
  grid_dirty = true
end

function grid_redraw()
  g:all(0)

  -- rows 1-4: rhythm patterns
  for ch = 1, 4 do
    local c = rep.channels[ch]
    for x = 1, math.min(c.steps, 16) do
      local bright = 0
      if c.pattern[x] == 1 then
        bright = (x == c.position and playing) and 15 or 8
      else
        bright = (x == c.position and playing) and 4 or 0
      end
      if c.muted then bright = math.floor(bright * 0.3) end
      g:led(x, ch, bright)
    end
  end

  -- rows 5-8: pitch chains
  for ch = 1, 4 do
    local c = zig.channels[ch]
    for x = 1, math.min(c.chain_len, 16) do
      local bright = 4
      if x == c.position and playing then
        bright = 15
      elseif grid_held and grid_held.ch == ch and grid_held.step == x then
        bright = 12
      else
        -- brightness = pitch height
        local note = c.chain[x] or 60
        bright = math.floor(util.linlin(24, 96, 3, 10, note))
      end
      g:led(x, ch + 4, bright)
    end
    -- chain extend position (dim)
    if c.chain_len < 16 then
      g:led(c.chain_len + 1, ch + 4, 2)
    end
  end

  g:refresh()
end

----------------------------------------------------------------
-- cleanup
----------------------------------------------------------------

function cleanup()
  playing = false
  all_notes_off()
end
