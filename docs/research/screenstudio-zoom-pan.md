# Screen Studio zoom and pan research

Research date: 2026-09-03. Scope: first-party Screen Studio website, guides, changelog, roadmap, and media embedded by Screen Studio. Statements marked **Observed/inferred** come from first-party demo media rather than an explicit product specification.

## Executive summary

Screen Studio's published design is best understood as an **event-generated, editable camera timeline**, not as a documented semantic/AI framing system:

- Recorded mouse clicks create Auto zoom ranges by default. Each range can instead be Manual, and each has an editable duration and zoom level.
- Auto chooses its initial subject from click position data, then moves the viewport while zoomed so the cursor remains visible. Manual uses a user-placed focal point.
- Zoom scale, target mode, time range, and animation style are separate concerns. Screen Studio exposes two screen-motion personalities (`Focused` and `Smooth`) and separately controls cursor smoothing and motion blur.
- Ordinary zoom ranges have an entrance, a hold/follow phase, and an exit back to the base framing. An instant option removes the transition. A separate `Always keep zoomed in` mode changes the base framing and continuously follows the cursor, especially for vertical output.
- Screen Studio does **not** publish its click-grouping threshold, lead/lag timing, follow dead zone, easing/spring constants, edge-clamping math, or any content-aware zoom-strength heuristic.

The strongest lesson for SmoothScreen is architectural: make a zoom range a complete camera shot with explicit base framing before and after it; keep targeting separate from animation; and make cursor following bounded and stateful rather than recentering on every sample.

## Focused answer: frequency, grouping, and avoiding zoom churn

### What Screen Studio actually promises

