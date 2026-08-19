# HANDOFF — openzoo memory (Omarchy bar widget)

Written 2026-08-19. State of play for whoever picks this up next.

## Where things are

| what | path |
|---|---|
| plugin source | `/Users/stacc/omarchy-openzoo-plugin` |
| GitHub | https://github.com/staccDOTsol/omarchy-openzoo-plugin (public, `main`) |
| Omarchy checkout (upstream, for its validator/tests) | `/Users/stacc/omarchy` |
| test VM | `~/vms/omarchy/` — `run.sh`, `omarchy.qcow2` (60G), `omarchy-4.0.0.iso` (5.84G) |

Files that matter: `manifest.json` (schema the shell enforces), `Panel.qml`
(the `barWidget` entry point), `Service.qml` (talks to the daemon).

## What is already verified — do not redo

- `bash /Users/stacc/omarchy/bin/omarchy-plugin-validate /Users/stacc/omarchy-openzoo-plugin` → **exit 0**.
  That script mirrors `shell/services/PluginRegistry.qml`, so it is the same
  schema the running shell applies: schemaVersion, required fields, relative
  entry points that exist, no symlinks, non-reserved id.
- Imports match Omarchy's own bundled plugins exactly — `qs.Commons`, `qs.Ui`,
  `Quickshell`, `Quickshell.Io`, `QtQuick{,.Controls,.Layouts}`. Verified by
  diffing against `grep -rh '^import qs\.' /Users/stacc/omarchy/shell/plugins/`.
- Secret scan clean before the repo was made public (only token present is the
  loopback default `hrr-lab-token`; `hostedKey` ships empty).

**Not yet verified: anything requiring a running compositor.** `qmllint` is not
available on the macOS host and Quickshell is Linux/Wayland-only, so the QML has
never actually been *loaded*. That is the entire point of the VM.

## The VM

Omarchy ships **x86_64 only** — there is no `aarch64` anywhere in its
`install/`. On an Apple Silicon host that means QEMU **TCG emulation**, not
virtualization, and Hyprland renders through llvmpipe with no GPU. It is slow by
construction. An ARM Arch VM would be fast but would not be Omarchy, so it would
not test what needs testing.

```bash
~/vms/omarchy/run.sh --install   # boot the ISO (first time only)
~/vms/omarchy/run.sh             # boot the installed disk afterwards
```

State at handoff: **install running** ("Installing Omarchy", progress bar).

The window looks tiny during install and that is the GUEST, not the window: the
installer runs in a 640x400 framebuffer console. The `xres=1920,yres=1200` hint
on `virtio-vga` only applies once a real driver sets the mode, i.e. when
Hyprland starts post-install. `zoom-to-fit=on` is set so the window can be
dragged larger and the output scales meanwhile.

Expect the AUR builds to dominate the wall clock — `install/omarchy-base.packages`
pulls `quickshell-git`, which is compiled from source, under emulation.

- `Ctrl+Alt+G` releases the mouse/keyboard grab, `Ctrl+Alt+F` fullscreen
- window is titled `QEMU`; closing it kills the VM
- SSH is forwarded: host `localhost:2222` → guest `:22`
- A QEMU monitor socket is at `~/vms/omarchy/monitor.sock`. Screenshot the guest
  headlessly with:
  ```bash
  cd ~/vms/omarchy && (echo "screendump /tmp/om.ppm"; sleep 3) | nc -U monitor.sock
  sips -s format png /tmp/om.ppm --out /tmp/om.png
  ```
  Use this instead of asking a human to look at the window.

## Install the plugin in the guest

```bash
omarchy plugin add https://github.com/staccDOTsol/omarchy-openzoo-plugin.git --enable
```

This works as written — the URL in `README.md` and in `manifest.json`'s
`repository` field both match the real repo.

## The one landmine waiting in the guest

The widget defaults to `endpoint = http://127.0.0.1:8787`. **Inside the VM that
is the guest's own loopback, not the Mac's**, so the daemon on the host is
unreachable and the widget will look broken while being correctly configured.

Two ways out, pick one:
- run a leCore daemon inside the guest, or
- point `endpoint` at the host. Under QEMU's user-mode networking the host is
  `10.0.2.2`, so `http://10.0.2.2:8787` — and the host daemon must be listening
  on more than loopback for that to connect, which it currently is not
  (`127.0.0.1:8787`).

Also: `contextId` defaults to empty and is **required** — the daemon has no list
endpoint, so a blank context id yields nothing and looks identical to a
connection failure. Get one from `~/.claude/memory/lecore-sessions.jsonl`.

## Unrelated work left mid-air in the same session

Not this plugin, but uncommitted on disk and easy to lose:

`/Users/stacc/claude/x402-tokens/src/server.ts` has **two staged, undeployed** fixes:
1. `~line 1260` — pin `provider: { order: ["anthropic"] }` for `anthropic/*`.
   Fable-5 was 400ing with `messages.2: role 'system'` on a body whose roles were
   `suau` (bisected: proxy forwards legal, gateway forwards legal, and the same
   body direct to OpenRouter with the provider pinned returns 200). Our account
   routes `anthropic/*` to Azure, which 401s, and the fallback rejects a legal body.
2. `~line 1441` — the provider-error refund carried `!paidByCredit`, so prepaid
   callers were billed for every provider error and refunded nothing.

Neither is deployed; `fly deploy` was deliberately not run.
