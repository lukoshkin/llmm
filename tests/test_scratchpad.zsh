# Run the scratchpad core Python unit tests through the zsh harness.
typeset _sp_out _sp_rc
_sp_out="$(python3 "$LLMM_ROOT/tests/scratchpad_core_test.py" 2>&1)"; _sp_rc=$?
assert_rc 0 "$_sp_rc" "scratchpad_core python tests pass"
[[ $_sp_rc == 0 ]] || print -u2 "$_sp_out"
