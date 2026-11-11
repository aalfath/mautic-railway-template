#!/bin/sh
# Prints the Railway start command used by the template: start.sh, base64-encoded inline,
# so the service runs the official image with no extra download at boot.
printf "/bin/bash -c 'echo %s | base64 -d > /railway-start.sh && exec bash /railway-start.sh'\n" "$(base64 -w0 "$(dirname "$0")/start.sh")"
