// Engine_Tessera v4
// 4 voices — each: 2 osc + sub + noise, MoogFF, musical saturation
// Global: tape delay w/ halo diffusion, plate reverb
//
// v4: fixed gain staging — params actually change the sound now

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

    SynthDef(\tessera_voice, {
      arg out=0, delayOut=0,
          freq=220, amp=0.5, t_gate=0, accent=1,
          atk=0.005, dec=0.5, rel=0.3,
          sawLvl=0.5, pulseLvl=0.0, subLvl=0.0, noiseLvl=0.0,
          detune=0.08, pulseWidth=0.5,
          drive=0.3,
          cutoff=2400, res=0.3, envMod=0.4,
          drift=0.15,
          slewTime=0.05,
          pan=0, delaySend=0.25;

      var sig, osc1, osc2, pul, sub, nz, env, envFilt, portFreq;
      var driftLfo1, driftLfo2, cutMod, driveGain;

      portFreq = Lag.kr(freq, slewTime);

      // internal drift LFOs — analog-style wandering
      driftLfo1 = LFNoise2.kr(0.3) * drift;
      driftLfo2 = LFNoise2.kr(0.37) * drift;

      // amplitude envelope
      env = EnvGen.kr(
        Env.perc(atk, dec + rel),
        t_gate
      ) * accent;

      // filter envelope — fast attack, sharp decay for plucky filter sweeps
      envFilt = EnvGen.kr(
        Env.perc(atk * 0.3, dec * 0.5),
        t_gate
      );

      // ── OSCILLATORS ────────────────────────────
      // two detuned saws — 2.5% detune at max for real thickness
      osc1 = Saw.ar(portFreq * (1 + (detune * 0.025) + (driftLfo1 * 0.003)));
      osc2 = Saw.ar(portFreq * (1 - (detune * 0.025) + (driftLfo2 * 0.003)));

      // pulse with PWM from drift
      pul = Pulse.ar(portFreq, (pulseWidth + (driftLfo1 * 0.08)).clip(0.05, 0.95));

      // sub: pure sine one octave down
      sub = SinOsc.ar(portFreq * 0.5);

      // noise: pitched band around fundamental
      nz = BPF.ar(PinkNoise.ar, portFreq.max(40), 0.25) * 6;

      // MIX — full level, no timid multipliers
      // each source at full amplitude when level = 1
      sig = (osc1 + osc2) * sawLvl * 0.5  // two saws summed, half each
          + (pul * pulseLvl)
          + (sub * subLvl)
          + (nz * noiseLvl);

      // ── SATURATION ─────────────────────────────
      // soft clip, NOT hard tanh. Drive adds harmonics without killing dynamics.
      // at drive=0: clean. at drive=1: warm. at drive=2: crunchy.
      driveGain = 1 + (drive * 2);
      sig = (sig * driveGain / (1 + (sig * driveGain).abs)) * (1 / driveGain.sqrt);

      // ── MOOGFF LADDER FILTER ───────────────────
      // envelope modulation: at envMod=1, cutoff sweeps up 8x (3 octaves!)
      cutMod = cutoff * (1 + (envFilt * envMod * 8) + (driftLfo2 * 0.05));
      cutMod = cutMod.clip(20, 20000);
      // resonance: 0=clean, 0.5=singing, 0.95=screaming self-oscillation
      sig = MoogFF.ar(sig, cutMod, res.linlin(0, 1, 0, 4.0));

      // post-filter makeup gain — filter attenuates, compensate
      sig = sig * (1 + res);

      // ── OUTPUT ─────────────────────────────────
      sig = sig * env * amp;
      sig = Pan2.ar(sig, pan + (driftLfo1 * 0.06));

      Out.ar(out, sig);
      Out.ar(delayOut, sig * delaySend);
    }).add;

    // ── TAPE DELAY ───────────────────────────────
    SynthDef(\tessera_delay, {
      arg in=0, out=0,
          time=0.375, feedback=0.45, color=3500,
          mix=0.3, halo=0.25;
      var sig, delayed, haloSig;

      sig = In.ar(in, 2);

      delayed = CombL.ar(sig, 2.0, time.clip(0.01, 2.0), feedback * 6);
      delayed = (delayed * 1.3).tanh * 0.8;
      delayed = LPF.ar(delayed, color.clip(200, 12000));
      delayed = HPF.ar(delayed, 60);

      haloSig = delayed;
      4.do { arg i;
        haloSig = AllpassC.ar(haloSig, 0.15,
          LFNoise1.kr(0.1 + (i * 0.04)).range(0.01, 0.05 + (i * 0.015)),
          halo * 2.5);
      };

      Out.ar(out, haloSig * mix);
    }).add;

    // ── REVERB ───────────────────────────────────
    SynthDef(\tessera_reverb, {
      arg in=0, out=0, mix=0.2, size=0.8, damp=0.4;
      var sig, dry, wet;

      sig = In.ar(in, 2);
      dry = sig;

      wet = DelayN.ar(sig, 0.05, 0.02);
      wet = FreeVerb2.ar(wet[0], wet[1], 1, size, damp);
      wet = HPF.ar(wet, 100);
      wet = LPF.ar(wet, 9000);

      Out.ar(out, dry + (wet * mix));
    }).add;

    context.server.sync;

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
