// Engine_Tessera v3
// 4 voices — each: 2 osc + sub + noise, MoogFF ladder, tanh saturation
// Global: tape delay w/ diffusion, plate reverb
//
// Design: fewer oscillators, better gain staging, musical saturation,
// internal modulation for life. Sounds like hardware, not a spreadsheet.

Engine_Tessera : CroneEngine {
  var voices;
  var delayBus, reverbBus;
  var delaySynth, reverbSynth;

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    delayBus = Bus.audio(context.server, 2);
    reverbBus = Bus.audio(context.server, 2);

    // ── VOICE ────────────────────────────────────
    // 2 oscillators (saw+pulse) mixed, sub sine, filtered noise
    // -> tanh saturation -> MoogFF ladder -> VCA
    // internal drift LFOs for life
    SynthDef(\tessera_voice, {
      arg out=0, delayOut=0,
          freq=220, amp=0.3, t_gate=0, accent=1,
          // envelope
          atk=0.005, dec=0.5, rel=0.3,
          // oscillator mix: saw, pulse, sub, noise (0-1 each)
          sawLvl=0.5, pulseLvl=0.0, subLvl=0.0, noiseLvl=0.0,
          // timbre
          detune=0.08, pulseWidth=0.5,
          drive=0.3,        // pre-filter saturation 0-2
          // filter
          cutoff=2400, res=0.3, envMod=0.4,
          // modulation
          drift=0.15,       // slow pitch/filter drift amount
          slewTime=0.05,
          pan=0, delaySend=0.25;

      var sig, osc1, osc2, sub, noise, env, envFilt, portFreq;
      var driftLfo1, driftLfo2, cutMod;

      portFreq = Lag.kr(freq, slewTime);

      // slow internal drift — this is what makes it breathe
      driftLfo1 = LFNoise2.kr(0.3) * drift;
      driftLfo2 = LFNoise2.kr(0.37) * drift;

      // perc envelope with accent
      env = EnvGen.kr(
        Env.perc(atk, dec + rel),
        t_gate
      ) * accent;

      // filter envelope (faster attack, independent shape)
      envFilt = EnvGen.kr(
        Env.perc(atk * 0.5, dec * 0.6),
        t_gate
      );

      // ── oscillators ────────────────────────────
      // two detuned saws — classic thick analog sound
      osc1 = Saw.ar(portFreq * (1 + (detune * 0.01) + (driftLfo1 * 0.002)));
      osc2 = Saw.ar(portFreq * (1 - (detune * 0.01) + (driftLfo2 * 0.002)));

      // pulse with width modulation from drift
      sub = Pulse.ar(portFreq, (pulseWidth + (driftLfo1 * 0.05)).clip(0.05, 0.95));

      // sub: pure sine one octave down
      noise = SinOsc.ar(portFreq * 0.5);

      // mix — each level 0-1
      sig = (osc1 * sawLvl * 0.4) + (osc2 * sawLvl * 0.4)
          + (sub * pulseLvl * 0.5)
          + (noise * subLvl * 0.6)
          + (BPF.ar(PinkNoise.ar, portFreq.max(40), 0.3) * noiseLvl * 2);

      // ── saturation (pre-filter, like driving a Moog input) ──
      sig = (sig * (1 + (drive * 3))).tanh * (1 / (1 + drive));

      // ── MoogFF ladder filter ───────────────────
      // cutoff modulated by envelope + drift
      cutMod = cutoff * (1 + (envFilt * envMod * 3) + (driftLfo2 * 0.03));
      cutMod = cutMod.clip(30, 18000);
      sig = MoogFF.ar(sig, cutMod, res.linlin(0, 1, 0, 3.8));

      // ── output ─────────────────────────────────
      sig = sig * env * amp;
      sig = Pan2.ar(sig, pan + (driftLfo1 * 0.05));

      Out.ar(out, sig);
      Out.ar(delayOut, sig * delaySend);
    }).add;

    // ── TAPE DELAY (Mimeophon-inspired) ──────────
    // Saturated feedback, filtered, with allpass diffusion "halo"
    SynthDef(\tessera_delay, {
      arg in=0, out=0,
          time=0.375, feedback=0.45, color=3500,
          mix=0.3, halo=0.25;
      var sig, delayed, haloSig;

      sig = In.ar(in, 2);

      // feedback with tape-style saturation
      delayed = CombL.ar(sig, 2.0, time.clip(0.01, 2.0), feedback * 5);
      delayed = (delayed * 1.2).tanh * 0.85;  // tape saturation
      delayed = LPF.ar(delayed, color.clip(200, 12000));
      delayed = HPF.ar(delayed, 80);  // remove mud

      // halo: diffused allpass cloud (Mimeophon's magic)
      haloSig = delayed;
      4.do { arg i;
        haloSig = AllpassC.ar(haloSig, 0.15,
          LFNoise1.kr(0.1 + (i * 0.04)).range(0.01, 0.05 + (i * 0.015)),
          halo * 2.5);
      };

      Out.ar(out, haloSig * mix);
    }).add;

    // ── REVERB (plate-style, bright but not muddy) ──
    SynthDef(\tessera_reverb, {
      arg in=0, out=0, mix=0.2, size=0.8, damp=0.4;
      var sig, dry, wet;

      sig = In.ar(in, 2);
      dry = sig;

      // pre-delay for clarity
      wet = DelayN.ar(sig, 0.05, 0.02);
      wet = FreeVerb2.ar(wet[0], wet[1], 1, size, damp);
      wet = HPF.ar(wet, 120);  // keep reverb clean
      wet = LPF.ar(wet, 8000); // not too bright

      Out.ar(out, dry + (wet * mix));
    }).add;

    context.server.sync;

    // ── instantiate voices ───────────────────────
    voices = Array.fill(4, {
      Synth(\tessera_voice, [
        \out, reverbBus, \delayOut, delayBus
      ], context.xg);
    });

    delaySynth = Synth.after(voices.last, \tessera_delay, [
      \in, delayBus, \out, reverbBus
    ]);

    reverbSynth = Synth.after(delaySynth, \tessera_reverb, [
      \in, reverbBus, \out, context.out_b
    ]);

    // ── voice commands ───────────────────────────
    this.addCommand("hz",       "if", { |msg| voices[msg[1].asInteger].set(\freq, msg[2]) });
    this.addCommand("amp",      "if", { |msg| voices[msg[1].asInteger].set(\amp, msg[2]) });
    this.addCommand("gate",     "ii", { |msg| voices[msg[1].asInteger].set(\t_gate, msg[2]) });
    this.addCommand("atk",      "if", { |msg| voices[msg[1].asInteger].set(\atk, msg[2]) });
    this.addCommand("dec",      "if", { |msg| voices[msg[1].asInteger].set(\dec, msg[2]) });
    this.addCommand("rel",      "if", { |msg| voices[msg[1].asInteger].set(\rel, msg[2]) });
    this.addCommand("saw",      "if", { |msg| voices[msg[1].asInteger].set(\sawLvl, msg[2]) });
    this.addCommand("pulse",    "if", { |msg| voices[msg[1].asInteger].set(\pulseLvl, msg[2]) });
    this.addCommand("sub",      "if", { |msg| voices[msg[1].asInteger].set(\subLvl, msg[2]) });
    this.addCommand("noise",    "if", { |msg| voices[msg[1].asInteger].set(\noiseLvl, msg[2]) });
    this.addCommand("detune",   "if", { |msg| voices[msg[1].asInteger].set(\detune, msg[2]) });
    this.addCommand("pw",       "if", { |msg| voices[msg[1].asInteger].set(\pulseWidth, msg[2]) });
    this.addCommand("drive",    "if", { |msg| voices[msg[1].asInteger].set(\drive, msg[2]) });
    this.addCommand("cutoff",   "if", { |msg| voices[msg[1].asInteger].set(\cutoff, msg[2]) });
    this.addCommand("res",      "if", { |msg| voices[msg[1].asInteger].set(\res, msg[2]) });
    this.addCommand("env_mod",  "if", { |msg| voices[msg[1].asInteger].set(\envMod, msg[2]) });
    this.addCommand("drift",    "if", { |msg| voices[msg[1].asInteger].set(\drift, msg[2]) });
    this.addCommand("slew",     "if", { |msg| voices[msg[1].asInteger].set(\slewTime, msg[2]) });
    this.addCommand("pan",      "if", { |msg| voices[msg[1].asInteger].set(\pan, msg[2]) });
    this.addCommand("delay_send", "if", { |msg| voices[msg[1].asInteger].set(\delaySend, msg[2]) });
    this.addCommand("accent",   "if", { |msg| voices[msg[1].asInteger].set(\accent, msg[2]) });

    // ── FX commands ──────────────────────────────
    this.addCommand("delay_time",     "f", { |msg| delaySynth.set(\time, msg[1]) });
    this.addCommand("delay_feedback", "f", { |msg| delaySynth.set(\feedback, msg[1]) });
    this.addCommand("delay_color",    "f", { |msg| delaySynth.set(\color, msg[1]) });
    this.addCommand("delay_mix",      "f", { |msg| delaySynth.set(\mix, msg[1]) });
    this.addCommand("halo",           "f", { |msg| delaySynth.set(\halo, msg[1]) });
    this.addCommand("reverb_mix",     "f", { |msg| reverbSynth.set(\mix, msg[1]) });
    this.addCommand("reverb_size",    "f", { |msg| reverbSynth.set(\size, msg[1]) });
    this.addCommand("reverb_damp",    "f", { |msg| reverbSynth.set(\damp, msg[1]) });
  }

  free {
    voices.do(_.free);
    delaySynth.free;
    reverbSynth.free;
    delayBus.free;
    reverbBus.free;
  }
}
