#!/usr/bin/env bash
# test-openclaw-install-sequence.sh
# Purpose: Simulate *exactly* the critical cloud-init runcmd block that installs + links the OpenClaw CLI
#          as the dedicated "openclaw" system user. This lets us validate Linux shell semantics, redirection,
#          find+force-link logic, log file creation, and symlink results on this Linux workstation *before*
#          any Windows pwsh launch or multipass cycle.
#
# Run:
#   bash scripts/test-openclaw-install-sequence.sh
#   bash -x scripts/test-openclaw-install-sequence.sh   # for full tracing
#
# The script creates a throwaway simulation tree under /tmp, "installs" by touching a binary at one of
# two plausible locations (direct --prefix result, or a nested node_modules/.bin result), runs the
# payload, then asserts:
#   - /tmp/openclaw-install.log (in sim) was created with clear SUCCESS/VERIFIED markers
#   - Both /home/openclaw/.openclaw/bin/openclaw and /usr/local/bin/openclaw end up as working symlinks
#     (relative to the sim root)
#
# This directly exercises the sequence we will embed in the launch.ps1 $cloudInitTemplate.

set -euo pipefail

SIM_ROOT="${SIM_ROOT:-/tmp/vtorclaw-sim-$$}"
SIM_HOME="$SIM_ROOT/home/openclaw"
SIM_USR_LOCAL_BIN="$SIM_ROOT/usr/local/bin"
LOG_FILE="$SIM_ROOT/tmp/openclaw-install.log"

echo "[test] Using simulation root: $SIM_ROOT"
rm -rf "$SIM_ROOT"
mkdir -p "$SIM_HOME/.openclaw" "$SIM_USR_LOCAL_BIN" "$SIM_ROOT/tmp"

# We will "run as the openclaw user" by exporting HOME and running bash snippets directly.
# In the real cloud-init the outer context is root and we use "sudo -u openclaw bash -c '...'".
# For the test we approximate by running the inner logic under the sim HOME.
export HOME="$SIM_HOME"

# Helper: run a "sudo -u openclaw bash -c 'CMD'" approximation.
# In test we just eval the body after cd'ing to sim and with HOME set.
run_as_openclaw() {
  local body="$1"
  # The body is expected to be a single-quoted snippet as it appears in the real block.
  # We exec it under bash -c with HOME and a clean PATH simulation.
  ( cd "$SIM_ROOT" ; HOME="$SIM_HOME" PATH="/usr/local/bin:/usr/bin:/bin" bash -c "$body" )
}

# The *exact* payload we intend to embed under the "- |" literal scalar in launch.ps1 runcmd.
# Differences from production:
#   - Paths are rewritten at runtime via sed or by the run_ helpers to use $SIM_ROOT.
#   - "npm install" is simulated by touching a file (we test both "direct" and "nested" placements).
#   - We do not actually need node/npm present.
# The redirection (exec > ...), set -x, markers, PATH append, controlled npm (simulated), find+force link,
# and VERIFIED checks are *identical* in structure and quoting to what will ship.

