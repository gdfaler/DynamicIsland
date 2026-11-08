#!/bin/bash
# Fails if a string passed to L("…") has no entry in a Localizable.strings file.
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
keys=$(grep -ho 'L("\([^"\\]\|\\.\)*")' Sources/*.swift | sed 's/^L("//; s/")$//' | sort -u)
for strings in Resources/*.lproj/Localizable.strings; do
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        if ! grep -qF "\"$key\" =" "$strings"; then
            echo "missing in $strings: $key"
            status=1
        fi
    done <<< "$keys"
done
[ $status -eq 0 ] && echo "localization OK"
exit $status
