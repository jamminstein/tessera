-- tessera
-- algorithmic mosaic synth
--
-- multi repetitor rhythms
-- ziggurat pitch chains
-- 4-voice analog-style engine
--
-- E1: page (rhythm/pitch/voice/fx)
-- E2: select channel or param
-- E3: adjust value
-- K2: play/stop
-- K3: hold for secondary
--
-- grid top 4 rows: rhythm steps
-- grid bottom 4 rows: pitch chain

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
local page = 1
local NUM_PAGES = 4
local sel_ch = 1
local sel_param = 1

local screen_dirty = true
local grid_dirty = true

local key3_held = false
local grid_held = nil

local active_notes = {{}, {}, {}, {}}

local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local DIVISIONS = {1/4, 1/8, 1/16, 1/32}
local DIV_NAMES = {"1/4", "1/8", "1/16", "1/32"}

-- voice params for E2/E3 editing on voice page
local VOICE_PARAMS = {
  "saw", "pulse", "sub", "noise",
  "detune", "drive", "cutoff", "res",
  "env_mod", "drift", "decay", "release",
  "amp", "delay_send"
}

-- channel presets — each voice has real character
local CH_PRESETS = {
  -- ch1: bright lead — dual saw, moderate filter, some drive
  {saw=0.7, pulse=0.0, sub=0.0, noise=0.0,
   detune=0.12, drive=0.4, cutoff=3500, res=0.25, env_mod=0.5,
   drift=0.12, decay=0.4, release=0.3, amp=0.28, pan=-0.35, delay_send=0.3},
  -- ch2: fat bass — sub + saw, low cutoff, high drive
  {saw=0.3, pulse=0.0, sub=0.8, noise=0.0,
   detune=0.05, drive=0.7, cutoff=600, res=0.4, env_mod=0.7,
   drift=0.08, decay=0.25, release=0.15, amp=0.35, pan=0.0, delay_send=0.1},
  -- ch3: percussive — pulse + noise, tight envelope, resonant
  {saw=0.0, pulse=0.6, sub=0.0, noise=0.4,
   detune=0.0, drive=0.5, cutoff=2000, res=0.55, env_mod=0.9,
   drift=0.06, decay=0.1, release=0.08, amp=0.25, pan=0.4, delay_send=0.35},
  -- ch4: pad wash — saw + noise, long decay, drifty
  {saw=0.4, pulse=0.0, sub=0.2, noise=0.5,
   detune=0.2, drive=0.2, cutoff=2500, res=0.15, env_mod=0.2,
   drift=0.3, decay=1.5, release=1.0, amp=0.18, pan=-0.2, delay_send=0.45},
}

local CH_LABELS = {"LEAD", "BASS", "PERC", "WASH"}

----------------------------------------------------------------
-- init
----------------------------------------------------------------