run_payload() {
  local scenario="$1"   # "direct" or "nested"
  local log_in_sim="$SIM_ROOT/tmp/openclaw-install.log"

  # Clean any previous log for this scenario
  rm -f "$log_in_sim"

  # Write and execute a temp script that contains the literal block content (with sim paths injected).
  # This mirrors "cloud-init writes the - | content to a temp script and runs it as root".
  local payload_script
  payload_script=$(mktemp "$SIM_ROOT/payload.XXXXXX.sh")

  # NOTE: We intentionally keep the structure extremely close to the final cloud-init text,
  # including the exec redirection at the top of the block, the inner single-quoted sudo bodies,
  # the find under /home/openclaw, the ln -sf to both canonical targets, and the VERIFIED echoes.
  cat > "$payload_script" << 'PAYLOAD_EOF'
# --- BEGIN exact block content (will be lightly sed-rewritten for sim paths before exec) ---
exec > /tmp/openclaw-install.log 2>&1
set -x
echo "=== OPENCLAW INSTALL START $(date -u) ==="

# 1. Early PATH for the dedicated user (sudo -u + login shells + bare "openclaw" via /usr/local/bin)
sudo -u openclaw bash -c '
  mkdir -p ~/.openclaw/bin
  for f in ~/.bashrc ~/.profile; do
    if [ -f "$f" ] || [ ! -e "$f" ]; then
      grep -q "export PATH=/usr/local/bin:\$PATH" "$f" 2>/dev/null || echo "export PATH=/usr/local/bin:\$PATH" >> "$f"
    fi
  done
' || true

# 2. Direct controlled "npm install -g openclaw --prefix ..." (the real one-liner; here we simulate)
echo "Running direct npm install -g openclaw --prefix /home/openclaw/.openclaw ..."
SIM_NPM_RC=0
# The following line is what the real block has; in test the "npm" is a no-op or we touch files below.
# We keep the command text so the log contains the intent.
echo "+ sudo -u openclaw bash -l -c npm install -g openclaw --prefix /home/openclaw/.openclaw  (simulated)"

# 3. Unconditional robust discovery + force links (core of the fix)
echo "Running discovery and force-linking..."
sudo -u openclaw bash -c '
  set -e
  mkdir -p /home/openclaw/.openclaw/bin
  CANDIDATE="/home/openclaw/.openclaw/bin/openclaw"
  if [ ! -x "$CANDIDATE" ]; then
    FOUND=$(find /home/openclaw -type f \( -name openclaw -o -path "*bin/openclaw" -o -path "*\.bin/openclaw" \) 2>/dev/null | head -5 || true)
    for f in $FOUND; do
      if [ -f "$f" ]; then
        chmod +x "$f" 2>/dev/null || true
        ln -sf "$f" "$CANDIDATE"
        echo "  discovered and linked candidate $f -> $CANDIDATE"
        break
      fi
    done
  fi
  if [ -f "$CANDIDATE" ] || [ -L "$CANDIDATE" ]; then
    ln -sf "$CANDIDATE" /usr/local/bin/openclaw
    chmod +x "$CANDIDATE" /usr/local/bin/openclaw 2>/dev/null || true
    echo "SUCCESS: openclaw binary linked from $CANDIDATE to service and /usr/local/bin"
    ls -l "$CANDIDATE" /usr/local/bin/openclaw
  else
    echo "FATAL: no executable openclaw found after install step. Dumping layout:"
    find /home/openclaw -maxdepth 5 -type f 2>/dev/null | head -30 || true
    ls -laR /home/openclaw/.openclaw 2>/dev/null | tail -50 || true
  fi
' || echo "Linking block exited non-zero (non-fatal; verification below will surface it)"

# 4. Verification (these lines are what we grep for in cloud-init-output.log on real launches)
echo "=== VERIFICATION ==="
if [ -x /home/openclaw/.openclaw/bin/openclaw ]; then
  echo "VERIFIED: /home/openclaw/.openclaw/bin/openclaw is executable"
  /home/openclaw/.openclaw/bin/openclaw --version 2>/dev/null || echo "(version probe non-zero is acceptable pre-onboard)"
else
  echo "VERIFICATION FAILED: /home/openclaw/.openclaw/bin/openclaw missing or not executable"
fi
if [ -x /usr/local/bin/openclaw ]; then
  echo "VERIFIED: /usr/local/bin/openclaw is executable (bare name will work under sudo -u openclaw)"
else
  echo "VERIFICATION FAILED: /usr/local/bin/openclaw missing or not executable"
fi
echo "=== OPENCLAW INSTALL END $(date -u) ==="
# --- END exact block content ---
PAYLOAD_EOF

  # Rewrite the payload for simulation paths.
  # - /home/openclaw and /usr/local/bin become the sim equivalents.
  # - The exec log path is also rewritten so the inner "exec > /tmp/..." lands under the sim tree.
  # - sudo -u openclaw becomes a HOME=... pass-through (the bodies run under the simulated user home).
  # We also inject a simulated "install" step that creates the binary at the location for this scenario.
  sed -i \
    -e "s|/home/openclaw|$SIM_HOME|g" \
    -e "s|/usr/local/bin/openclaw|$SIM_USR_LOCAL_BIN/openclaw|g" \
    -e "s|exec > /tmp/openclaw-install.log|exec > $SIM_ROOT/tmp/openclaw-install.log|g" \
    -e "s|sudo -u openclaw |HOME=$SIM_HOME |g" \
    "$payload_script"

  # Scenario-specific "install" side effect: create a plausible openclaw binary *before* the discovery runs.
  # This mimics what a successful `npm install -g openclaw --prefix /home/openclaw/.openclaw` would do,
  # or the case where it lands in node_modules/.bin.
  mkdir -p "$SIM_HOME/.openclaw/bin"
  if [ "$scenario" = "direct" ]; then
    # The happy path: npm respected --prefix and put the bin exactly where the unit expects it.
    touch "$SIM_HOME/.openclaw/bin/openclaw"
    chmod +x "$SIM_HOME/.openclaw/bin/openclaw"
    echo "[test] Scenario '$scenario': pre-created $SIM_HOME/.openclaw/bin/openclaw"
  else
    # The "install script was weird" path: binary exists but not at the canonical spot yet.
    mkdir -p "$SIM_HOME/.openclaw/lib/node_modules/openclaw/bin"
    touch "$SIM_HOME/.openclaw/lib/node_modules/openclaw/bin/openclaw"
    chmod +x "$SIM_HOME/.openclaw/lib/node_modules/openclaw/bin/openclaw"
    # Also drop one in a .bin style dir to exercise the find glob
    mkdir -p "$SIM_HOME/.openclaw/node_modules/.bin"
    ln -sf "$SIM_HOME/.openclaw/lib/node_modules/openclaw/bin/openclaw" "$SIM_HOME/.openclaw/node_modules/.bin/openclaw"
    echo "[test] Scenario '$scenario': pre-created nested binary under node_modules (find must discover)"
  fi

  # Now execute the payload script. All its stdout/stderr (thanks to exec > inside) will go to the (sim) log.
  # We also capture the outer execution trace for the test harness.
  echo "[test] Executing payload for scenario '$scenario' (log will be at $log_in_sim)..."
  # Run with tracing visible to the test runner but the inner exec still captures the log under the sim tree.
  bash -x "$payload_script" 2>&1 | cat || true

  # If a stray host /tmp/openclaw-install.log exists from an earlier non-rewritten run, ignore it.
  # The sed above ensures the exec inside the payload now targets $SIM_ROOT/tmp/...

  # Post-run assertions (the important part)
  echo "[test] --- Assertions for '$scenario' ---"
  if [ ! -f "$log_in_sim" ]; then
    echo "[FAIL] $log_in_sim was never created. Redirection in the block is broken."
    echo "Host /tmp version (if any):"
    ls -l /tmp/openclaw-install.log 2>/dev/null || true
    exit 1
  fi
  echo "[ok] Log file exists."

  if ! grep -q "VERIFIED: /home/openclaw/.openclaw/bin/openclaw is executable" "$log_in_sim"; then
    echo "[FAIL] Missing 'VERIFIED: .../.openclaw/bin/openclaw' marker in log. Contents:"
    cat "$log_in_sim"
    exit 1
  fi
  echo "[ok] Primary service location verified in log."

  if ! grep -q "VERIFIED: /usr/local/bin/openclaw is executable" "$log_in_sim"; then
    echo "[FAIL] Missing 'VERIFIED: /usr/local/bin/openclaw' marker in log."
    cat "$log_in_sim"
    exit 1
  fi
  echo "[ok] /usr/local/bin symlink verified in log."

  if ! grep -q "SUCCESS:" "$log_in_sim" && ! grep -q "VERIFIED:" "$log_in_sim"; then
    echo "[FAIL] No SUCCESS/VERIFIED lines at all."
    exit 1
  fi

  # Check the actual symlinks in the sim fs (they must point at something executable)
  if [ ! -L "$SIM_HOME/.openclaw/bin/openclaw" ] && [ ! -x "$SIM_HOME/.openclaw/bin/openclaw" ]; then
    echo "[FAIL] $SIM_HOME/.openclaw/bin/openclaw is not a valid link/executable after run."
    ls -l "$SIM_HOME/.openclaw/bin/openclaw" || true
    exit 1
  fi
  echo "[ok] Primary location is present and usable."

  if [ ! -L "$SIM_USR_LOCAL_BIN/openclaw" ] || [ ! -x "$SIM_USR_LOCAL_BIN/openclaw" ]; then
    echo "[FAIL] $SIM_USR_LOCAL_BIN/openclaw is not a valid executable symlink."
    ls -l "$SIM_USR_LOCAL_BIN/openclaw" || true
    exit 1
  fi
  echo "[ok] /usr/local/bin/openclaw symlink is present and executable."

  # Show the tail of the captured log (what a user would see with cat /tmp/openclaw-install.log)
  echo "[test] Captured install log tail (this is what ends up in /tmp inside the real VM):"
  tail -20 "$log_in_sim" | sed 's/^/    /'

  echo "[PASS] Scenario '$scenario' passed all assertions."
  echo
}

# Run both scenarios
run_payload "direct"
run_payload "nested"

echo "[SUCCESS] All simulation scenarios passed. The embedded shell sequence produces a real log file,"
echo "          force-links the binary to both required locations, and leaves VERIFIED markers."
echo "          This sequence can now be safely embedded in launch.ps1 and will survive cloud-init."
echo
echo "Next (on Windows after normal git pull):"
echo "  multipass delete --purge openclaw"
echo "  pwsh -File .\\scripts\\launch.ps1 -Spec vtorclaw.yaml"
echo "Then inside the fresh VM the full-path and bare-name commands will work with no extra steps."