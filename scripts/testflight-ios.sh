#!/bin/bash
# Build Polly for iPhone and iPad and upload it to TestFlight. Run with --help for the options.
exec "$(dirname "$0")/lib/testflight.sh" ios "$(basename "$0")" "$@"
