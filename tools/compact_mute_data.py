#!/usr/bin/env python3
"""Convert SpellMuteData table entries from Lua tables to string literals.

Before: [6343]={539874,539880,542331,951192},
After:  [6343]="539874,539880,542331,951192",

Only converts within the Resonance_SpellMuteData table (lines 4–170835).
Leaves VoxFIDs, RaceCSD, and other tables untouched.
"""

import re
import sys
from pathlib import Path

PATTERN = re.compile(r'^\[(\d+)\]=\{([\d,]+)\}(,?)$')

def compact(filepath: Path) -> int:
    lines = filepath.read_text().splitlines(keepends=True)
    in_smd = False
    converted = 0

    for i, line in enumerate(lines):
        stripped = line.strip()
        if not in_smd:
            if 'Resonance_SpellMuteData' in line and '=' in line:
                in_smd = True
            continue

        # End of SpellMuteData table
        if stripped == '}':
            break

        m = PATTERN.match(stripped)
        if m:
            sid, fids, comma = m.group(1), m.group(2), m.group(3)
            lines[i] = f'[{sid}]="{fids}"{comma}\n'
            converted += 1

    filepath.write_text(''.join(lines))
    return converted


if __name__ == '__main__':
    path = Path(__file__).resolve().parent.parent / 'data' / 'SpellMuteData.lua'
    if len(sys.argv) > 1:
        path = Path(sys.argv[1])
    n = compact(path)
    print(f'Converted {n} entries to string format.')
