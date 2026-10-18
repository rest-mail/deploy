#!/usr/bin/env bash
# Checks .github/workflows/image.yml without GitHub: its shape (workflow.py
# contract), and what its plan, tag and HEALTHCHECK steps decide, by running
# their run: scripts exactly as the workflow holds them against the facts a
# run would give them.
#
# The HEALTHCHECK step inspects images through a stand-in docker by default.
# REAL_DOCKER=1 also builds the fixtures (FROM scratch, single platform) and
# checks them with the real one.
set -uo pipefail
# pass only echoes, so `check && pass || fail` cannot run both.
# shellcheck disable=SC2015

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
failures=0

pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
script() { python3 -I "$here/workflow.py" step "$1" "$2"; }
# refused <exit code> <description>: a refusal is the step saying no, with an
# ::error::, not the script falling over.
refused() {
  if [[ $1 == 0 ]]; then fail "$2: was not refused"; return 1; fi
  if ! grep -q '^::error::' "$tmp/log"; then fail "$2: failed without saying why: $(cat "$tmp/log")"; return 1; fi
  pass "$2"
}

python3 -I "$here/workflow.py" contract && pass "contract holds" || fail "contract"
python3 -I "$here/workflow.py" contract-catches || fail "contract misses a breakage"

script validate plan > "$tmp/plan.sh" || exit 1
script publish tags > "$tmp/tags.sh" || exit 1
script validate healthcheck > "$tmp/healthcheck.sh" || exit 1
if command -v shellcheck > /dev/null; then
  for f in plan tags healthcheck; do
    shellcheck -s bash "$tmp/$f.sh" && pass "the $f step passes shellcheck" || fail "the $f step fails shellcheck"
  done
fi
# The publish job runs the same plan and HEALTHCHECK steps, not copies.
cmp -s "$tmp/plan.sh" <(script publish plan) && pass "publish plans as validate does" || fail "publish plans differently"
cmp -s "$tmp/healthcheck.sh" <(script publish healthcheck) && pass "publish checks as validate does" || fail "publish checks differently"

# plan <expect: ok|refused> <description> [VAR=value ...]: runs the plan
# step with a pushed default branch of rest-mail/reference-postfix, changed by
# the VAR=value given; leaves its outputs in $tmp/out.
plan() {
  local expect="$1" what="$2"; shift 2
  : > "$tmp/out"
  env -i PATH="$PATH" GITHUB_OUTPUT="$tmp/out" \
    EVENT=push REF=refs/heads/master REPOSITORY=rest-mail/reference-postfix DEFAULT_BRANCH=master \
    PUBLISH_INPUT=true CONTEXT=. DOCKERFILE= PLATFORMS=linux/amd64,linux/arm64 RUNTIME_CHECK= \
    "$@" bash "$tmp/plan.sh" > "$tmp/log" 2>&1
  local rc=$?
  case "$expect" in
    ok) [[ $rc == 0 ]] && return 0; fail "$what: refused: $(cat "$tmp/log")" ;;
    refused) refused $rc "$what" && return 0 ;;
  esac
  return 1
}
out() { sed -n "s/^$1=//p" "$tmp/out"; }
expect() { # expect <description> key=value ...
  local what="$1" kv; shift
  for kv in "$@"; do
    [[ "$(out "${kv%%=*}")" == "${kv#*=}" ]] || { fail "$what: ${kv%%=*} is '$(out "${kv%%=*}")', want '${kv#*=}'"; return; }
  done
  pass "$what"
}

echo "== who may publish =="
plan ok "default branch" && expect "a push to the default branch publishes latest and sha" \
  publish=true kind=branch image=ghcr.io/rest-mail/reference-postfix file=./Dockerfile check-platform=linux/amd64
