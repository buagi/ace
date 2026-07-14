#!/usr/bin/env bash
# parse KEY=VALUE -> prints VALUE. BUG: accepts empty/malformed input silently.
parse(){ printf '%s' "$1" | cut -d= -f2; }
