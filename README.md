# openzoo — Omarchy bar widget

Ask 480+ models from the bar. No account, no API key, no subscription.

Every call is priced before it runs and paid per request from a local burner
wallet over x402, so there is nothing to sign up for and nothing to cancel. The
widget shows what you have actually spent, live.

It also searches your own corpus: type a fragment of something you half-remember
and get the actual slice back, matched semantically across far more text than
fits in any context window.

**Local by default. Nothing leaves your machine unless you set a hosted key.**

## Install

```
omarchy plugin add https://github.com/staccDOTsol/omarchy-openzoo-plugin.git --enable
```

Enable, disable, or remove later with:

```
omarchy plugin enable openzoo --section right
omarchy plugin disable openzoo
omarchy plugin remove openzoo
```

## What it needs

A **leCore** daemon running on loopback. leCore is MIT-licensed and self-hosted:
<https://github.com/AnOversizedMooseWithSocks/leCore>. The widget talks to
`http://127.0.0.1:8787` and nothing else — no account, no API key, no network.

If the daemon isn't running the widget says so plainly and does nothing. It
never hangs the bar.

## Why it isn't just fuzzy search

Omarchy's existing providers match strings. This one searches *meaning*, over a
corpus that was bound once and is then queried cheaply forever. That is the
shape of workload holographic memory is for: one large body of text, questioned
constantly. "That Solana fee thing I copied last week" is a query no
string-matcher can answer.

## Settings

| setting | default | what it does |
|---|---|---|
| `endpoint` | `http://127.0.0.1:8787` | The local daemon. Loopback by default. |
| `token` | `hrr-lab-token` | Bearer token the daemon expects. |
| `tenantId` | `claude-code` | Namespace inside the daemon. |
| `contextId` | *(empty)* | **Required.** Which bound corpus to search (`ctx_…`). |
| `topK` | `8` | Retrieval breadth. This is the real quality knob. |
| `hostedKey` | *(empty)* | **Leave empty to stay local.** |

`contextId` has no picker because the daemon exposes no list endpoint — you
paste the id of the corpus you bound.

## Going hosted (optional)

Setting `hostedKey` to an `ozk_live_…` key opts in to hosted models and corpora
that follow you between machines. **This sends your queries off the machine.**
It is off by default, it is a single explicit field, and the panel header says
which mode you are in every time you open it.

## Status

Written against the Omarchy Quattro plugin format (`schemaVersion: 1`,
`bar-widget`) and against a live leCore daemon — the recall request and response
shapes were read off a running instance, not guessed.

**It has not yet been loaded by a real `omarchy plugin add`.** No Omarchy
machine was available when it was written, so treat the QML as unverified
against the real host API until someone runs it.

## License

MIT.
