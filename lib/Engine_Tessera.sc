// Engine_Tessera
// Spectral resynthesis engine inspired by:
//   Spectraphon (additive partials, freeze, smear)
//   Mimeophon (spectral delay with halo)
//   QPAS (dual resonant filtering)
//
// 4 voices, each with 16 sine partials
// Global spectral delay + diffusion + reverb

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

    // ── voice: spectral resynthesis ──────────────
    SynthDef(\tessera_voice, {
      arg out=0, delayOut=0,
          freq=220, amp=0.3, t_gate=0, accent=1,
          atk=0.003, dec=0.8,
          partials=8, tilt=0.5, spread=0.01,
          filterFreq=2000, filterQ=0.4,
          delaySend=0.3, slewTime=0.05,
          freeze=0, smearRate=0.5, pan=0;

      var sig, env, portFreq;

      portFreq = Lag.kr(freq, slewTime);
      env = EnvGen.kr(Env.perc(atk, dec), t_gate) * accent;

      // additive spectral resynthesis
      sig = Mix.fill(16, { |i|
        var n = i + 1;
        var pFreq = portFreq * n;
        var pAmp = (1 / (n ** (1 + tilt.max(0)))) * (n <= partials);
        var drift = LFNoise1.kr(smearRate + (i * 0.07)) * spread * pFreq;
        drift = drift * (1 - freeze);
        SinOsc.ar(pFreq + drift) * pAmp;
      });

      // resonant lowpass (QPAS-inspired character)
      sig = RLPF.ar(sig, filterFreq.clip(20, 18000), filterQ.clip(0.05, 1));
      sig = sig * 2.5;

      sig = sig * env * amp;
      sig = Pan2.ar(sig, pan);

      Out.ar(out, sig);
      Out.ar(delayOut, sig * delaySend);
    }).add;

    // ── spectral delay (Mimeophon-inspired) ──────
    SynthDef(\tessera_delay, {
      arg in=0, out=0,
          time=0.3, feedback=0.5, color=4000,
          mix=0.4, halo=0.3;

      var sig, delayed, haloSig;

      sig = In.ar(in, 2);
      delayed = CombL.ar(sig, 2.0, time.clip(0.01, 2.0), feedback * 6);
      delayed = LPF.ar(delayed, color.clip(200, 16000));

      haloSig = delayed;
      4.do { |i|
        haloSig = AllpassL.ar(haloSig, 0.5,
          LFNoise1.kr(0.05 + (i * 0.02)).range(0.02, 0.07 + (i * 0.02)),
          halo * 3);
      };

      Out.ar(out, haloSig * mix);
    }).add;

    // ── reverb ───────────────────────────────────
    SynthDef(\tessera_reverb, {
      arg in=0, out=0, mix=0.3, size=0.85, damp=0.5;

      var sig, wet;
      sig = In.ar(in, 2);
      wet = FreeVerb2.ar(sig[0], sig[1], mix, size, damp);
      Out.ar(out, wet);
    }).add;

    context.server.sync;

    // ── instantiate ──────────────────────────────
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

    // ── voice commands (index, value) ────────────
    this.addCommand("hz",          "if", { |msg| voices[msg[1].asInteger].set(\freq, msg[2]) });
    this.addCommand("amp",         "if", { |msg| voices[msg[1].asInteger].set(\amp, msg[2]) });
    this.addCommand("gate",        "ii", { |msg| voices[msg[1].asInteger].set(\t_gate, msg[2]) });
    this.addCommand("atk",         "if", { |msg| voices[msg[1].asInteger].set(\atk, msg[2]) });
    this.addCommand("dec",         "if", { |msg| voices[msg[1].asInteger].set(\dec, msg[2]) });
    this.addCommand("partials",    "if", { |msg| voices[msg[1].asInteger].set(\partials, msg[2]) });
    this.addCommand("tilt",        "if", { |msg| voices[msg[1].asInteger].set(\tilt, msg[2]) });
    this.addCommand("spread",      "if", { |msg| voices[msg[1].asInteger].set(\spread, msg[2]) });
    this.addCommand("filter_freq", "if", { |msg| voices[msg[1].asInteger].set(\filterFreq, msg[2]) });
    this.addCommand("filter_q",    "if", { |msg| voices[msg[1].asInteger].set(\filterQ, msg[2]) });
    this.addCommand("delay_send",  "if", { |msg| voices[msg[1].asInteger].set(\delaySend, msg[2]) });
    this.addCommand("slew",        "if", { |msg| voices[msg[1].asInteger].set(\slewTime, msg[2]) });
    this.addCommand("freeze",      "if", { |msg| voices[msg[1].asInteger].set(\freeze, msg[2]) });
    this.addCommand("smear",       "if", { |msg| voices[msg[1].asInteger].set(\smearRate, msg[2]) });
    this.addCommand("pan",         "if", { |msg| voices[msg[1].asInteger].set(\pan, msg[2]) });
    this.addCommand("accent",      "if", { |msg| voices[msg[1].asInteger].set(\accent, msg[2]) });

    // ── global FX commands ───────────────────────
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
