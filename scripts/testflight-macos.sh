#!/bin/bash
# Build Polly for macOS and upload it to TestFlight. Run with --help for the options.
exec "$(dirname "$0")/lib/testflight.sh" mac "$(basename "$0")" "$@"
