# DRAFT — NOT PUBLISHED

**What this is:** a draft sequel post for seevali.dev, to be published by the owner by pushing to the `sites/seevali.dev` repo (which auto-deploys). Nothing here is live until that push happens. Suggested slug: `builds/the-loop-leaves-the-nest`. Written in the owner's plain first-person voice.

---

# The loop leaves the nest

A few weeks ago I wrote about a repo called `ralph-loop-demo` — a little machine that builds software by itself, one story at a time, each step a fresh Claude Code session with no memory of the last. I split it into two tracks. A "Demo Track" you could clone and run: a React app skeleton and a fully-written PRD for an Exchange Rates dashboard, sitting at the repo root, waiting to be built. And a "System Track" under `system/`, where I used the loop to improve the loop itself — the recursion I actually cared about.

I've now deleted the Demo Track. The repo has a new name — **Ergane** — and it runs on one track. Here's why, because the reasoning is the interesting part.

## The demo never earned its keep

The Demo Track was a promise, not a record. I never actually ran it. The `src/` folder still held the vanilla Vite scaffold. `docs/stories/` was empty. The PRD and the epic were real and carefully written, but no agent had ever touched them — running the loop costs real API money, and every time I sat down to do it I found something more useful to spend the budget on. So the "showcase" showed nothing. It was a diagram of a thing that could happen, dressed up as a thing that had happened.

Meanwhile the System Track was the opposite: every chapter under `system/chapters/` is a real run, with real commits, real code review, real bugs the loop tripped over and fixed. The part I'd framed as scaffolding was the part doing the work. The part I'd framed as the main event was inert.

Once I saw it that way, the Demo Track wasn't neutral weight. It was actively misleading — it made the repo look like a demo of a loop instead of what it is: the loop, and the place the loop is built.

## What replaced it

I didn't want to lose "clone it and watch it build an app," though. That's a genuinely good first experience. So I moved it somewhere better: into the installer.

Ergane ships with a Node CLI that installs the loop into any repo. It now has a third task source — `--task-source example` — that drops the same Exchange Rates PRD and epic into a fresh project, ready to run, no TODOs to fill in. The difference is that the example now travels through the *real install path*. When you watch it build the dashboard, you're watching exactly the machinery a real user gets, not a special in-repo copy that only exists to be demoed. The demo became a test of the product instead of a decoration on top of it.

So the experience survived. It just moved from being a static thing in the repo to being an output of the thing the repo actually is.

## The name

`ralph-loop-demo` stopped being true the moment the repo *was* the loop rather than a demo of it. "Ralph" is Geoff Huntley's name for the pattern — run the agent in a fresh session, in a loop, against a spec — and I still credit it everywhere, because the engine genuinely speaks Ralph. But the product needed its own name.

**Ergane** is an epithet of Athena: *Athena Ergane*, "Athena the Worker," the goddess as patroness of craftspeople — the one who actually makes things. It fits because everything I build lives under an ecosystem called Metis, and my projects are named from Greek myth: Kleos, Nyx, Mneme, Moneta. And in the myths, Metis is Athena's mother. A working craftswoman born out of Metis is exactly the relationship this tool has to the monorepo it grew up in. The name was also, pragmatically, the one clean candidate — free on npm, free on GitHub, no trademark landmines. Sometimes the poetry and the paperwork agree.

## What carries over

I didn't rewrite history. That's a rule I hold in this repo: history over tidiness. The `TIMELINE.md` still narrates the two-track era, tags and all. The old chapters stay exactly where they are, closed and dated. The original post — the one you might have arrived from — still stands as a record of what the repo was; I've only added a banner pointing here. Nothing that was true got edited into pretending it was never true. It just got marked as past.

The whole rationale for the change lives in the repo too, as a chapter (`system/chapters/2026-07-07-single-track/`), written to the same standard as everything else: a fresh reader with no context should be able to pick it up and act on it.

## What's next

Two things I still owe this project. First, an actual live run with write-back turned on — the loop taking a GitHub issue, opening a pull request, and reporting its own progress back onto the issue, for real, with money on the line. I've built all of it; I haven't yet let it loose end to end in public. That's the weekend job. Second, publishing Ergane to npm so the install command is `npx @seevali/ergane install` instead of "clone this and run the script." Both are small, and both are the difference between a tool that works and a tool people can use.

The loop spent its whole life so far building itself. It's about time it left the nest.