plan ok "main" REF=refs/heads/main DEFAULT_BRANCH=main && expect "the default branch is whatever the repository says" publish=true kind=branch
plan ok "manual run" EVENT=workflow_dispatch && expect "a manual run of the default branch publishes" publish=true
plan ok "other branch" REF=refs/heads/feature && expect "another branch only validates" publish=false kind=validate
plan ok "manual other branch" EVENT=workflow_dispatch REF=refs/heads/feature && expect "a manual run of another branch only validates" publish=false
plan ok "pull request" EVENT=pull_request REF=refs/pull/7/merge && expect "a pull request only validates" publish=false kind=validate
plan ok "fork pull request" EVENT=pull_request REF=refs/heads/master && expect "a pull request only validates, whatever ref it claims" publish=false
plan ok "pull_request_target" EVENT=pull_request_target && expect "pull_request_target only validates" publish=false
plan ok "pull_request_target tag" EVENT=pull_request_target REF=refs/tags/v1.2.3 && expect "pull_request_target never releases" publish=false
plan ok "schedule" EVENT=schedule && expect "a schedule only validates" publish=false
plan ok "no default branch" DEFAULT_BRANCH= && expect "without a known default branch nothing publishes" publish=false
plan ok "branch named like the default" REF=refs/heads/master-old && expect "a branch that merely starts like the default only validates" publish=false
plan ok "publish off" PUBLISH_INPUT=false && expect "publish: false keeps the default branch to validation" publish=false kind=branch
plan ok "publish off tag" PUBLISH_INPUT=false REF=refs/tags/v1.2.3 && expect "publish: false keeps a release to validation" publish=false kind=release

echo "== which version =="
plan ok "release" REF=refs/tags/v1.2.3 && expect "v1.2.3 publishes 1.2.3" publish=true kind=release version=1.2.3
plan ok "prerelease" REF=refs/tags/v0.4.0-rc.1 && expect "v0.4.0-rc.1 publishes 0.4.0-rc.1" kind=release version=0.4.0-rc.1
plan ok "big release" REF=refs/tags/v10.20.300 && expect "v10.20.300 publishes 10.20.300" version=10.20.300
plan refused "a date (CalVer) tag is refused" REF=refs/tags/v2026.10.18
plan refused "a date tag with a prerelease is refused" REF=refs/tags/v2026.1.2-rc.1
plan refused "a tag without its v is refused" REF=refs/tags/1.2.3
plan refused "a two-part tag is refused" REF=refs/tags/v1.2
plan refused "a leading zero is refused" REF=refs/tags/v01.2.3
plan refused "build metadata (no Docker tag can hold +) is refused" REF=refs/tags/v1.2.3+build.1
plan refused "a word is refused" REF=refs/tags/vlatest
plan refused "a tag carrying a newline is refused" REF=$'refs/tags/v1.2.3\nlatest'

echo "== where it goes, and from what =="
plan ok "uppercase" REPOSITORY=Rest-Mail/Reference-Dovecot && expect "the image is the calling repository, lowercased" image=ghcr.io/rest-mail/reference-dovecot
plan ok "subdirectory" CONTEXT=images/rspamd && expect "the Dockerfile defaults to the context's" file=images/rspamd/Dockerfile
plan ok "dockerfile" DOCKERFILE=docker/Dockerfile.prod && expect "a named Dockerfile is used" file=docker/Dockerfile.prod
plan ok "arm64 first" PLATFORMS=linux/arm64,linux/amd64 && expect "the first platform is the one checked" check-platform=linux/arm64
plan ok "runtime check" RUNTIME_CHECK=tests/health.sh && expect "a runtime check inside the repository is accepted" publish=true
plan refused "a repository that is not owner/name is refused" REPOSITORY='rest-mail/x:latest'
plan refused "a context outside the repository is refused" CONTEXT=../other
plan refused "an absolute context is refused" CONTEXT=/etc
plan refused "a context hiding .. is refused" CONTEXT=a/../../b
plan refused "a context that reads as an option is refused" CONTEXT=--build-arg=x
plan refused "a Dockerfile outside the repository is refused" DOCKERFILE=../Dockerfile
plan refused "a runtime check outside the repository is refused" RUNTIME_CHECK=../../bin/sh
plan refused "a runtime check with a shell in it is refused" RUNTIME_CHECK='x;id'
plan refused "platforms with a shell in them are refused" PLATFORMS='linux/amd64;id'
plan refused "a platform that is not linux is refused" PLATFORMS=windows/amd64

