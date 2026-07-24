#!/bin/zsh
# The three merge gates, in one command, so they mean the same thing to a human
# as they do to an automated development loop.
#
# Deliberately excluded: anything that touches the network. Those fail on rate
# limiting rather than on regressions, which would make a green run meaningless.
# Their commands are printed at the end so they stay easy to reach on purpose.
set -uo pipefail

ROOT="${0:A:h:h}"
RELAY_TESTS="${NDM_RELAY_TESTS_DIR:-$ROOT/extension/NDMRelay/tests}"

typeset -i failures=0
typeset -a summary

bold() { print -P "%B$1%b" }

record() {
  # Not named `status`: that is read-only in zsh.
  local name="$1" outcome="$2" detail="$3"
  if [[ "$outcome" == "ok" ]]; then
    summary+=("  PASS  ${(r:22:)name}$detail")
  else
    summary+=("  FAIL  ${(r:22:)name}$detail")
    (( failures += 1 ))
  fi
}

bold "1/3  swift build"
if build_log="$(cd "$ROOT" && swift build 2>&1)"; then
  record "swift build" ok ""
else
  print -r -- "$build_log" | grep -E "error:" | head -20
  record "swift build" fail "see output above"
fi

bold "2/3  swift test"
test_log="$(cd "$ROOT" && swift test 2>&1)"
test_status=$?
# Count individual cases rather than reading an "Executed N tests" line: those
# are printed per suite AND per target, so the last one is just the last target's
# tally and summing them double-counts.
typeset -i t_pass t_fail t_skip
t_pass=$(print -r -- "$test_log" | grep -c "^Test Case .*' passed (")
t_fail=$(print -r -- "$test_log" | grep -c "^Test Case .*' failed (")
t_skip=$(print -r -- "$test_log" | grep -c "^Test Case .*' skipped (")
tally="$t_pass passed"
(( t_fail > 0 )) && tally="$tally, $t_fail failed"
(( t_skip > 0 )) && tally="$tally, $t_skip skipped"
if (( test_status == 0 )); then
  record "swift test" ok "$tally"
else
  print -r -- "$test_log" | grep -E "error:|XCTAssert" | head -20
  record "swift test" fail "$tally"
fi

bold "3/3  NDM Relay (node)"
if (( ! ${+commands[node]} )); then
  record "relay tests" fail "node is not installed"
else
  typeset -i relay_pass=0 relay_fail=0 relay_files=0
  for f in "$RELAY_TESTS"/*.test.js(N); do
    (( relay_files += 1 ))
    out="$(node "$f" 2>&1)"
    p=$(print -r -- "$out" | grep -oE "^# pass [0-9]+" | head -1 | awk '{print $3}')
    fl=$(print -r -- "$out" | grep -oE "^# fail [0-9]+" | head -1 | awk '{print $3}')
    (( relay_pass += ${p:-0} ))
    (( relay_fail += ${fl:-0} ))
    if [[ "${fl:-0}" != "0" ]]; then
      print -r -- "  ${f:t}"
      print -r -- "$out" | grep -E "^not ok|Error" | head -5
    fi
  done
  if (( relay_files == 0 )); then
    record "relay tests" fail "no test files under $RELAY_TESTS"
  elif (( relay_fail == 0 )); then
    record "relay tests" ok "$relay_pass passed in $relay_files files"
  else
    record "relay tests" fail "$relay_fail failed, $relay_pass passed"
  fi
fi

print
bold "Gates"
for line in "${summary[@]}"; do print -r -- "$line"; done

print
if (( failures == 0 )); then
  bold "All gates green."
else
  bold "$failures gate(s) failed."
fi

print
print -r -- "Not run here (they reach the network, so they cannot gate a merge):"
print -r -- "  NDM_LIVE_NETWORK_TESTS=1 swift test --filter YtDlpToolIntegrationTests"
print -r -- "  swift run NDMProbe                      # delivery success rate"
print -r -- "  swift run NDMSoak --duration 28800      # the real 8 hour soak"

exit $(( failures == 0 ? 0 : 1 ))
