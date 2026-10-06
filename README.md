# K8s Troubleshooting Kit (read-only)

| File | What |
| --- | --- |
| `k8s_profile.sh` | Bash profile: multi-cluster (Rancher PCI/non-PCI, AKS, on-prem), read-only guard, emerID sessions, troubleshooting commands |
| `01-setup.md` / `.docx` | Workstation setup: tools, Rancher, Azure, clusters, namespaces, emerID, access check |
| `02-runbook.md` / `.docx` | Troubleshooting runbook: what to run, when, where |
| `03-microservices.md` / `.docx` | Microservices troubleshooting notes: source vs victim, dependency mapping, failure patterns, timeout budgets, tracing |

Quick start:

```bash
cp k8s_profile.sh ~/.k8s_profile
echo '[ -f ~/.k8s_profile ] && source ~/.k8s_profile' >> ~/.bashrc
exec bash && khelp
```

# Prompt: implement the "Anchor command center" UI in the existing SRE agent

You are working in my existing SRE incident-triage agent repo. Add a new "command center" view modelled on
the Anchor design described below. Every element must be driven by real agent data (stored runs and the
live event stream). No mock, demo or hard-coded incident data anywhere. If a panel needs data the backend
does not produce yet, add that backend capability properly or hide the panel. Never fake it.

## Step 0: inspect before building
1. Find the UI framework, the run/event model, and how the UI receives progress (SSE, websocket or polling).
2. List the event types the backend emits today (for example run_started, llm_step, agent_note,
   tool_started, tool_finished, rca_ready, run_finished, run_failed) and the RCA JSON shape.
3. Write a short mapping table: each panel below → the event or field that feeds it → "exists" or
   "needs backend change". Show me the table and stop for approval before writing UI code.

## Layout, top to bottom

### 1. Command header (sticky)
- Left: a 14px breathing dot in the accent colour, the "ANCHOR" wordmark (700, letter-spacing 0.2em),
  then a mono meta line built from real data: "<n> MCP servers · <n> reachable".
- Centre: a pill input labelled "ask anchor" (mono label inside the pill), with the placeholder
  "Describe a problem or paste an incident number (INC…)". If the text matches the incident-number regex,
  start a triage for it. Free text starts a free-form investigation only if the backend supports it;
  otherwise show an inline hint and do nothing.
- Right: "Play"/"Pause" and "Replay" pill buttons that control replay of the selected run's stored events.
  Both are disabled while a run is live.

### 2. Intake strip (4 cards, wrap on small screens)
- **Webhook · ServiceNow**: the latest auto-triaged incident and its received time. Show a blinking dot
  only while that run is still running.
- **Prompt · Engineers**: the number of runs started by people today, and the latest free-text question
  if one exists.
- **API**: runs started by other systems, if the backend records a trigger source. Otherwise hide the card.
- **MCP servers (dashed border)**: one dashed pill per server that is configured but unreachable or
  disabled, from the sources endpoint. If every server is reachable, show "all sources online".
- If runs have no trigger-source field yet, add `trigger: webhook|user|api` to runs. That is a backend change.

### 3. Main area: two columns (left flex 999 1 640px, right 1 1 420px, max 520px)

**Left column**
- **Incident header**: a blinking mono line "● LIVE · <INC> · P<n>" while a run is live (static
  "TRIAGED · …" once finished), an h1 with the short description (30px/700), and on the right a mono clock
  "T+<elapsed>s · <n> tool calls in flight".
- **Orbit (the centrepiece)**: a 600×620 SVG/absolute-positioned stage that scales down with its container.
  - Core at the centre: three concentric rings (dashed outer, two partial-arc rings rotating in opposite
    directions at 18s, 11s and 6s) around a 96px breathing circle. The circle shows "ANCHOR" plus a state
    line: `reasoning` | `calling` | `<n> tools live` | `awaiting you` (after rca_ready).
  - One 96px node per MCP server, placed evenly on a radius-215 circle. Generate the positions from the
    server list; do not hard-code six.
  - A beam (line) runs from the core to each node, with these states:
    - idle: 1px dashed, dim, node at 60% opacity, sub-label "standby".
    - calling (between tool_started and tool_finished on that server): 3px line in the source colour,
      animated dash flow, halo glow on the node, sub-label "calling", and the caption below the node
      shows `tool_name()`.
    - returned: 1.5px solid line at about 33% alpha, sub-label "✓ returned", and the caption shows the
      one-line preview from tool_finished.
    - failed: red dashed beam, sub-label "failed", and the caption shows the error class (no raw error text).
- **Thought stream panel**: a mono heading "ANCHOR IS THINKING", then a 22px/500 paragraph with the latest
  agent_note or LLM reasoning text, then the last 3 feed lines as a grid of [mono time | **tool name in
  its source colour** + one-line text]. Wrap the paragraph in `aria-live="polite"`.

