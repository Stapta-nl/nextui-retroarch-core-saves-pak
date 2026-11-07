# Hardware verification: Core States

Core States has only been exercised by the automated suites so far. This guide
says what that does and does not prove, how to test on a device, and exactly what
evidence to attach to the pull request so a reviewer can check the result without
the device.

## What the automated tests already cover

`make test` runs three suites. The mount suite makes real bind mounts inside a
private namespace (`unshare -rm`), so mount behaviour itself is exercised, but
against a fake SD card on a Linux host.

Covered:

- Naming of states for all five NextUI formats, both directions, and the slots
  (0 to 7, 8 hidden, auto), including thumbnails and unrecognised files.
- Convert and Revert as one transaction for saves and states: one backup, one
  journal, rollback after a failure, recovery after an interruption.
- One mount layer mounting `/Saves/<tag>` and the NextUI states folders together,
  at boot, on re-apply, refusing to hide files, and removed on revert.
- The Core States setting, the menu rows, Profiles ownership (against a stub).

**Not covered, and what this guide is for:**

| Not verified | Why it matters |
| --- | --- |
| Everything on a real device and its real NextUI | Paths, permissions, `batmon`, the SD card filesystem, the real boot sequence |
| NextUI picking up the format change on the next game launch | Taken from the source (`CFG_init` reads `minuisettings.txt` once per process), never observed |
| States loading and saving through the bind mount | The tests only write files through the mount |
| The real Profiles.pak layer 10, and switching profiles with states mounted | Only a stub is used |
| `h700`'s `/mnt/SDCARD` symlink, `tg5050`, `my285` | Only a desktop platform is simulated |
| Desktop RetroArch reading the renamed, uncompressed or headerless states | From memory of libretro; the source could not be fetched |
| The `minui-presenter` buttons for the "restore format?" prompt | Only the logic behind it is tested |
| A power loss in the middle of Convert | Recovery is simulated, not interrupted for real |

