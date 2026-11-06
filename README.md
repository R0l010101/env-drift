# Env Drift Checker

Before you port a ticket from `prod` to `qa`, `staging` or `simulation`, `drift` tells you whether the target branch is missing something your code needs: another ticket that changed the same files, a database column, a function, a class, or a JS import. It checks the **backend (Laravel)** and the **frontend (React)** in one go.

Read-only: it only reads git history. It never checks out a branch, never changes files, and never touches a database.

Windows only (PowerShell 5.1, built into Windows).

## Install (once)

1. Copy or clone this folder anywhere, e.g. `C:\Users\<you>\tools\env-drift`.
2. **Double-click `install.cmd`.**
3. It shows the list of **projects drift will check**. If you use Local Dev Doctor, your list is copied from it. Otherwise type the **full path** of your backend folder, press Enter, then your frontend folder, press Enter. When the list is right, press **Enter**.
4. It asks `Test it now?`. Press **Enter** to see your tickets that are in prod but not in qa yet.
5. Close all open terminals (and restart Claude Code).

## Use

Type `drift` in any terminal: PowerShell, CMD, Git Bash. In Claude Code, type `!drift ...`.

| Command | When | What it answers |
|---|---|---|
| `drift ESCM-13883 simulation` | Before porting a ticket to one environment | Is it safe to port ESCM-13883 to simulation? |
| `drift ESCM-13883` | Before porting to all environments | Same, for qa, staging and simulation at once |
| `drift qa` | Any time | Which tickets are in prod (last 60 days) but not in qa yet? |
| `drift qa -Mine` | Any time | Same, only your own commits |

`ESCM13883` and `13883` work too. Options: `-Days 90` (overview window), `-Lookback 365` (how far back to look for related tickets, default 180), `-NoFetch` (skip `git fetch`), `-Path C:\...` (one repo only).

## Reading the result

```
--- simulation (origin/feature/simulation-ESCM-9179-qne)
[INFO] ESCM-13883 is not in simulation yet
[OK  ] 5 other ticket(s) that changed your files (last 180 days) are in simulation
[WARN] ESCM-13227 is NOT in simulation (2026-08-03) - it changed app/Services/CustomerService.php
[FAIL] your code uses 'set_as_ecr_recipient', but no migration in simulation creates it
         comes from database/migrations/2026_07_17_..._add_recipient_flags.php (added by ESCM-13070 - port it first)
=> NOT SAFE to port to simulation: fix the FAIL items first
```

| Tag | Meaning | What to do |
|---|---|---|
| `[OK  ]` | Fine | Nothing |
| `[INFO]` | Information | Nothing |
| `[WARN]` | Another ticket changed the same files and is not in the target | Check if your code depends on it. If yes, port it first |
| `[FAIL]` | Your code needs a column, function, class or file that the target does not have | Port the missing ticket first, or adjust your code |

The last line of every environment is the verdict: **SAFE**, **CHECK FIRST**, or **NOT SAFE**.

## What it checks

1. **Related tickets.** Every other commit that changed the same files in the last 180 days. Is it in the target? (Matched by commit message, so the `_qa` / `_staging` ports are recognized.)
2. **Database (backend).** Columns and tables your code uses that come from a migration the target does not have.
3. **Code your code needs.** PHP functions/methods you call (`pickDate()`), `use App\...` classes, and JS `import`s (file and named export) that do not exist in the target.

## Limits

- It relies on the ticket ID (`ESCM-12345` or `ESCM12345`) in commit messages. Commits without one are shown by their message.
- A `[WARN]` is a hint, not proof: two tickets can change the same file in unrelated places.
- The code checks are text searches, not a compiler. They catch missing names, not a method that exists in a different class.

## Settings

`drift.config` holds the source branch (`prod`), the ticket prefix (`ESCM`) and the environments (`simulation = feature/simulation-ESCM-9179-qne`). Edit it if a branch name changes.

## Ano ang ginagawa nito? (Tagalog)

Bago ka mag-port ng ticket mula `prod` papunta sa `qa`, `staging`, o `simulation`, sasabihin ng `drift` kung **may kulang sa target na kailangan ng code mo**. Halimbawa nito ang ibang ticket na gumalaw sa parehong file, column sa database, function, class, o import sa React. Sabay nitong sinusuri ang **BE (Laravel)** at **FE (React)**.

Wala itong binabago. Git history lang ang binabasa nito: walang checkout, walang binabagong file, at hindi nito ginagalaw ang database.

### Paano gamitin

1. **I-install (isang beses):** i-double-click ang `install.cmd`. Kung naka-install ang Local Dev Doctor, kokopyahin ang listahan ng project mo mula roon. Pindutin ang **Enter** hanggang matapos.
2. **Isara lahat ng terminal** at magbukas ng bago.
3. **Bago mag-port**, i-type:
   - `drift ESCM-13883 simulation`: ligtas bang i-port ang ESCM-13883 sa simulation?
   - `drift ESCM-13883`: sabay na sinusuri ang qa, staging, at simulation.
   - `drift qa -Mine`: ang mga ticket mo na nasa prod pero wala pa sa qa.
4. **Basahin ang huling linya** ng bawat env:
   - **SAFE** = puwede nang i-port.
   - **CHECK FIRST** = may ticket na gumalaw sa parehong file pero wala sa target. Tingnan kung kailangan ito ng code mo.
   - **NOT SAFE** = may column, function, o file na kailangan ng code mo pero wala sa target. Unahin munang i-port ang ticket na nakasulat.
