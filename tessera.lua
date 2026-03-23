-- tessera
-- algorithmic spectral mosaic
--
-- multi repetitor rhythms
-- ziggurat pitch chains
-- spectral resynthesis + FM
-- wavefolder + sub + noise
--
-- E1: page (rhythm/pitch/spectral/fx)
-- E2: select channel or param
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
local page = 1           -- 1=rhythm  2=pitch  3=spectral  4=fx
local NUM_PAGES = 4
local sel_ch = 1
local sel_param = 1

local screen_dirty = true
local grid_dirty = true

local key3_held = false
local grid_held = nil

local engine_freeze = {0, 0, 0, 0}
local active_notes = {{}, {}, {}, {}}

local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local DIVISIONS = {1/4, 1/8, 1/16, 1/32}
local DIV_NAMES = {"1/4", "1/8", "1/16", "1/32"}
local WAVE_NAMES = {"sine", "saw", "pulse", "noise"}
local FILTER_NAMES = {"lpf", "bpf", "hpf"}

local SPECTRAL_PARAMS = {
  "waveform", "partials", "tilt", "fold",
  "fm_depth", "fm_ratio",
  "sub_amp", "noise_amp",
  "filter", "filter_q", "filter_type", "filter_env",
  "decay", "release", "delay_send"
}