**Right column**
- **Confidence card**: a 112px conic-gradient ring with a stage label and the hypothesis text.
  - Until rca_ready: the label is "FORMING", the ring is empty, and the text is the latest interim
    hypothesis if the agent emits one.
  - After rca_ready: map the real confidence (high/medium/low) to a ring fill of 100/66/33% and the labels
    ROOT CAUSE / STRONG / NARROWING. Show the probable_cause.
  - Never show a numeric % unless the backend returns a real numeric score.
  - Optional backend change: let the agent emit `hypothesis` events {stage, text} between rounds.
- **Live path card** "AGENT PROBING HOP BY HOP": a vertical chain of hops joined by short 2px wires.
  Each hop shows its name, "via <source>" in mono, and a status of `not checked` | `probing…` | `ok` |
  `suspect` | `fault`, with matching tinted backgrounds. The probing state gets a scanning outline
  animation; fault gets a halo.
  - Data: derive hops from RCA `evidence[]` plus per-source tool activity. For true hop-by-hop status,
    add `source_verdicts[{source, component, status: ok|suspect|fault, note}]` to the RCA contract and an
    optional `verdict` field on tool_finished.
- **Precognition card** "FAILURES THAT HAVEN'T HAPPENED YET": render only if the backend returns
  `similar_risks[{service, why, eta?, severity}]`, for example from a follow-up tool that searches other
  services for the same pattern. Otherwise show the empty-state sentence: "Once the root cause is known,
  the agent checks other services for the same pattern." Do not invent ETAs.
- **Fix card** "RECOMMENDED FIX":
  - Show the top recommended_actions entry.
  - "Approve" must call the EXISTING gated action endpoint (post work note or draft rollback MR). Open a
    native `<dialog>` that names the exact target and says the action is audit-logged. Never auto-execute.
  - Render the "actual vs projected" bar chart only if the backend provides real series data: the actual
    error-rate points from the Datadog tool result. Draw the projection only if a real projection exists;
    otherwise show the actual series alone.

### 4. Time machine (full-width footer panel)
- A range slider over the selected run's stored events (0…N-1), with the label "<HH:MM> · step i of N".
- Scrubbing re-runs the same reducer over `events.slice(0, i+1)`, so every panel rewinds consistently.
  Play advances one event about every 1.2s; Replay restarts from 0.
- Four tick labels under the slider at real milestones: run started, first tool returned, rca_ready,
  finished.

## Visual tokens (CSS variables)
- Background #07090D with a 48px grid of 1px #0E131B lines. Panels rgba(10,14,20,.85), 1px border #161D28,
  radius 16px, padding 20px. Pills radius 999px.
- Text: body #D9E1EA, headings #F4F8FC, secondary #A7B2C0 / #8A94A3, muted #6B7686, faint #4F5A6A.
- Accent #7FD4FF. Semantic colours: ok #8FE3A5, suspect #F2C27A, fault #FF8F8F, violet #B49CFF.
- Source colours are fixed everywhere and defined once in a map:
  - ServiceNow #B49CFF, Kibana #FFB27A, Kubernetes #5CE0D2, Datadog #FF8FC0, GitLab #8FE3A5,
    Firewall/Panorama #E8D46A.
  - Unknown sources get a generated hue at the same lightness.
- Fonts: Space Grotesk (UI) and JetBrains Mono (tool calls, ids, times, labels), self-hosted woff2. No
  Google Fonts at runtime. 24-hour times.
- Section labels: mono 11px, letter-spacing 0.12em, uppercase, muted, or in the source/semantic colour.

## Motion
- Keyframes: spin, counter-spin, flow (stroke-dashoffset), halo (box-shadow pulse), breathe (scale 1.06),
  scan (outline-offset pulse), blink.
- Animate only what reflects live state: calling beams and nodes, the probing hop, the live dot, and the
  core rings while a run is active. Everything is static once the run finishes.
- `prefers-reduced-motion: reduce` turns off all animation; states stay legible through colour and labels.

## Responsive and accessibility
- Under 860px: the columns stack, the orbit scales to the container width, intake cards go 2×2, and the
  header input takes a full row.
- Use real `<button>`, `<label>` + `<input>` and a labelled range input. Touch targets ≥44px. Text
  contrast ≥4.5:1 on the dark panels. Icon-only controls get aria-labels. No emoji.

## Implementation rules
- One reducer (`(state, event) → state`) feeds every panel. Live mode, replay and scrubbing all use it.
- Component split:
  - CommandHeader, IntakeStrip, IncidentHeader, Orbit (Core, ToolNode, Beam), ThoughtStream
  - ConfidenceCard, LivePath, Precognition, FixCard, TimeMachine
  - theme.css with the tokens
- Every backend change you add (trigger source, hypothesis events, source_verdicts, similar_risks) gets
  a schema update, tests, and graceful UI fallback when the field is absent.
- Do not touch security behaviour: write actions stay gated, confirmed and audit-logged; identity comes
  only from the auth-layer header.
- Finish with a list of the files you changed and the commands to run the UI against a real run.