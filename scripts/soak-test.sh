#!/bin/bash
# Read-only soak test: watches SMC fan registers while you use the Mac
# normally (load, sleep, panel closed) and reports how often the fan mode
# left manual control. Pick a FanMacly mode in the panel first.
#
#   bash scripts/soak-test.sh [minutes]    (default 30)
set -euo pipefail
cd "$(dirname "$0")/.."
minutes="${1:-30}"
swift build -c release --product fanmacly-probe >/dev/null
mkdir -p build/soak
log="build/soak/soak-$(date +%Y%m%d-%H%M%S).log"
echo "Watching for $minutes min → $log"
.build/release/fanmacly-probe --watch=$((minutes * 60)) | tee "$log" | awk '{ printf "\r%s", substr($0, 1, 150) }'
echo
python3 -I - "$log" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
modes = [re.findall(r"md=(\S+?)/", l) for l in lines]
manual = [all(m == "1" for m in ms) and ms != [] for ms in modes]
drops = sum(1 for a, b in zip(manual, manual[1:]) if a and not b)
share = 100 * sum(manual) / max(1, len(manual))
hot = [float(m.group(1)) for l in lines if (m := re.search(r"cpu=([\d.]+)", l))]
print(f"samples: {len(lines)}; manual control: {share:.1f}%; manual→auto transitions: {drops}")
if hot: print(f"CPU control temperature: min {min(hot):.1f} °C, max {max(hot):.1f} °C")
print("Helper events: log show --last 1h --predicate 'subsystem == \"app.fanmacly.helper\"'")
PY