Facts taken from the NextUI source rather than a device: states live in
`.userdata/shared/<TAG>-<core>` where `<core>` is the core file name without
`_libretro` (the pak's `EMU_EXE`); MinUI has 8 manual slots (0 to 7), slot 8 is a
hidden default, slot 9 is the auto-resume slot; MinArch reads compressed and raw
states alike; the setting key is `stateFormat` in `minuisettings.txt`.

## Before you start

1. **Copy the SD card's `Saves/`, `States/` (if it exists), `Roms/` listing and
   `.userdata/shared/` to a computer.** The pak makes its own backups, but test
   code deserves one you control.
2. Note the device, platform (`tg5040`, `tg5050`, `h700` or `my285`), NextUI
   version and the current **Save state format** in NextUI Settings.
3. Pick one game on a system you can play, and make states in a few slots
   (for example 0, 2 and 5), plus let the device power off once so an auto state
   exists. Know which system (tag) and core it uses.
4. Pick a second system you have **never launched**, to test a states folder that
   does not exist yet.
5. Install the pak: `Tools/<PLATFORM>/RetroArch Core Saves.pak`, from the zip
   built from the PR (`make release`, or the zip attached to the PR).

## Collecting evidence

Do the collection **after each step** (before the next step changes things).

**With a shell on the device** (SSH, telnet or adb): `docs/` is not part of the
release zip, so copy `docs/collect-evidence.sh` from the repository onto the SD
card (for example to its root) and run:

```bash
sh /mnt/SDCARD/collect-evidence.sh
```

It writes `core-states-evidence-<time>/` (and a `.tar.gz`) onto the SD card root,
with `summary.txt` on top. It copies only small text files, and lists and checksums
your states and saves; it never copies them. Rename the folder after each step, for
example `T3-after-reboot`. On `h700` pass the path explicitly if `/mnt/SDCARD` is
a symlink on your device: `sh collect-evidence.sh /mnt/sdcard h700`.

**Without a shell**, take the SD card to a computer and copy these (the pak data
folder is named after the pak folder, normally `RetroArch Core Saves`):

| File or folder | What it shows |
| --- | --- |
| `.userdata/shared/minuisettings.txt` | `stateFormat` and `saveFormat` |
| `.userdata/shared/RetroArch Core Saves/` (all of it) | `conversion-report.txt`, `enabled`, `mounts.conf`, `states-mounts.conf`, `features.conf`; `operation.journal` must be **absent** |
| `.userdata/<platform>/logs/core-saves.txt` and `mounts.txt` (and `.old`) | What the pak and mountctl did |
| A listing of `States/Cores/` and `Saves/Cores/` | Where the files ended up (names and dates) |
| A listing of `.userdata/shared/*-*` folders | The NextUI states folders (empty on a computer while mounted) |
| A listing of `.core-saves-backups/<newest>/` | The backup (`Saves/` and `States/`) |
| `.profiles/active` and `core-saves-profile`, if Profiles.pak is used | Ownership |

Also take **photos or screenshots** of each dialog and of the menu. These cannot be
collected from files.

Mounts are not visible from a computer: the bind mounts exist only on the device.
That is why a states folder looks empty on the computer while the states load fine
on the device. With a shell, `mountctl-status.txt` and `mountinfo-filtered.txt`
from the script show them directly.

**Proving the states were not altered:** only file names change. For any state, the
checksum of the renamed file in `hashes-States-Cores.txt` must equal the checksum of
the original in `hashes-backup-<time>-enable-States.txt`. For example
`Game.state` (tree) against `Game.gb.st0` (backup).

## Test steps

For every step: do it, collect evidence, and note pass or fail. Stop and report at
the first failure. Do not retry before collecting evidence.

### T1. Install and menu

Open the pak. **Expect** a *State Status* block with: Core States (`On`, selectable),
State Format (your current format), States (`Off`), States Location (`/States/Cores`),
and the usual Convert action.
Evidence: photo of the menu, `summary.txt` (version, `stateFormat`).

### T2. Convert (saves and states)

Choose Convert. **Expect** a confirm dialog that mentions states and the
RetroArch (compressed) format; then a result like "Core saves and states are active
(N states renamed)", with no issues.
Then check:

- `States/Cores/<Core>/` holds the states with RetroArch names
  (`Game.state`, `Game.state2`, `Game.state5`, `Game.state.auto`, no `.st0`).
- The NextUI folder `.userdata/shared/<TAG>-<core>` is empty on a computer.
- NextUI Settings shows **Save state format: Retroarch (compressed)**.
- `enabled` contains `states=1`, `old_state_format=<your original>`, `states_backup=<path>`.
- `conversion-report.txt` ends "Issues requiring attention: 0".
- The checksums match the backup (see above).
- Launch the game: **load every slot** you made; each loads.
- Save a new state in a free slot and quit: a new file appears in `States/Cores/<Core>/`.

Evidence: dialog photos, the collected folder, a note of which slots loaded.

### T3. Boot

Power off and on. **Expect** no dialog about mounts. Open the game and load a state;
use the game switcher's Resume. Evidence: collect again; `mounts.txt` must show an
`apply --boot` and `mounted ...` lines for the `/Saves/<tag>` folders **and** the
`.userdata/shared/<TAG>-<core>` folders, with no `ERROR`.

### T4. Auto-resume state

Play, then power off with the power button. Boot, resume. **Expect** the game resumes
and `Game.state.auto` in `States/Cores/<Core>/` has a fresh modification time.
Evidence: the listing before and after.

### T5. A system whose folder did not exist before

After T2, launch the system you had never played, make a state and quit.
**Expect** the state in `States/Cores/<Core>/` (not in `.userdata/shared`), because
Convert creates and mounts the folder up front. Evidence: the listing.
(If a launcher loads a core file named differently from its `EMU_EXE`, the real
folder would differ; report the system and the names if the state ends up elsewhere.)

### T6. Setting Off, and opting in later

Revert first (T8 or T9) so the setup is not running. Set **Core States** to `Off`
(select the row), then Convert. **Expect** a confirm that mentions saves only;
`enabled` has `states=0`; no `states-mounts.conf`; `stateFormat` unchanged; the
NextUI states folders untouched.
Now select the row again to turn it `On` (it is selectable because states are not
active): **Re-apply Core Save Mappings** appears. Run it. **Expect** the states to
join: `states=1`, `old_state_format` equal to the original format.
Evidence: both collections and the menu photos.

### T7. Re-apply is idempotent

Run Re-apply (or Convert) again with nothing changed. **Expect** no duplicates and no
`core-conflict` files in `States/Cores/`, and `old_state_format` unchanged.
Evidence: listing before and after.

### T8. Revert and restore the format

Choose Revert. **Expect** a confirm, then the question "Restore the state format from
before Core States?". Choose **RESTORE**. **Expect** the original format back in
NextUI Settings; the states back in `.userdata/shared/<TAG>-<core>` under the old
names; the layer and mounts gone. If your original was MinUI, any state without
exactly one matching ROM stays in `States/Cores/` and the result says it will not
load. **Load the states in the game.** Nothing may be deleted from `States/Cores/`.
Evidence: result dialog photo, `conversion-report.txt`, collections before and after.

### T9. Revert and keep the format

Convert again, then Revert and choose **KEEP**. **Expect** format RetroArch
(compressed) and the states under RetroArch names in the NextUI folders, loading
normally. Evidence as T8.

### T10. Interrupted Convert (optional, only with your SD card copy)

During Convert (the "Moving..." step), hold the power button to cut power. Boot and
open the pak. **Expect** "Recovered an interrupted enable operation" and the
previous layout restored: states back in the NextUI folders, format restored, no
`operation.journal`. Evidence: dialog photo, collection. Skip this if you do not
want to risk the card.

### T11. Profiles.pak (only if you use it)

Convert as profile A. Switch to profile B. **Expect** Convert refused (owner A),
Revert still available, and no states mounts for B. Switch back to A: mounts return.
Evidence: `mounts.txt`, `.profiles/core-saves-profile`, the menu photo.

### T12. Syncthing and desktop RetroArch

Sync `States/Cores` with a desktop RetroArch whose states are sorted by core. Load a
device state in desktop RetroArch (same core, compatible version), and save one on
the desktop and load it on the device. Note the `.png` thumbnails, and whether
`.state.auto` crosses over. **Expect** loading to work only when core and version
match. Evidence: file names and checksums on both sides, a note of the core
versions, whether each load worked.

## Result table for the pull request

Copy this into a PR comment and fill it in. Attach the collected folders or archives.

```text
Device / platform:
NextUI version:
Pak build (commit):
Original state format:

T1  menu                      PASS / FAIL   notes:
T2  convert                   PASS / FAIL   notes:
T3  boot mounts               PASS / FAIL   notes:
T4  auto-resume               PASS / FAIL   notes:
T5  folder that did not exist PASS / FAIL   notes:
T6  setting off / opt-in      PASS / FAIL   notes:
T7  re-apply idempotent       PASS / FAIL   notes:
T8  revert, restore format    PASS / FAIL   notes:
T9  revert, keep format       PASS / FAIL   notes:
T10 interrupted (optional)    PASS / FAIL / SKIPPED   notes:
T11 Profiles (if used)        PASS / FAIL / N/A       notes:
T12 Syncthing / desktop       PASS / FAIL / SKIPPED   notes:
```

## If something goes wrong

1. Do not retry. Collect the evidence first.
2. Re-opening the pak rolls back an interrupted operation by itself. The backup is
   in `.core-saves-backups/<time>-enable/` (`Saves/`, `States/`, `minuisettings.txt`).
3. To undo by hand: put the files of `States/<TAG>-<core>/` in the backup back into
   `.userdata/shared/<TAG>-<core>/` and set `stateFormat` in
   `.userdata/shared/minuisettings.txt` back (the value is in the backup's
   `minuisettings.txt`).
4. Your SD card copy from "Before you start" is the last resort.
