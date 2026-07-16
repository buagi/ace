# Recording the ACE demo

`ace demo` is a **paced, zero-credit** run-through of ACE's features, built to be recorded. Nothing is built,
pushed, deployed, or spent — every step is `--dry-run` / `--explain` / `--demo` / the DRY swarm sandbox / a
read-only status, or a throwaway repo the script creates and deletes. No API keys required.

## Run it

```sh
ace demo                     # interactive: press ↵ between steps
DEMO_AUTO=1 ace demo         # hands-free (auto-advances) — record THIS
DEMO_SPEED=slow ace demo     # slower typing + longer pauses (also: fast)
DEMO_SECTIONS=atlas,swarm ace demo   # just these (default: all)
```

Sections: `intro, status, scaffold, atlas, graph, policy, loop, swarm, stats, deploy, outro`.

## Record to a GIF / SVG / MP4

Record in an **80×24 (or 100×30)** terminal with a truecolor theme for the cleanest result.

**asciinema → GIF (recommended):**
```sh
asciinema rec -c 'DEMO_AUTO=1 DEMO_SPEED=normal ace demo' ace-demo.cast
agg --theme monokai --font-size 20 ace-demo.cast ace-demo.gif      # agg = asciinema's gif renderer
```

**asciinema → SVG** (what the README uses — crisp, tiny, animates in the browser):
```sh
asciinema rec -c 'DEMO_AUTO=1 ace demo' ace-demo.cast
svg-term --in ace-demo.cast --out docs/demo/ace-demo.svg --window --width 100 --height 30
```

**Single-frame stills** (already wired into ACE via `ace snap`): `freeze` (Go) or `ansitoimg` (uv) turn a
captured terminal into a PNG — good for a poster frame or a README hero image.

**Screen-capture to MP4:** just run `DEMO_AUTO=1 DEMO_SPEED=slow ace demo` full-screen and record with OBS /
`wf-recorder` / QuickTime. `slow` gives a comfortable narration cadence.

## Tips

- `DEMO_AUTO=1` is essential for a clean recording (no waiting on keypresses).
- The `loop` and `swarm` sections auto-play (`ace loop dash --demo` cycles; `ace swarm sandbox` runs a DRY
  fleet) — they're the most visual; keep them.
- To keep a recording short, trim to the highlights: `DEMO_SECTIONS=intro,atlas,loop,swarm,outro`.
- The menu itself (`ace`) is interactive — record it separately if you want to show the themed screens (now
  each replaces the previous; `ACE_ALT_SCREEN=0` if you want the old scroll-back behavior for the capture).
