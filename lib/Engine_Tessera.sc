// Engine_Tessera v5 — Resynthesizer
// 4 voices: Spectraphon spectral osc + QPAS dual filter + Mimeophon delay
// Thick, organic, alien — burning cathedral through broken radio
//
// Per voice: 6 partials (saw+sine, individually saturated),
//   dual animated resonant BPF peaks, spectral freeze/tilt
// Global: tape delay w/ halo diffusion, plate reverb

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

    // ── SPECTRAL VOICE ─────────────────────────────
    SynthDef(\tessera_voice, {
      arg out=0, delayOut=0,
          freq=220, amp=0.5, t_gate=0, accent=1,
          atk=0.005, dec=0.5, rel=0.3,
          partials=6, tilt=1.0,
          spread=0.3, t_freeze=0,
          drive=0.5,
          peak1=800, peak2=2400, peakSpread=0,
          res=0.5, envMod=0.5,
          drift=0.2,
          slewTime=0.05,
          pan=0, delaySend=0.25;

      var sig, env, envFilt, portFreq;
      var driftLfo1, driftLfo2, peakLfo1, peakLfo2;
      var peak1Freq, peak2Freq, filt1, filt2;
      var partialSig, partialFreq, partialAmp, partialDrift;
      var partialSaw, partialSin, partialMix;
      var driveGain, freezeFlag;
      var cutEnv1, cutEnv2, resScaled;

      portFreq = Lag.kr(freq, slewTime);

      // freeze latch: holds freq when freeze engaged
      freezeFlag = Latch.kr(portFreq, t_freeze + Impulse.kr(0));

      // select: when freeze > 0, use latched freq
      portFreq = Select.kr(t_freeze > 0, [portFreq, freezeFlag]);

      // drift LFOs — slow analog wandering
      driftLfo1 = LFNoise2.kr(0.25) * drift;
      driftLfo2 = LFNoise2.kr(0.31) * drift;

      // filter peak LFOs — slow vowel-like animation
      peakLfo1 = LFNoise2.kr(0.13).range(-0.15, 0.15);
      peakLfo2 = LFNoise2.kr(0.09).range(-0.15, 0.15);

      // amplitude envelope
      env = EnvGen.kr(
        Env.perc(atk, dec + rel),
        t_gate
      ) * accent;

      // filter envelope — fast attack for plucky filter sweep
      envFilt = EnvGen.kr(
        Env.perc(atk * 0.3, dec * 0.5),
        t_gate
      );

      // ── SPECTRAL OSCILLATOR (Spectraphon-inspired) ──
      // 6 partials: each is saw+sine mix, individually detuned and saturated
      sig = Mix.fill(6, { arg i;
        // tilt curve: lower partials louder, tilt controls rolloff steepness
        // partial 0 = fundamental, partial 5 = 6th harmonic
        partialAmp = (1 / ((i + 1) ** (tilt * 0.5))).clip(0.05, 1.0);

        // only sound partials up to the partials count
        partialAmp = partialAmp * (i < partials).asInteger;

        // each partial drifts independently
        partialDrift = LFNoise2.kr(0.2 + (i * 0.07)) * spread * 0.01;

        // partial frequency: harmonic series with spread drift
        partialFreq = portFreq * (i + 1) * (1 + partialDrift + (driftLfo1 * 0.003));

        // saw + sine mix per partial (saw for grit, sine for body)
        partialSaw = Saw.ar(partialFreq * (1 + (LFNoise2.kr(0.4 + (i * 0.1)) * 0.003)));
        partialSin = SinOsc.ar(partialFreq);
        partialMix = (partialSaw * 0.6) + (partialSin * 0.4);

        // individual partial saturation — this is what makes it THICK
        partialMix = (partialMix * 1.5).tanh;

        partialMix * partialAmp;
      });

      // scale down from 6 partials
      sig = sig * 0.2;

      // add fundamental body: a fat detuned saw pair at root
      sig = sig + (Saw.ar(portFreq * (1 + (driftLfo1 * 0.004))) * 0.3);
      sig = sig + (Saw.ar(portFreq * (1 - (driftLfo2 * 0.004))) * 0.3);

      // ── PRE-FILTER SATURATION ─────────────────────
      driveGain = 1 + (drive * 3);
      sig = (sig * driveGain).tanh * (1 / driveGain.sqrt);

      // ── DUAL RESONANT FILTER (QPAS-inspired) ──────
      // two BPF peaks in parallel, spread apart like formants
      peak1Freq = peak1 * (1 + peakLfo1) * (2 ** (peakSpread * -0.5));
      peak2Freq = peak2 * (1 + peakLfo2) * (2 ** (peakSpread * 0.5));

      // envelope modulation pushes both peaks up
      cutEnv1 = peak1Freq * (1 + (envFilt * envMod * 4) + (driftLfo1 * 0.03));
      cutEnv2 = peak2Freq * (1 + (envFilt * envMod * 3) + (driftLfo2 * 0.03));
      cutEnv1 = cutEnv1.clip(40, 18000);
      cutEnv2 = cutEnv2.clip(40, 18000);

      // resonance: BPF rq — lower = more resonant. At res=1, rq=0.05 (screaming)
      resScaled = res.linlin(0, 1, 0.8, 0.03);

      filt1 = BPF.ar(sig, cutEnv1, resScaled);
      filt2 = BPF.ar(sig, cutEnv2, resScaled);

      // makeup gain for BPF (BPF attenuates heavily)
      filt1 = filt1 * (1 + (res * 6));
      filt2 = filt2 * (1 + (res * 6));

      // mix filters with stereo spread — peak1 slightly left, peak2 slightly right
      sig = [
        (filt1 * 0.7) + (filt2 * 0.3),
        (filt1 * 0.3) + (filt2 * 0.7)
      ];

      // ── POST-FILTER SATURATION ────────────────────
      sig = (sig * 1.2).tanh * 0.85;

      // ── OUTPUT ────────────────────────────────────
      sig = sig * env * amp;
      sig = Balance2.ar(sig[0], sig[1], pan + (driftLfo1 * 0.06));

      Out.ar(out, sig);
      Out.ar(delayOut, sig * delaySend);
    }).add;

    // ── TAPE DELAY (Mimeophon-inspired) ─────────────
    SynthDef(\tessera_delay, {
      arg in=0, out=0,
          time=0.375, feedback=0.45, color=3500,
          mix=0.3, halo=0.25;
      var sig, delayed, haloSig;

      sig = In.ar(in, 2);

      delayed = CombC.ar(sig, 2.0, time.clip(0.01, 2.0), feedback * 6);
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

    // ── REVERB ──────────────────────────────────────
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

    // ── VOICE COMMANDS ──────────────────────────────
    this.addCommand("hz",       "if", { |msg| voices[msg[1].asInteger].set(\freq, msg[2]) });
    this.addCommand("amp",      "if", { |msg| voices[msg[1].asInteger].set(\amp, msg[2]) });
    this.addCommand("gate",     "ii", { |msg| voices[msg[1].asInteger].set(\t_gate, msg[2]) });
    this.addCommand("atk",      "if", { |msg| voices[msg[1].asInteger].set(\atk, msg[2]) });
    this.addCommand("dec",      "if", { |msg| voices[msg[1].asInteger].set(\dec, msg[2]) });
    this.addCommand("rel",      "if", { |msg| voices[msg[1].asInteger].set(\rel, msg[2]) });
    this.addCommand("accent",   "if", { |msg| voices[msg[1].asInteger].set(\accent, msg[2]) });
    this.addCommand("partials", "if", { |msg| voices[msg[1].asInteger].set(\partials, msg[2]) });
    this.addCommand("tilt",     "if", { |msg| voices[msg[1].asInteger].set(\tilt, msg[2]) });
    this.addCommand("spread",   "if", { |msg| voices[msg[1].asInteger].set(\spread, msg[2]) });
    this.addCommand("freeze",   "ii", { |msg| voices[msg[1].asInteger].set(\t_freeze, msg[2]) });
    this.addCommand("drive",    "if", { |msg| voices[msg[1].asInteger].set(\drive, msg[2]) });
    this.addCommand("peak1",    "if", { |msg| voices[msg[1].asInteger].set(\peak1, msg[2]) });
    this.addCommand("peak2",    "if", { |msg| voices[msg[1].asInteger].set(\peak2, msg[2]) });
    this.addCommand("peak_spread", "if", { |msg| voices[msg[1].asInteger].set(\peakSpread, msg[2]) });
    this.addCommand("res",      "if", { |msg| voices[msg[1].asInteger].set(\res, msg[2]) });
    this.addCommand("env_mod",  "if", { |msg| voices[msg[1].asInteger].set(\envMod, msg[2]) });
    this.addCommand("drift",    "if", { |msg| voices[msg[1].asInteger].set(\drift, msg[2]) });
    this.addCommand("slew",     "if", { |msg| voices[msg[1].asInteger].set(\slewTime, msg[2]) });
    this.addCommand("pan",      "if", { |msg| voices[msg[1].asInteger].set(\pan, msg[2]) });
    this.addCommand("delay_send", "if", { |msg| voices[msg[1].asInteger].set(\delaySend, msg[2]) });

    // ── FX COMMANDS ─────────────────────────────────
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
