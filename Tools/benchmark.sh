#!/bin/zsh
# Measures memory (physical footprint), idle CPU/energy and on-disk size of
# Tempo next to the apps it replaces. Launches each app in the background,
# lets it settle, samples, then quits the ones that weren't already running.
#   ./Tools/benchmark.sh [settle-seconds]
set -u
apps=(Tempo AltTab Maccy Amphetamine "Dropzone 4")
settle=${1:-30}

pid_of() { pgrep -f "/Applications/$1.app/Contents/MacOS/" | head -1; }

started=()
for app in $apps; do
    [[ -d "/Applications/$app.app" ]] || { echo "skip: $app not installed"; continue; }
    if [[ -z "$(pid_of $app)" ]]; then
        open -g -a "$app" && started+=("$app")
    fi
done
echo "Letting apps settle for ${settle}s…"
sleep $settle

printf "%-12s %10s %10s %9s %8s\n" App Memory "Idle CPU" Energy Size
for app in $apps; do
    pid=$(pid_of $app)
    [[ -n "$pid" ]] || continue
    mem=$(footprint $pid 2>/dev/null | awk '/Footprint:/{print $(NF-5), $(NF-4)}')
    # Average of 6 five-second samples, skipping top's first (meaningless) one.
    read cpu energy <<< $(top -l 7 -s 5 -stats pid,cpu,power -pid $pid \
        | awk -v p=$pid '$1 == p {n++; if (n > 1) {c += $2; e += $3}} END {printf "%.2f %.2f", c/(n-1), e/(n-1)}')
    size=$(du -sh "/Applications/$app.app" | cut -f1)
    printf "%-12s %10s %9s%% %9s %8s\n" "$app" "$mem" "$cpu" "$energy" "$size"
done

for app in $started; do
    [[ "$app" == Tempo ]] || osascript -e "quit app \"$app\"" >/dev/null 2>&1
done
