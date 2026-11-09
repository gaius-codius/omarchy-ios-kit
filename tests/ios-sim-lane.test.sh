#!/usr/bin/env bash
# shellcheck disable=SC2034 # the checks read their variables inside eval
# Tests ios-sim-lane and ios-sim-gate together on Linux: a fake ssh runs the gate as the
# Mac's forced command would (SSH_ORIGINAL_COMMAND, the Mac's home), with stub xcrun and
# axe that log what they were asked. Run it from anywhere: tests/ios-sim-lane.test.sh
set -euo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'kill_holds; rm -rf "$T"' EXIT
fails=0

kill_holds() {
    local f
    for f in "$T"/lane*/hold.pid; do [ -f "$f" ] && kill -- "-$(cat "$f")" 2>/dev/null; done
    return 0
}

MAC="$T/mac" STUB="$T/stub" LOG="$T/log"
mkdir -p "$MAC/ios-sim-run" "$STUB" "$T/home/.config/ios-run" "$T/home/.ssh"
# The gate reads its settings from the Mac's gate.conf only, never the environment.
echo "IOS_SIM_GATE_PATH=\"$STUB\"" >"$MAC/ios-sim-run/gate.conf"
: >"$LOG"
export LOG MAC

cat >"$STUB/xcrun" <<'EOF'
#!/usr/bin/env bash
echo "xcrun $*" >>"$LOG"
u=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
case "$1 $2" in
    "simctl list") echo "== Devices =="; echo "    iPhone 18 Pro (11111111-2222-3333-4444-555555555555) (Booted)"
        [ -f "$MAC/.created" ] && echo "    csp runs ($u) (Shutdown)"; exit 0 ;;
    "simctl create") touch "$MAC/.created"; echo "$u" ;;
    "simctl io") printf 'PNGDATA' >"$5" ;;
esac
exit 0
EOF
cat >"$STUB/axe" <<'EOF'
#!/usr/bin/env bash
echo "axe $*" >>"$LOG"
EOF
cat >"$STUB/xcodebuild" <<'EOF'
#!/usr/bin/env bash
echo "xcodebuild $*" >>"$LOG"
mkdir -p ../dd/Build/Products/Debug-iphonesimulator && echo bin >../dd/Build/Products/Debug-iphonesimulator/App
EOF
for tool in plutil codesign; do printf '#!/usr/bin/env bash\necho "%s $*" >>"$LOG"\n' "$tool" >"$STUB/$tool"; done
# The fake ssh: options, the host, then the command line, run as the forced command. A
# control command (-O forward) is logged with its -R and fails while $T/forward-fails exists.
cat >"$STUB/ssh" <<EOF
#!/usr/bin/env bash
ctl="" fwd=""
while [ \$# -gt 0 ]; do
    case \$1 in
        -O) ctl=\$2; shift 2 ;;
        -R) fwd=\$2; shift 2 ;;
        -F|-o) shift 2 ;;
        -*) shift ;;
        simmac) shift; break ;;
        *) shift ;;
    esac
done
if [ -n "\$ctl" ]; then
    echo "ssh -O \$ctl \$fwd" >>"\$LOG"
    [ ! -e "$T/forward-fails" ] || { echo "remote port forwarding failed for listen port" >&2; exit 255; }
    exit 0