function init()
  rep = Repetitor.new()
  zig = Ziggurat.new()

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

  -- per-channel voice params
  for ch = 1, 4 do
    local pre = CH_PRESETS[ch]
    params:add_separator("CH " .. ch .. " " .. CH_LABELS[ch])

    params:add_control("ch" .. ch .. "_saw", "saw",
      controlspec.new(0, 1, 'lin', 0.01, pre.saw))
    params:set_action("ch" .. ch .. "_saw", function(v) engine.saw(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_pulse", "pulse",
      controlspec.new(0, 1, 'lin', 0.01, pre.pulse))
    params:set_action("ch" .. ch .. "_pulse", function(v) engine.pulse(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_sub", "sub",
      controlspec.new(0, 1, 'lin', 0.01, pre.sub))
    params:set_action("ch" .. ch .. "_sub", function(v) engine.sub(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_noise", "noise",
      controlspec.new(0, 1, 'lin', 0.01, pre.noise))
    params:set_action("ch" .. ch .. "_noise", function(v) engine.noise(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_detune", "detune",
      controlspec.new(0, 1, 'lin', 0.01, pre.detune))
    params:set_action("ch" .. ch .. "_detune", function(v) engine.detune(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_drive", "drive",
      controlspec.new(0, 2, 'lin', 0.01, pre.drive))
    params:set_action("ch" .. ch .. "_drive", function(v) engine.drive(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_cutoff", "cutoff",
      controlspec.new(60, 12000, 'exp', 1, pre.cutoff, "hz"))
    params:set_action("ch" .. ch .. "_cutoff", function(v) engine.cutoff(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_res", "resonance",
      controlspec.new(0, 0.95, 'lin', 0.01, pre.res))
    params:set_action("ch" .. ch .. "_res", function(v) engine.res(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_env_mod", "env > cutoff",
      controlspec.new(0, 1, 'lin', 0.01, pre.env_mod))
    params:set_action("ch" .. ch .. "_env_mod", function(v) engine.env_mod(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_drift", "drift",
      controlspec.new(0, 1, 'lin', 0.01, pre.drift))
    params:set_action("ch" .. ch .. "_drift", function(v) engine.drift(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_decay", "decay",
      controlspec.new(0.01, 4, 'exp', 0.01, pre.decay, "s"))
    params:set_action("ch" .. ch .. "_decay", function(v) engine.dec(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_release", "release",
      controlspec.new(0.01, 4, 'exp', 0.01, pre.release, "s"))
    params:set_action("ch" .. ch .. "_release", function(v) engine.rel(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_amp", "amp",
      controlspec.new(0, 1, 'lin', 0.01, pre.amp))
    params:set_action("ch" .. ch .. "_amp", function(v) engine.amp(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_delay_send", "delay send",
      controlspec.new(0, 1, 'lin', 0.01, pre.delay_send))
    params:set_action("ch" .. ch .. "_delay_send", function(v) engine.delay_send(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_pan", "pan",
      controlspec.new(-1, 1, 'lin', 0.01, pre.pan))
    params:set_action("ch" .. ch .. "_pan", function(v) engine.pan(ch - 1, v) end)
  end

  -- FX
  params:add_separator("FX")

  params:add_control("delay_time", "delay time",
    controlspec.new(0.01, 2.0, 'exp', 0.01, 0.375, "s"))
  params:set_action("delay_time", function(v) engine.delay_time(v) end)

  params:add_control("delay_feedback", "delay fb",
    controlspec.new(0, 0.9, 'lin', 0.01, 0.45))
  params:set_action("delay_feedback", function(v) engine.delay_feedback(v) end)

  params:add_control("delay_color", "delay color",
    controlspec.new(200, 12000, 'exp', 1, 3500, "hz"))
  params:set_action("delay_color", function(v) engine.delay_color(v) end)

  params:add_control("delay_mix", "delay mix",
    controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("delay_mix", function(v) engine.delay_mix(v) end)

  params:add_control("halo", "halo",
    controlspec.new(0, 1, 'lin', 0.01, 0.25))
  params:set_action("halo", function(v) engine.halo(v) end)

  params:add_control("reverb_mix", "reverb mix",
    controlspec.new(0, 1, 'lin', 0.01, 0.2))
  params:set_action("reverb_mix", function(v) engine.reverb_mix(v) end)

  params:add_control("reverb_size", "reverb size",
    controlspec.new(0, 1, 'lin', 0.01, 0.8))
  params:set_action("reverb_size", function(v) engine.reverb_size(v) end)

  -- MIDI
  params:add_separator("MIDI")
  params:add_number("midi_device", "midi device", 1, 4, 1)
  params:set_action("midi_device", function(v) midi_out = midi.connect(v) end)
  for ch = 1, 4 do
    params:add_number("midi_ch_" .. ch, "ch " .. ch .. " midi ch", 1, 16, ch)
  end
  params:add_option("midi_enabled", "midi out", {"off", "on"}, 1)

  midi_out = midi.connect(params:get("midi_device"))
  params:bang()

  clock.run(step_clock)

  clock.run(function()
    while true do
      clock.sleep(1/15)
      if screen_dirty then redraw(); screen_dirty = false end
      if grid_dirty then grid_redraw(); grid_dirty = false end
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

          engine.slew(ch - 1, slew)
          engine.hz(ch - 1, freq)
          engine.accent(ch - 1, accent)
          engine.gate(ch - 1, 1)

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
-- encoders
----------------------------------------------------------------

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, NUM_PAGES)
    sel_param = 1
  elseif n == 2 then
    if page == 3 then
      sel_param = util.clamp(sel_param + d, 1, #VOICE_PARAMS)
    elseif page == 4 then
      sel_param = util.clamp(sel_param + d, 1, 7)
    else
      sel_ch = util.clamp(sel_ch + d, 1, 4)
    end
  elseif n == 3 then
    if grid_held then
      local c = zig.channels[grid_held.ch]
      local cur = c.chain[grid_held.step] or 60
      local new = util.clamp(cur + d, c.range_lo, c.range_hi)
      new = zig:quantize(new)
      c.chain[grid_held.step] = new
    elseif page == 1 then enc_rhythm(d)
    elseif page == 2 then enc_pitch(d)
    elseif page == 3 then enc_voice(d)
    elseif page == 4 then enc_fx(d)
    end
  end
  screen_dirty = true
  grid_dirty = true
end

function enc_rhythm(d)
  local c = rep.channels[sel_ch]
  if key3_held then
    if c.mode == 1 then
      c.pulses = util.clamp(c.pulses + d, 0, c.steps)
    else
      c.offset = (c.offset + d) % c.steps
    end
  else
    c.mode = util.clamp(c.mode + d, 1, rep:get_num_modes())
  end
  rep:regenerate(sel_ch)
end

function enc_pitch(d)
  local c = zig.channels[sel_ch]
  if key3_held then
    zig:set_chain_length(sel_ch, c.chain_len + d)
  else
    c.advance_mode = util.clamp(c.advance_mode + d, 1, zig:get_num_modes())
  end
end

function enc_voice(d)
  local pname = VOICE_PARAMS[sel_param]
  local pkey = "ch" .. sel_ch .. "_" .. pname
  if params.lookup[pkey] then params:delta(pkey, d) end
end

local FX_PARAMS = {"delay_time", "delay_feedback", "delay_color", "delay_mix",
                    "halo", "reverb_mix", "reverb_size"}

function enc_fx(d)
  local pkey = FX_PARAMS[sel_param]
  if pkey and params.lookup[pkey] then params:delta(pkey, d) end
end

----------------------------------------------------------------
-- keys
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

local PAGE_NAMES = {"RHYTHM", "PITCH", "VOICE", "FX"}

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

  for i = 1, NUM_PAGES do
    screen.level(i == page and 15 or 3)
    screen.rect(55 + (i-1)*5, 3, 3, 3)
    screen.fill()
  end

  screen.level(2)
  screen.move(1, 9)
  screen.line(128, 9)
  screen.stroke()

  if page == 1 then draw_rhythm()
  elseif page == 2 then draw_pitch()
  elseif page == 3 then draw_voice()
  elseif page == 4 then draw_fx()
  end

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

    screen.level(is_sel and 15 or 4)
    screen.move(1, y + 7)
    screen.text(ch)

    local x0 = 10
    local w = math.floor(78 / c.steps)
    for i = 1, c.steps do
      local x = x0 + (i - 1) * w
      local is_play = (i == c.position and playing)
      if c.pattern[i] == 1 then
        screen.level(is_play and 15 or (is_sel and 10 or 5))
        screen.rect(x, y + 1, w - 1, 6)
        screen.fill()
      elseif is_play then
        screen.level(4)
        screen.rect(x, y + 1, w - 1, 6)
        screen.fill()
      end
    end

    screen.level(is_sel and 12 or 4)
    screen.move(92, y + 7)
    screen.text(rep:get_mode_name(ch))
  end
end

function draw_pitch()
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

    local x = 10
    for i = 1, c.chain_len do
      local note = c.chain[i] or 60
      local name = musicutil.note_num_to_name(note, true)
      screen.level((i == c.position and playing) and 15 or (is_sel and 7 or 3))
      screen.move(x, y + 7)
      screen.text(name)
      x = x + screen.text_extents(name) + 2
      if x > 95 then screen.text(".."); break end
    end

    screen.level(is_sel and 10 or 4)
    screen.move(116, y + 7)
    screen.text_right(zig:get_mode_name(ch))
  end
end

function draw_voice()
  screen.level(12)
  screen.move(50, 7)
  screen.text_right("CH" .. sel_ch .. " " .. CH_LABELS[sel_ch])

  -- mixer bars for osc levels
  local bar_y = 14
  local sources = {"saw", "pulse", "sub", "noise"}
  for i, src in ipairs(sources) do
    local v = params:get("ch" .. sel_ch .. "_" .. src)
    local x = 2 + (i - 1) * 32
    local is_sel = sel_param == i

    screen.level(is_sel and 15 or 6)
    screen.move(x, bar_y + 7)
    screen.text(src:sub(1, 3))

    -- bar
    local bw = math.floor(v * 24)
    screen.level(is_sel and 12 or 5)
    screen.rect(x, bar_y + 9, bw, 3)
    screen.fill()
    screen.level(2)
    screen.rect(x, bar_y + 9, 24, 3)
    screen.stroke()
  end

  -- filter viz
  local cut = params:get("ch" .. sel_ch .. "_cutoff")
  local r = params:get("ch" .. sel_ch .. "_res")
  local cut_x = util.linlin(60, 12000, 4, 124, math.log(cut))
  screen.level(8)
  screen.move(4, 42)
  for x = 4, 124 do
    local f = util.linexp(4, 124, 60, 12000, x)
    local gain = 1 / (1 + ((f / cut) ^ 4))
    if math.abs(f - cut) < cut * 0.15 then
      gain = gain * (1 + r * 3)
    end
    local y = 42 - math.floor(gain * 12)
    screen.line(x, y)
  end
  screen.level(6)
  screen.stroke()

  -- selected param readout
  screen.level(10)
  screen.move(1, 60)
  local pname = VOICE_PARAMS[sel_param]
  local pkey = "ch" .. sel_ch .. "_" .. pname
  if params.lookup[pkey] then
    screen.text(pname:gsub("_", " ") .. ": " .. params:string(pkey))
  end
end

function draw_fx()
  local y = 14
  for i, pkey in ipairs(FX_PARAMS) do
    local is_sel = i == sel_param
    screen.level(is_sel and 15 or 5)
    screen.move(3, y + (i - 1) * 7)
    screen.text(pkey:gsub("_", " "))

    screen.level(is_sel and 12 or 4)
    screen.move(126, y + (i - 1) * 7)
    screen.text_right(params:string(pkey))
  end
end

----------------------------------------------------------------
-- grid
----------------------------------------------------------------

g.key = function(x, y, z)
  if y >= 1 and y <= 4 then
    if z == 1 then
      local ch = y
      local c = rep.channels[ch]
      if x >= 1 and x <= c.steps then
        c.pattern[x] = c.pattern[x] == 1 and 0 or 1
        if c.pattern[x] == 1 then
          c.accents[x] = ((x - 1) % 4 == 0) and 1.0 or 0.65
        else
          c.accents[x] = 0
        end
      end
      sel_ch = ch; page = 1
    end
  elseif y >= 5 and y <= 8 then
    local ch = y - 4
    local c = zig.channels[ch]
    if z == 1 then
      if x >= 1 and x <= c.chain_len then
        grid_held = {ch = ch, step = x}
        sel_ch = ch; page = 2
      elseif x == c.chain_len + 1 and c.chain_len < 16 then
        zig:set_chain_length(ch, c.chain_len + 1)
        sel_ch = ch; page = 2
      end
    else
      if grid_held and grid_held.ch == ch then grid_held = nil end
    end
  end
  screen_dirty = true; grid_dirty = true
end

function grid_redraw()
  g:all(0)
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
  for ch = 1, 4 do
    local c = zig.channels[ch]
    for x = 1, math.min(c.chain_len, 16) do
      local bright = 4
      if x == c.position and playing then bright = 15
      elseif grid_held and grid_held.ch == ch and grid_held.step == x then bright = 12
      else
        local note = c.chain[x] or 60
        bright = math.floor(util.linlin(24, 96, 3, 10, note))
      end
      g:led(x, ch + 4, bright)
    end
    if c.chain_len < 16 then g:led(c.chain_len + 1, ch + 4, 2) end
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
