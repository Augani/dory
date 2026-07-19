# Burned-Caption Timing Handoff

These are concise 3–6 word phrase groups for the burned-in treatment. They sit inside the measured cue envelopes in `audio-cue-report.json`; they are editorial interpolation, not word-level forced alignment. Check them by ear against the final mix before locking the render.

Show one group at a time in the lower safe zone. Each group needs a deterministic hard kill at its end time so adjacent phrases never overlap.

| Group | Start | End | Burned-caption copy |
| --- | ---: | ---: | --- |
| 01A | 0.450 | 2.530 | Switching Docker runtimes shouldn't |
| 01B | 2.530 | 4.781 | mean rebuilding your local world. |
| 02A | 4.950 | 6.760 | Images. Volumes. Networks. |
| 02B | 6.760 | 8.833 | Ports. Container state. |
| 03A | 9.000 | 11.560 | Dory discovers Docker Desktop, |
| 03B | 11.560 | 14.611 | OrbStack, Colima, and other compatible sources. |
| 04A | 14.780 | 17.220 | It reads first—checking capacity |
| 04B | 17.220 | 19.623 | and collisions before writing to Dory. |
| 05A | 19.690 | 21.670 | Dory imports transactionally, |
| 05B | 21.670 | 22.520 | verifies, |
| 05C | 22.520 | 24.490 | and never deletes the source. |
| 06A | 24.560 | 27.510 | Dory. Your complete local Linux workspace. |
| 06B | 27.510 | 28.430 | Bring the work. |
| 06C | 28.430 | 29.893 | Leave the lock behind. |

Implementation notes:

- Keep the cue gaps empty; do not hold the previous phrase across silence.
- Treat **Dory**, **READS FIRST**, **transactionally**, and **never deletes** as emphasis candidates, using the established light palette.
- Preserve the subtitle wording even if scene headlines use shorter display copy.
- The final 0.307 seconds after narration ends is reserved for an uncluttered logo/URL hold.
