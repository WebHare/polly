#!/bin/bash
# Shared by scripts/testflight-macos.sh and scripts/testflight-ios.sh; see "TestFlight" in DEVELOPERS.md.
set -euo pipefail

PLATFORM=$1 SCRIPT=$2; shift 2
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

usage() {
  cat <<USAGE
Usage: scripts/$SCRIPT [options]

Builds Polly from the current checkout and uploads it to TestFlight.

  --groups NAMES        comma-separated TestFlight groups to add the build to
                        (default: \$POLLY_TESTFLIGHT_GROUPS; none = only groups with automatic distribution)
  --external            also distribute to external testers in those groups (submits for beta review)
  --notes-file FILE     "What to Test" text (default: this version's CHANGELOG.md section, else [Unreleased])
  --build-number N      use build number N instead of CURRENT_PROJECT_VERSION from project.yml;
                        "auto" uses the latest TestFlight build of this platform + 1
  --no-wait             don't wait for App Store Connect to finish processing the build
  --dry-run             build and export only; upload nothing
  --allow-dirty         build even with uncommitted changes

Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (App Store Connect API key) except with --dry-run.
USAGE
}

TESTER_GROUPS=${POLLY_TESTFLIGHT_GROUPS:-}
EXTERNAL=false NO_WAIT=false DRY_RUN=false ALLOW_DIRTY=false NOTES_FILE="" BUILD_NUMBER=""
while [ $# -gt 0 ]; do
  case $1 in
    --groups) TESTER_GROUPS=$2; shift 2 ;;
    --external) EXTERNAL=true; shift ;;
    --notes-file) NOTES_FILE=$2; shift 2 ;;
    --build-number) BUILD_NUMBER=$2; shift 2 ;;
    --no-wait) NO_WAIT=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

cd "$ROOT"
if [ "$ALLOW_DIRTY" != true ] && [ -n "$(git status --porcelain)" ]; then
  echo "Uncommitted changes; commit them or pass --allow-dirty." >&2; exit 1
fi
if [ "$EXTERNAL" = true ] && [ -z "$TESTER_GROUPS" ]; then
  echo "--external needs --groups (or POLLY_TESTFLIGHT_GROUPS)." >&2; exit 2
fi

# fastlane needs a current Ruby; macOS ships 2.6. Keep a current one from PATH (CI's setup-ruby), else Homebrew's.
RUBY_BIN=$(dirname "$(command -v ruby)")
if ! ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2"))' 2>/dev/null \
   && [ -x /opt/homebrew/opt/ruby/bin/ruby ]; then
  RUBY_BIN=/opt/homebrew/opt/ruby/bin
fi
# Xcode's export runs /usr/bin/rsync, which starts the first rsync in PATH as its peer; Homebrew's rsync
# doesn't understand its options and the export fails with "Copy failed". Ruby's folder may be Homebrew's
# bin with that rsync in it, so only Ruby's own commands go before /usr/bin.
TOOLS=$(mktemp -d); trap 'rm -rf "$TOOLS"' EXIT
for tool in ruby gem bundle bundler; do ln -s "$RUBY_BIN/$tool" "$TOOLS/$tool"; done
PATH=$TOOLS:/usr/bin:$PATH
export BUNDLE_PATH=vendor/bundle FASTLANE_OPT_OUT_USAGE=1 FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1
bundle check >/dev/null 2>&1 || bundle install --quiet

if [ -z "$NOTES_FILE" ]; then
  VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
  mkdir -p build/testflight
  NOTES_FILE=build/testflight/what-to-test.txt
  python3 scripts/release_notes.py --testflight "$VERSION" CHANGELOG.md > "$NOTES_FILE"
fi
echo "What to Test:"; sed 's/^/  /' "$NOTES_FILE"

bundle exec fastlane "$PLATFORM" beta \
  "groups:$TESTER_GROUPS" "external:$EXTERNAL" "notes_file:$(cd "$(dirname "$NOTES_FILE")" && pwd)/$(basename "$NOTES_FILE")" \
  "build_number:$BUILD_NUMBER" "no_wait:$NO_WAIT" "dry_run:$DRY_RUN"