echo "== the tags it pushes =="
sha=0123456789abcdef0123456789abcdef01234567
img=ghcr.io/rest-mail/reference-postfix
tags() { # tags <expect: ok|refused> <description> <TAGS> [VAR=value ...]
  local expect="$1" what="$2" list="$3"; shift 3
  env -i PATH="$PATH" TAGS="$list" IMAGE="$img" KIND=branch VERSION= SHA="$sha" "$@" \
    bash "$tmp/tags.sh" > "$tmp/log" 2>&1
  local rc=$?
  if [[ $expect == ok ]]; then [[ $rc == 0 ]] && pass "$what" || fail "$what: $(cat "$tmp/log")"
  else refused $rc "$what"; fi
}
tags ok "latest and the short sha for the default branch" "$img:latest"$'\n'"$img:0123456"
tags ok "in any order" "$img:0123456"$'\n'"$img:latest"$'\n'
tags ok "the version for a release" "$img:1.2.3" KIND=release VERSION=1.2.3
tags refused "a release does not move latest" "$img:1.2.3"$'\n'"$img:latest" KIND=release VERSION=1.2.3
tags refused "a release is not its sha" "$img:0123456" KIND=release VERSION=1.2.3
tags refused "the default branch does not publish without its sha" "$img:latest"
tags refused "nothing extra rides along" "$img:latest"$'\n'"$img:0123456"$'\n'"$img:2026.10.18"
tags refused "nothing goes to another image" "ghcr.io/someone/else:latest"$'\n'"ghcr.io/someone/else:0123456"
tags refused "a validate run pushes nothing" "" KIND=validate
tags refused "an empty tag list pushes nothing" "" KIND=release VERSION=1.2.3
tags refused "a commit that is not a sha is refused" "$img:latest"$'\n'"$img:main" SHA=main

echo "== the HEALTHCHECK =="
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Stands in for `docker image inspect --format '{{json .Config.Healthcheck}}' IMAGE`.
[[ "$1 $2" == "image inspect" ]] || exit 2
[[ -n "${FAKE_INSPECT_FAILS:-}" ]] && { echo "Error: No such image" >&2; exit 1; }
printf '%s\n' "$FAKE_HEALTHCHECK"
EOF
chmod +x "$tmp/bin/docker"
health() { # health <expect: ok|refused> <description> [VAR=value ...]
  local expect="$1" what="$2"; shift 2
  env -i PATH="${HEALTH_PATH:-$tmp/bin:$PATH}" IMAGE="${HEALTH_IMAGE:-image-under-test:local}" "$@" \
    bash "$tmp/healthcheck.sh" > "$tmp/log" 2>&1
  local rc=$?
  if [[ $expect == ok ]]; then [[ $rc == 0 ]] && pass "$what" || fail "$what: $(cat "$tmp/log")"
  else refused $rc "$what"; fi
}
health ok "a shell HEALTHCHECK passes" FAKE_HEALTHCHECK='{"Test":["CMD-SHELL","postconf mail_version >/dev/null 2>&1 && nc -z 127.0.0.1 25 || exit 1"],"Interval":30000000000}'
health ok "an exec HEALTHCHECK passes" FAKE_HEALTHCHECK='{"Test":["CMD","rspamc","stat"]}'
health refused "no HEALTHCHECK is refused" FAKE_HEALTHCHECK=null
health refused "HEALTHCHECK NONE is refused" FAKE_HEALTHCHECK='{"Test":["NONE"]}'
health refused "a HEALTHCHECK with no test is refused" FAKE_HEALTHCHECK='{"Interval":30000000000}'
health refused "an empty test is refused" FAKE_HEALTHCHECK='{"Test":[]}'
health refused "a blank command is refused" FAKE_HEALTHCHECK='{"Test":["CMD-SHELL","  "]}'
health refused "an unknown form is refused" FAKE_HEALTHCHECK='{"Test":["EXEC","x"]}'
health refused "unreadable output is refused" FAKE_HEALTHCHECK='not json'
health refused "an image that is not there is refused" FAKE_INSPECT_FAILS=1 FAKE_HEALTHCHECK=null

if [[ "${REAL_DOCKER:-}" == 1 ]]; then
  echo "== the HEALTHCHECK, built for real =="
  for fixture in healthy healthcheck-none no-healthcheck; do
    docker build -q -t "image-workflow-fixture:$fixture" "$here/fixtures/$fixture" > /dev/null \
      || { fail "fixture $fixture does not build"; continue; }
  done
  HEALTH_PATH="$PATH" HEALTH_IMAGE=image-workflow-fixture:healthy health ok "a built image with a HEALTHCHECK passes"
  HEALTH_PATH="$PATH" HEALTH_IMAGE=image-workflow-fixture:healthcheck-none health refused "a built image with HEALTHCHECK NONE is refused"
  HEALTH_PATH="$PATH" HEALTH_IMAGE=image-workflow-fixture:no-healthcheck health refused "a built image without a HEALTHCHECK is refused"
  docker image rm -f image-workflow-fixture:healthy image-workflow-fixture:healthcheck-none \
    image-workflow-fixture:no-healthcheck > /dev/null 2>&1 || true
fi

if (( failures )); then echo "$failures failed" >&2; exit 1; fi
echo "all passed"