-- channel character presets (applied at init)
local CH_PRESETS = {
  -- ch1: crystalline lead — saw partials, light FM, some fold
  {waveform=1, partials=10, tilt=0.3, fold=0.5, fm_depth=0.15, fm_ratio=2.0,
   sub_amp=0, noise_amp=0, filter=6000, filter_q=0.3, filter_type=0,
   filter_env=0.4, decay=0.5, release=0.4, amp=0.3, pan=-0.4},
  -- ch2: thick bass — sine + sub, low filter
  {waveform=0, partials=4, tilt=1.2, fold=0, fm_depth=0, fm_ratio=1,
   sub_amp=0.6, noise_amp=0, filter=800, filter_q=0.5, filter_type=0,
   filter_env=0.6, decay=0.3, release=0.2, amp=0.35, pan=0.1},
  -- ch3: metallic perc — pulse, FM, heavy fold
  {waveform=2, partials=6, tilt=0.1, fold=2.5, fm_depth=0.6, fm_ratio=1.414,
   sub_amp=0, noise_amp=0.15, filter=3000, filter_q=0.2, filter_type=0,
   filter_env=0.8, decay=0.15, release=0.1, amp=0.25, pan=0.5},
  -- ch4: spectral wash — noise bands, shimmer
  {waveform=3, partials=12, tilt=0.6, fold=0.3, fm_depth=0.1, fm_ratio=3.0,
   sub_amp=0, noise_amp=0.3, filter=5000, filter_q=0.6, filter_type=1,
   filter_env=0.2, decay=1.2, release=0.8, amp=0.2, pan=-0.3},
}

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

  -- per-channel params
  for ch = 1, 4 do
    local pre = CH_PRESETS[ch]
    params:add_separator("CH " .. ch)

    params:add_option("ch" .. ch .. "_waveform", "waveform", WAVE_NAMES, pre.waveform + 1)
    params:set_action("ch" .. ch .. "_waveform", function(v)
      engine.waveform(ch - 1, v - 1)
    end)

    params:add_number("ch" .. ch .. "_partials", "partials", 1, 16, pre.partials)
    params:set_action("ch" .. ch .. "_partials", function(v)
      engine.partials(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_tilt", "tilt",
      controlspec.new(0, 3, 'lin', 0.01, pre.tilt))
    params:set_action("ch" .. ch .. "_tilt", function(v)
      engine.tilt(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_fold", "wavefold",
      controlspec.new(0, 5, 'lin', 0.01, pre.fold))
    params:set_action("ch" .. ch .. "_fold", function(v)
      engine.fold(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_fm_depth", "FM depth",
      controlspec.new(0, 2, 'lin', 0.01, pre.fm_depth))
    params:set_action("ch" .. ch .. "_fm_depth", function(v)
      engine.fm_depth(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_fm_ratio", "FM ratio",
      controlspec.new(0.25, 8, 'exp', 0.01, pre.fm_ratio))
    params:set_action("ch" .. ch .. "_fm_ratio", function(v)
      engine.fm_ratio(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_sub_amp", "sub amp",
      controlspec.new(0, 1, 'lin', 0.01, pre.sub_amp))
    params:set_action("ch" .. ch .. "_sub_amp", function(v)
      engine.sub_amp(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_noise_amp", "noise amp",
      controlspec.new(0, 1, 'lin', 0.01, pre.noise_amp))
    params:set_action("ch" .. ch .. "_noise_amp", function(v)
      engine.noise_amp(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_spread", "spread",
      controlspec.new(0, 0.1, 'lin', 0.001, 0.008))
    params:set_action("ch" .. ch .. "_spread", function(v)
      engine.spread(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_filter", "filter",
      controlspec.new(100, 12000, 'exp', 1, pre.filter, "hz"))
    params:set_action("ch" .. ch .. "_filter", function(v)
      engine.filter_freq(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_filter_q", "filter q",
      controlspec.new(0.05, 1, 'lin', 0.01, pre.filter_q))
    params:set_action("ch" .. ch .. "_filter_q", function(v)
      engine.filter_q(ch - 1, v)
    end)

    params:add_option("ch" .. ch .. "_filter_type", "filter type", FILTER_NAMES, pre.filter_type + 1)
    params:set_action("ch" .. ch .. "_filter_type", function(v)
      engine.filter_type(ch - 1, v - 1)
    end)

    params:add_control("ch" .. ch .. "_filter_env", "filt env mod",
      controlspec.new(-1, 1, 'lin', 0.01, pre.filter_env))
    params:set_action("ch" .. ch .. "_filter_env", function(v)
      engine.filter_env(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_amp", "amp",
      controlspec.new(0, 1, 'lin', 0.01, pre.amp))
    params:set_action("ch" .. ch .. "_amp", function(v)
      engine.amp(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_decay", "decay",
      controlspec.new(0.01, 4, 'exp', 0.01, pre.decay, "s"))
    params:set_action("ch" .. ch .. "_decay", function(v)
      engine.dec(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_release", "release",
      controlspec.new(0.01, 4, 'exp', 0.01, pre.release, "s"))
    params:set_action("ch" .. ch .. "_release", function(v)
      engine.rel(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_delay_send", "delay send",
      controlspec.new(0, 1, 'lin', 0.01, 0.25))
    params:set_action("ch" .. ch .. "_delay_send", function(v)
      engine.delay_send(ch - 1, v)
    end)

    params:add_control("ch" .. ch .. "_pan", "pan",
      controlspec.new(-1, 1, 'lin', 0.01, pre.pan))
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

  params:add_control("shimmer", "shimmer",
    controlspec.new(0, 1, 'lin', 0.01, 0.15))
  params:set_action("shimmer", function(v) engine.shimmer(v) end)

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

  params:bang()

  clock.run(step_clock)

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
-- input: encoders
----------------------------------------------------------------

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, NUM_PAGES)
    sel_param = 1

  elseif n == 2 then
    if page == 3 then
      sel_param = util.clamp(sel_param + d, 1, #SPECTRAL_PARAMS)
    elseif page == 4 then
      sel_param = util.clamp(sel_param + d, 1, 8) -- 8 FX params
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
    elseif page == 1 then
      enc_rhythm(d)
    elseif page == 2 then
      enc_pitch(d)
    elseif page == 3 then
      enc_spectral(d)
    elseif page == 4 then
      enc_fx(d)
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

function enc_spectral(d)
  local pname = SPECTRAL_PARAMS[sel_param]
  local pkey = "ch" .. sel_ch .. "_" .. pname
  if params.lookup[pkey] then
    params:delta(pkey, d)
  end
end

local FX_PARAMS = {"delay_time", "delay_feedback", "delay_color", "delay_mix",
                    "halo", "reverb_mix", "reverb_size", "shimmer"}

function enc_fx(d)
  local pkey = FX_PARAMS[sel_param]
  if pkey and params.lookup[pkey] then
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

local PAGE_NAMES = {"RHYTHM", "PITCH", "SPECTRAL", "FX"}
local CH_LABELS = {"CRYST", "BASS", "METAL", "WASH"}

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

  -- page dots
  for i = 1, NUM_PAGES do
    screen.level(i == page and 15 or 3)
    screen.rect(55 + (i-1)*5, 3, 3, 3)
    screen.fill()
  end

  -- divider
  screen.level(2)
  screen.move(1, 9)
  screen.line(128, 9)
  screen.stroke()

  if page == 1 then draw_rhythm()
  elseif page == 2 then draw_pitch()
  elseif page == 3 then draw_spectral()
  elseif page == 4 then draw_fx()
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
      else
        if is_play then
          screen.level(4)
          screen.rect(x, y + 1, w - 1, 6)
          screen.fill()
        end
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

    screen.level(is_sel and 10 or 4)
    screen.move(116, y + 7)
    screen.text_right(zig:get_mode_name(ch))
  end
end

function draw_spectral()
  -- show selected channel label
  screen.level(12)
  screen.move(50, 7)
  screen.text_right("CH" .. sel_ch .. " " .. CH_LABELS[sel_ch])

  for ch = 1, 4 do
    local y = 12 + (ch - 1) * 11
    local is_sel = ch == sel_ch

    screen.level(is_sel and 15 or 4)
    screen.move(1, y + 7)
    screen.text(ch)

    -- waveform indicator
    local wf = params:get("ch" .. ch .. "_waveform")
    screen.level(is_sel and 10 or 4)
    screen.move(8, y + 7)
    screen.text(string.sub(WAVE_NAMES[wf], 1, 3))

    -- partial bars with fold brightness
    local np = params:get("ch" .. ch .. "_partials")
    local tilt = params:get("ch" .. ch .. "_tilt")
    local fld = params:get("ch" .. ch .. "_fold")
    for i = 1, 16 do
      local h = 0
      if i <= np then
        h = math.floor(8 / (i ^ (tilt * 0.4)))
        h = math.max(h, 1)
      end
      if h > 0 then
        local x = 26 + (i - 1) * 4
        local bright = is_sel and (engine_freeze[ch] == 1 and 15 or 8) or 3
        if fld > 0.5 then bright = math.min(bright + 3, 15) end
        screen.level(bright)
        screen.rect(x, y + 9 - h, 3, h)
        screen.fill()
      end
    end

    -- freeze indicator
    if engine_freeze[ch] == 1 then
      screen.level(15)
      screen.move(95, y + 7)
      screen.text("FRZ")
    end

    -- filter type
    local ft = params:get("ch" .. ch .. "_filter_type")
    screen.level(is_sel and 6 or 2)
    screen.move(112, y + 7)
    screen.text_right(FILTER_NAMES[ft])
  end

  -- selected param
  screen.level(10)
  screen.move(1, 60)
  local pname = SPECTRAL_PARAMS[sel_param]
  screen.text(pname .. ": ")
  local pkey = "ch" .. sel_ch .. "_" .. pname
  if params.lookup[pkey] then
    screen.text(params:string(pkey))
  end
end

function draw_fx()
  local y = 14
  for i, pkey in ipairs(FX_PARAMS) do
    local is_sel = i == sel_param
    screen.level(is_sel and 15 or 5)
    screen.move(3, y + (i - 1) * 6)
    screen.text(pkey:gsub("_", " "))

    screen.level(is_sel and 12 or 4)
    screen.move(126, y + (i - 1) * 6)
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
      sel_ch = ch
      page = 1
    end

  elseif y >= 5 and y <= 8 then
    local ch = y - 4
    local c = zig.channels[ch]
    if z == 1 then
      if x >= 1 and x <= c.chain_len then
        grid_held = {ch = ch, step = x}
        sel_ch = ch
        page = 2
      elseif x == c.chain_len + 1 and c.chain_len < 16 then
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
      if x == c.position and playing then
        bright = 15
      elseif grid_held and grid_held.ch == ch and grid_held.step == x then
        bright = 12
      else
        local note = c.chain[x] or 60
        bright = math.floor(util.linlin(24, 96, 3, 10, note))
      end
      g:led(x, ch + 4, bright)
    end
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