fi
[ -z "\$fwd" ] || echo "ssh asked to forward \$fwd" >>"\$LOG"
echo "ssh \$*" >>"\$LOG"
SSH_ORIGINAL_COMMAND="\$*" HOME="$MAC" exec bash "$KIT/mac/ios-sim-gate"
EOF
chmod +x "$STUB"/*
echo "fake key" >"$T/home/.config/ios-run/runs-key"
echo "mac ssh-ed25519 AAAA" >"$T/home/.config/ios-run/runs-known_hosts"

# lane N ARGS...: ios-sim-lane as run N, with its own hold folder.
lane() {
    local n=$1
    shift
    HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" SIM_HOST=me@mac IOS_SIM_LANE_SSH="$STUB/ssh" \
        IOS_SIM_LANE_DIR="$T/lane$n" bash "$KIT/bin/ios-sim-lane" "$@"
}
# gate CMDLINE: the gate as the Mac runs it for that command line.
gate() { SSH_ORIGINAL_COMMAND="$1" HOME="$MAC" bash "$KIT/mac/ios-sim-gate"; }

ok() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

# --- The gate on its own ---------------------------------------------------------------
check "the gate refuses a verb it doesn't know" '! gate "bash -c id" 2>/dev/null'
check "the gate refuses a shell character on the command line" '! gate "shot x;id" 2>/dev/null'
check "the gate refuses a verb without the holder's token" '! gate "shot nope" 2>/dev/null </dev/null'
check "the gate refuses a key with a slash" '! gate "upload t ../x" 2>/dev/null </dev/null'

# --- One run takes it, another is told it's busy ----------------------------------------
out=$(lane 1 take --label kiwi)
check "the hold's own ssh asks for no forward; the forward comes after it" '! grep -q "^ssh asked to forward" "$LOG" && grep -q "^ssh -O forward 127.0.0.1:18443:127.0.0.1:18443" "$LOG"'
check "a run takes the runs' simulator" '[[ $out == *"holding the runs'"'"' simulator (AAAAAAAA-"* ]]'
check "taking it erases the runs' device before the run sees it" 'grep -q "xcrun simctl erase AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" "$LOG"'
: >"$LOG"
set +e
busy=$(lane 2 take --label sol 2>&1)
code=$?
set -e
check "a busy run asks for no forward (the holder's port would refuse it)" '! grep -q "forward" "$LOG"'

check "a second run is told it's busy, with the holder, and exits 75" '[ $code -eq 75 ] && [[ $busy == *"busy: the runs'"'"' simulator is held by kiwi since "*"carry on without the simulator"* ]]'
check "the busy run holds nothing" '[[ $(lane 2 status) == *"doesn'"'"'t hold"* ]]'
check "the second run's verbs are refused" '! lane 2 shot "$T/x.png" 2>/dev/null'
: >"$LOG"
lane 2 shot "$T/x.png" 2>/dev/null || true
check "a run without the hold sends nothing to the Mac" '! grep -q "^ssh " "$LOG"'
check "the gate refuses a wrong token while a hold is live" '! gate "shot wrongtoken" 2>/dev/null </dev/null'
check "the gate refuses a key starting with a dot, with the holder's token" '! gate "upload $(cat "$T/lane1/token") .x" 2>/dev/null </dev/null'
check "the gate refuses an upload into a key's parent through the holder's token" '! gate "upload $(cat "$T/lane1/token") .." 2>/dev/null </dev/null'

# lane_as RUN ARGS...: ios-sim-lane in run RUN's unit, with the default hold folder.
lane_as() {
    local run=$1
    shift
    HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_RUNTIME_DIR="$T/runtime" SIM_HOST=me@mac \
        IOS_SIM_LANE_SSH="$STUB/ssh" CSP_RUN="$run" INVOCATION_ID="inv-$run" bash "$KIT/bin/ios-sim-lane" "$@"
}
mkdir -p "$T/runtime"
set +e
busy=$(lane_as p-9-1 take --label wren 2>&1)
code=$?
set -e
check "runs sharing a runtime folder get their own hold folders, so the second is busy" '[ $code -eq 75 ] && [ -d "$T/runtime/ios-sim-lane-p-9-1" ]'
check "another run's hold folder doesn't count as this run's" '[[ $(lane_as p-9-2 status) == *"doesn'"'"'t hold"* ]]'

# --- What the holder may do ---------------------------------------------------------------
: >"$LOG"
lane 1 axe tap --label "Needs you" >/dev/null
check "axe goes to the runs' device only" 'grep -qx "axe tap --label Needs you --udid AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" "$LOG"'
check "axe with a device of its own is refused" '! lane 1 axe tap --udid 11111111-2222-3333-4444-555555555555 2>/dev/null'
check "axe with -- is refused (it would make the gate's --udid an argument)" '! lane 1 axe tap -- 10 10 2>/dev/null'
check "no axe call reached another device" '! grep -q "11111111-2222" <(grep "^axe" "$LOG")'
lane 1 sim openurl "conspector-pair://127.0.0.1:18443/K7Q2" >/dev/null
check "sim names the runs' device" 'grep -qx "xcrun simctl openurl AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE conspector-pair://127.0.0.1:18443/K7Q2" "$LOG"'
check "sim refuses a verb that isn't listed (spawn)" '! lane 1 sim spawn booted ls 2>/dev/null'
check "sim refuses keychain (trust is the only way in)" '! lane 1 sim keychain booted reset 2>/dev/null'
: >"$LOG"
lane 1 type ab >/dev/null
check "type sends one character at a time" '[ "$(grep -c "^axe type . --udid" "$LOG")" -eq 2 ]'
lane 1 shot "$T/shot.png" >/dev/null
check "shot saves the screen" '[ "$(cat "$T/shot.png")" = PNGDATA ]'
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' >"$T/ca.pem"
lane 1 trust "$T/ca.pem" >/dev/null
check "trust adds the authority as a root on the runs' device" 'grep -q "xcrun simctl keychain AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE add-root-cert" "$LOG"'
echo "not a cert" >"$T/bad.pem"
check "trust refuses what isn't a certificate" '! lane 1 trust "$T/bad.pem" 2>/dev/null'

# --- The app from the run's checkout ----------------------------------------------------
app="$T/work/Conspector-gh-1" dep="$T/deps/HotReload"
mkdir -p "$app/Sources/App" "$app/.build" "$dep"
echo "bundleID: com.example.app" >"$app/xtool.yml"
printf '.library(\n    name: "Conspector",\n.package(path: "%s"),\n' "$dep" >"$app/Package.swift"
echo junk >"$app/.build/big"
echo "dep" >"$dep/Package.swift"
: >"$LOG"
lane 1 run "$app" >/dev/null
up="$MAC/ios-sim-run/runs/Conspector-gh-1"
mkdir -p "$MAC/ios-sim-run/runs/Conspector-gh-2/dd"
app2="$T/work/Conspector-gh-2"
mkdir -p "$app2" && cp "$app/xtool.yml" "$app/Package.swift" "$app2/"
check "run copies the run's checkout, without .build" '[ -f "$up/src/xtool.yml" ] && [ ! -e "$up/src/.build" ]'
check "run copies a local package beside it, made relative" '[ -f "$up/deps/HotReload/Package.swift" ] && grep -q "\.\./deps/HotReload" "$up/src/Package.swift"'
lane 1 run "$app2" >/dev/null
check "a new app's upload removes the other apps' builds on the Mac" '[ ! -e "$up" ] && [ -d "$MAC/ios-sim-run/runs/Conspector-gh-2/src" ]'
check "run installs and launches on the runs' device" 'grep -q "xcrun simctl install AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" "$LOG" && grep -q "xcrun simctl launch AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE com.example.app" "$LOG"'

# --- Letting go ---------------------------------------------------------------------------
: >"$LOG"
lane 1 release >/dev/null
for _ in $(seq 50); do [ -d "$MAC/ios-sim-run/runs/.lock" ] || break; sleep 0.1; done
check "release ends the hold and frees the lock" '[ ! -d "$MAC/ios-sim-run/runs/.lock" ]'
check "release erases the runs' device (the scratch pairing goes)" 'grep -q "xcrun simctl erase AAAAAAAA" "$LOG"'
out=$(lane 2 take --label sol)
check "the next run takes it once it is free" '[[ $out == *holding* ]]'
lane 2 release >/dev/null
for _ in $(seq 50); do [ -d "$MAC/ios-sim-run/runs/.lock" ] || break; sleep 0.1; done

# --- A hold that ends because its stdin closes (the run's ssh ended) ----------------------
: >"$LOG"
printf 'kiwi\n' | gate hold >"$T/hold-eof.out" 2>"$T/hold-eof.err" || true
check "a hold whose stdin closes prints its token, then ends" 'grep -q "^token " "$T/hold-eof.out"'
check "it erases the runs' device on the way out" '[ "$(grep -c "xcrun simctl erase AAAAAAAA" "$LOG")" -ge 2 ]'
check "and frees the lock" '[ ! -d "$MAC/ios-sim-run/runs/.lock" ]'

# --- A forward that fails lets the simulator go ---------------------------------------
touch "$T/forward-fails"
set +e
err=$(lane 5 take --label owl 2>&1)
code=$?
set -e
rm -f "$T/forward-fails"
for _ in $(seq 50); do [ -d "$MAC/ios-sim-run/runs/.lock" ] || break; sleep 0.1; done
check "a forward that fails ends the take, says why, and lets the simulator go" '[ $code -eq 1 ] && [[ $err == *"couldn'"'"'t be forwarded back"* ]] && [ ! -d "$MAC/ios-sim-run/runs/.lock" ]'

# --- Breaking a stale hold is serialised -------------------------------------------------
mkdir -p "$MAC/ios-sim-run/runs/.lock" "$MAC/ios-sim-run/runs/.break"
echo 999999 >"$MAC/ios-sim-run/runs/.lock/pid"
set +e
printf 'jay\n' | gate hold >"$T/break.out" 2>&1
code=$?
set -e
check "while another taker is breaking a stale hold, a taker is told busy and breaks nothing" '[ $code -eq 75 ] && [ "$(cat "$MAC/ios-sim-run/runs/.lock/pid")" = 999999 ]'
rmdir "$MAC/ios-sim-run/runs/.break"

# --- A hold whose process died ------------------------------------------------------------
mkdir -p "$MAC/ios-sim-run/runs/.lock"
echo 999999 >"$MAC/ios-sim-run/runs/.lock/pid"
echo ghost >"$MAC/ios-sim-run/runs/.lock/who"
out=$(lane 3 take --label wren)
check "a hold whose process is gone is taken over" '[[ $out == *holding* ]]'
lane 3 release >/dev/null
for _ in $(seq 50); do [ -d "$MAC/ios-sim-run/runs/.lock" ] || break; sleep 0.1; done

# --- A pid from an earlier boot of the Mac ---------------------------------------------
sleep 600 >/dev/null 2>&1 &
alive=$!
mkdir -p "$MAC/ios-sim-run/runs/.lock"
echo "$alive" >"$MAC/ios-sim-run/runs/.lock/pid"
echo "an earlier boot" >"$MAC/ios-sim-run/runs/.lock/boot"
out=$(lane 6 take --label lark 2>&1) || true
kill "$alive" 2>/dev/null || true
check "a hold whose pid is alive but from an earlier boot is taken over" '[[ $out == *holding* ]]'
lane 6 release >/dev/null
for _ in $(seq 50); do [ -d "$MAC/ios-sim-run/runs/.lock" ] || break; sleep 0.1; done

# --- The developer's key ----------------------------------------------------------------
echo "dev key" >"$T/home/.ssh/id_ed25519"
check "a key in ~/.ssh is refused" '! IOS_SIM_LANE_KEY="$T/home/.ssh/id_ed25519" lane 4 status 2>/dev/null'

if [ $fails -gt 0 ]; then echo "$fails failed" >&2; exit 1; fi
echo "all passed"