- Clicks are the input to automatic zoom generation, but Screen Studio never states that **every click creates a separate range**. The documented unit in the editor is the range, not the click. One range may use the click positions that fall inside it; a range with no click cannot resolve an Auto target. [Auto Zoom guide](https://screen.studio/guide/auto-zoom), [Adding & Editing Zooms guide](https://screen.studio/guide/adding-editing-zooms)
- The range itself owns duration and can be stretched by either edge. This lets a user preserve one camera state over an interaction sequence instead of accepting repeated automatic entrances and exits. [Adding & Editing Zooms guide](https://screen.studio/guide/adding-editing-zooms)
- Screen Studio has historically enforced temporal validity between ranges: its changelog records preventing a duplicate zoom when there was not enough space before the next range. The same release first increased minimum range duration to 1 second; a later release reduced the editable minimum to 0.1 second. These are UI constraints, not a published auto-generation threshold, but they show that ranges are treated as bounded, non-arbitrary phases with room for transitions. [Screen Studio changelog](https://screen.studio/changelog)

### What the official demo shows

**Observed/inferred:** In the 24-second project shown in Screen Studio's own Auto Zoom guide, the timeline contains only three Auto ranges, approximately `3.8–6.6s`, `9.6–14.0s`, and `17.2–20.6s`. Each is shown at `2x`; the gaps are several seconds long. During the middle range, the camera stays at the same zoom level while the cursor moves from the playback controls down through the track list, and the viewport pans rather than zooming out and back in. By about `14.6s`, after the block ends, the view is back at overview. [Auto Zoom guide](https://screen.studio/guide/auto-zoom), [embedded Auto Zoom demo video](https://cdn.sanity.io/files/2ltoq22u/production/c73cce5a1569b0ad2ace6897fd025df5f48d5512.mp4)

This is good evidence for the *shape* of the behavior—sparse ranges, in-shot panning, reset in gaps—but not for exact thresholds. The demo may have been edited, and Screen Studio publishes no raw click log for it.

### How the UX suppresses excessive movement

The first-party material points to several cooperating mechanisms:

1. **Click-gated generation:** cursor travel or typing alone is not documented as creating zoom ranges. [Auto Zoom guide](https://screen.studio/guide/auto-zoom)
2. **Multi-action ranges:** the demo keeps one range active while the pointer travels between related controls, using a pan rather than a zoom-out/zoom-in pair. This is a visual inference, not a stated merge rule. [embedded Auto Zoom demo video](https://cdn.sanity.io/files/2ltoq22u/production/c73cce5a1569b0ad2ace6897fd025df5f48d5512.mp4)
3. **Visibility following rather than hard centering:** the editor says Auto will “try to keep the mouse cursor visible.” The softer wording and observed motion indicate a bounded follower rather than exact cursor locking. [embedded editing demo video](https://cdn.sanity.io/files/2ltoq22u/production/3115f12a592970fd873ffe30a5a9e693a37de66f.mp4)
4. **Independent pan and scale dynamics:** Screen Studio distinguishes zooming in/out from moving while zoomed, so a settled zoom can pan without restarting the scale animation. [Animations guide](https://screen.studio/guide/animations)
5. **High-level motion styles:** `Focused` settles quickly; `Smooth` is more fluid. Screen Studio removed older “glide” options from the UI in 2024, suggesting a deliberate move away from low-level tuning toward opinionated styles. [Animations guide](https://screen.studio/guide/animations), [Screen Studio changelog](https://screen.studio/changelog)
6. **Explicit persistent mode:** `Always keep zoomed in` is used when repeated returns to overview would be undesirable, especially in narrow aspect ratios. It is not an accidental carry-over from a previous range. [Aspect Ratio guide](https://screen.studio/guide/aspect-ratio)

### Product conclusion for SmoothScreen

Do not model auto zoom as “click → zoom effect.” Model it as **click activity → camera shot proposal**:

- Start a shot for a meaningful click after sufficient quiet/base-framing time.
- Merge later related clicks into the active shot when they can be served by a restrained pan.
- Keep scale stable during the shot; pan only when the subject/cursor threatens a safe-area boundary.
- End the shot only after a meaningful quiet tail, then complete a deterministic return to base framing.
- Suppress a proposed shot when there is not enough time for a readable enter/hold/exit lifecycle.
- Expose a small number of intent presets; keep merge windows, springs, and hysteresis internal unless the user selects an advanced/custom mode.

That last list is a recommendation for SmoothScreen, not a claim about Screen Studio's unpublished constants.

## Findings by behavior

### 1. Triggers and target selection

**Documented facts**

- By default, Screen Studio creates zooms from recorded mouse clicks. Auto mode detects click positions and focuses on those areas. An Auto range containing no mouse click has no place to zoom, so the user must switch it to Manual. [Auto Zoom guide](https://screen.studio/guide/auto-zoom), [Adding & Editing Zooms guide](https://screen.studio/guide/adding-editing-zooms)
- Automatic range creation can be disabled globally using `Create zooms automatically` in Recording settings. [Disable Automatic Zooms guide](https://screen.studio/guide/disable-automatic-zooms-)
- Manual mode works both when the user wants a different target than the click and when no click exists. Its picker presents a purple point which the user moves to the desired focal area. [Manual Zoom guide](https://screen.studio/guide/manual-zoom)
- Finger taps in direct iPhone/iPad capture cannot drive automatic zoom because Screen Studio cannot record them like desktop mouse clicks and movements. [Recording iPhone & iPad guide](https://screen.studio/guide/recording-iphone-ipad)

**What is not documented**

- No first-party source found says that typing or keyboard shortcuts generate camera zooms. Keyboard shortcuts can be recorded and displayed, but the zoom documentation consistently defines automatic targeting in terms of mouse clicks. [Screen Studio homepage](https://screen.studio/), [Auto Zoom guide](https://screen.studio/guide/auto-zoom)
- Screen Studio does not disclose whether it understands clicked UI controls, text, windows, or semantic regions. The public contract is positional: clicks identify the area.

### 2. Shot grouping and duration

**Documented facts**

- Every zoom is an explicit purple block on a dedicated zoom track. A user can click the track to add a block, drag either edge to set its duration, click it to edit mode/level, or right-click to disable or remove it. [Adding & Editing Zooms guide](https://screen.studio/guide/adding-editing-zooms)
- The changelog documents duplicate, copy/paste, multi-select, and batch operations for ranges. It also says version 2.25.30 reduced the minimum editable zoom duration from 1 second to 0.1 second. [Screen Studio changelog](https://screen.studio/changelog)
- If a zoom range begins on the first frame, Screen Studio starts already zoomed instead of playing a zoom-in animation. [Screen Studio changelog](https://screen.studio/changelog)

**Observed/inferred from first-party media**

- The official Auto Zoom demo shows three separate `2x Auto` blocks over a 24-second recording, roughly 3–4 seconds long apiece, with multi-second unzoomed gaps. The middle block remains active while the pointer traverses a list, which demonstrates in-shot pan rather than a new zoom for every movement. This supports treating each range as a self-contained interaction shot, not a click flash. [Auto Zoom guide](https://screen.studio/guide/auto-zoom), [embedded Auto Zoom demo video](https://cdn.sanity.io/files/2ltoq22u/production/c73cce5a1569b0ad2ace6897fd025df5f48d5512.mp4)
- The demo is consistent with the viewport returning to overview after the playhead leaves a block. That reset behavior is visible, but its precise timing curve is not specified.

**What is not documented**

- There is no published click merge window, spatial grouping threshold, pre-roll, post-roll, minimum gap, dwell policy, or rule for selecting among several clicks inside one Auto range. Any numeric recreation of those behaviors would be reverse-engineering, not implementation of a published contract.

### 3. Zoom strength and framing

**Documented facts**

- Zoom level is editable on a selected range. The official UI describes it as how closely to zoom on the cursor during that phase. [Adding & Editing Zooms guide](https://screen.studio/guide/adding-editing-zooms)
- Manual mode separates focal position from zoom strength: the user places the target point, then adjusts level. [Manual Zoom guide](https://screen.studio/guide/manual-zoom)
- Changing output aspect ratio automatically readjusts zooms. [Screen Studio homepage](https://screen.studio/)

**Observed/inferred from first-party media**

- In the editing demo, automatic blocks initially read `2x Auto`; changing one range makes it `3.1x Auto`, while the editor exposes `Set as default` and `Apply to all zooms`. This strongly suggests magnification is principally a per-range/default parameter, not an automatically chosen value derived from target size. [Adding & Editing Zooms guide](https://screen.studio/guide/adding-editing-zooms), [embedded editing demo video](https://cdn.sanity.io/files/2ltoq22u/production/3115f12a592970fd873ffe30a5a9e693a37de66f.mp4)
- Nothing in the first-party material demonstrates a tighter click target automatically receiving more magnification than a broad interaction region. Adaptive scale would therefore be an opportunity for SmoothScreen to exceed Screen Studio's documented behavior, not something required for parity.

### 4. Panning and cursor follow

**Documented facts**

- Screen Studio describes automatic zoom as following the mouse cursor, and its zoom editor says the zoomed camera will automatically try to keep the cursor visible. [Product demo page](https://screen.studio/create/product-demo-videos), [embedded editing demo video](https://cdn.sanity.io/files/2ltoq22u/production/3115f12a592970fd873ffe30a5a9e693a37de66f.mp4)
- Screen Studio treats `Screen zooming in` and `Screen moving` while already zoomed as distinct animation channels with separately adjustable motion blur. [Animations guide](https://screen.studio/guide/animations)
- Screen animation offers `Focused`, which stabilizes quickly for legibility, and `Smooth`, which is more fluid. Cursor animation is configured independently as `Smooth`, `Medium`, `Rapid`, or `None`. [Animations guide](https://screen.studio/guide/animations)
- Cursor smoothing can be disabled for individual fragments when exact motion matters, with dropdown menus given as the example. [Disable Smooth Mouse Movement guide](https://screen.studio/guide/disable-smooth-mouse-movement)

**Observed/inferred from first-party media**

- During an Auto block in the official demo, the view begins around a clicked control and later pans as the pointer travels down a list. The pointer is not rigidly centered at every instant; the camera appears to move only as needed to preserve useful framing. This is consistent with a safe-area/dead-zone follower, although Screen Studio does not publish that algorithm. [embedded Auto Zoom demo video](https://cdn.sanity.io/files/2ltoq22u/production/c73cce5a1569b0ad2ace6897fd025df5f48d5512.mp4)
- Separating zoom motion from in-shot translation is an important implementation clue: scale and center should have independent state/velocity, even if they share a high-level style.

### 5. Zoom-out and reset rules

**Documented facts**

- Normal screen animation explicitly includes zoom-in and zoom-out. Enabling `Instant Animation` makes a range take effect without animation. [Animations guide](https://screen.studio/guide/animations), [Instant Zoom guide](https://screen.studio/guide/instant-zoom)
- `Always keep zoomed in` is a separate aspect-ratio behavior: the output remains cropped and the cursor dictates the visible area's position continuously. This is especially applicable to vertical output. [Aspect Ratio guide](https://screen.studio/guide/aspect-ratio)
- The first-frame special case starts in the zoomed state, which avoids a meaningless opening transition. [Screen Studio changelog](https://screen.studio/changelog)

**Observed/inferred from first-party media**

- Gaps between ordinary timeline blocks return to base framing; the next block then starts a new shot. Continuous crop is not an accidental consequence of a completed zoom range—it is an explicit mode (`Always keep zoomed in`). [Auto Zoom guide](https://screen.studio/guide/auto-zoom), [Aspect Ratio guide](https://screen.studio/guide/aspect-ratio)

### 6. Editing controls, defaults, and presets

**Documented facts**

- Automatic creation from clicks is the default, but every generated range remains directly editable or removable. [Adding & Editing Zooms guide](https://screen.studio/guide/adding-editing-zooms)
- The animation guide says its default settings are intended to be sufficient, while still exposing the higher-level `Focused`/`Smooth` screen styles and separate cursor styles. It does not publish numeric defaults. [Animations guide](https://screen.studio/guide/animations)
- Presets save frequently used project settings, and can be applied to new or completed projects. [Creating Preset guide](https://screen.studio/guide/creating-preset), [Applying Preset guide](https://screen.studio/guide/applying-preset)
- Historical changelog entries document numeric zoom shortcuts (`0`–`9`) while hovered, applying one zoom level to all zooms, disabling ranges without deleting them, and copy/paste and batch actions. [Screen Studio changelog](https://screen.studio/changelog)

**Observed/inferred from first-party media**

- The official animation screenshots show `Focused` screen motion and `Smooth` cursor motion selected. Because the prose never calls those values normative defaults, they should be treated as illustrative UI state rather than a guaranteed default contract. [Animations guide](https://screen.studio/guide/animations)

### 7. Implementation clues

**Documented facts**

- Imported MP4 files can use zooms and other visual effects, but cannot gain cursor animation data that would normally be captured during recording. [Creating Project from Existing Video guide](https://screen.studio/guide/creating-project-from-existing-video)
- The changelog says the raw screen recording does not contain the mouse cursor; Screen Studio reconstructs it later from recorded mouse-position data. It also records fixes for cursor-following during zoom. [Screen Studio changelog](https://screen.studio/changelog)
- The changelog describes a rewritten animation engine, a separate motion-blur engine, and correct blending of mouse position and zoom animation when a cut occurs in the middle of a transition. [Screen Studio changelog](https://screen.studio/changelog)
- The roadmap currently lists beta work on a Glass Loupe zoom effect, sharper zoomed text, and many smaller zoom improvements. [Screen Studio roadmap](https://screen.studio/roadmap)

**Reasonable architectural inference**

The evidence points to a layered render pipeline:

1. Raw screen pixels are retained independently.
2. Mouse positions, cursor types, and clicks are stored as timed metadata.
3. Auto/Manual timeline ranges define camera intent.
4. The renderer evaluates scale and translation continuously, with separate animation state and motion blur.
5. Cursor imagery is composited after those decisions, allowing smoothing, resizing, hiding, and cursor-type correction after recording.

The exact renderer math and data model are proprietary and not published.

## Practical implications for SmoothScreen

The Screen Studio pattern worth copying is not a large collection of exposed timing knobs. It is a small set of stable concepts:

1. **A zoom segment is a complete shot.** It must define entrance, active framing, and exit/reset. Outside a segment, camera state resolves from the base framing, never from stale prior state.
2. **Auto and Manual differ only in target policy.** Auto starts from click metadata and may follow the cursor inside a safe region; Manual holds a user-selected point. Both feed the same camera evaluator.
3. **Scale and pan are separate.** Zoom-in/out animation should not be coupled to cursor-follow translation. A camera can settle in scale while continuing a restrained pan.
4. **Following should preserve visibility, not continuously center.** Use an inner safe area, edge clamping, hysteresis, and velocity limits so small cursor motions do not create camera motion.
5. **Base crop is its own mode.** Persistent vertical/aspect-ratio tracking should be explicit, not an accidental failure to zoom out.
6. **Offer style, not mechanics.** A couple of intent-level motion styles (`Focused`, `Smooth`) are more understandable than exposing raw spring and timing parameters.
7. **Potential differentiation:** choose magnification from target geometry and interaction density. Screen Studio's public UI appears to use a fixed/default per-range scale; SmoothScreen can make small, coherent targets tighter and broad/scattered actions wider, while still allowing override.

## Unknowns that should not be reverse-engineered into requirements

- Exact interval and distance used to merge clicks into one range.
- Whether the first, last, average, or most recent click is the initial target when several clicks occur in a range.
- Lead-in and tail duration around automatically generated ranges.
- The safe-area dimensions and hysteresis for cursor following.
- Spring/easing constants and maximum pan velocity.
- Edge padding, target bias, and aspect-ratio transformation math.
- Any use of window hierarchy, accessibility metadata, OCR, or other semantic UI understanding.

These should be designed and tested against SmoothScreen's own product goals rather than copied from unsupported assumptions.
