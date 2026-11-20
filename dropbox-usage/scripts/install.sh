#!/bin/zsh

set -euo pipefail

root=${0:A:h:h}
source_app="$root/build/Dropbox Usage.app"
destination="$HOME/Applications/Dropbox Usage.app"

if [[ ! -d "$source_app" ]]; then
    "$root/scripts/build-app.sh"
fi

/bin/mkdir -p "$HOME/Applications"
/usr/bin/ditto "$source_app" "$destination"

echo "$destination"
