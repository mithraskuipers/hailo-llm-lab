#!/bin/bash
# ============================================================
# Hailo-10H / Hailo-Ollama Terminal Manager
# Raspberry Pi 5 + AI HAT+ 2
#
# Uses the Hailo-Ollama REST API.
# No tmux required.
# Every choice in this script (models, confirmations, etc.)
# is a numbered list - just type the number.
# ============================================================

set -u

SERVER_HOST="127.0.0.1"
DEFAULT_SERVER_PORT="8000"
PORT_SEARCH_RANGE=20   # how many ports to try (8000, 8001, 8002, ...)
SERVER_PORT="$DEFAULT_SERVER_PORT"
BASE_URL="http://${SERVER_HOST}:${SERVER_PORT}"

SERVER_LOG="$HOME/.hailo-ollama.log"
SERVER_PID="$HOME/.hailo-ollama.pid"
SERVER_PORT_FILE="$HOME/.hailo-ollama.port"

CURL="curl --silent --show-error --fail"

# ------------------------------------------------------------
# Helper python scripts (progress bar for downloads, realtime
# token streaming for chat). Written out once at startup into
# HELPER_DIR if python3 is available.
# ------------------------------------------------------------
HELPER_DIR="$HOME/.hailo-ollama-helpers"
PULL_PROGRESS_PY="$HELPER_DIR/pull_progress.py"
CHAT_STREAM_PY="$HELPER_DIR/chat_stream.py"
HAVE_PYTHON3=0
if command -v python3 >/dev/null 2>&1; then
    HAVE_PYTHON3=1
fi

# ------------------------------------------------------------
# Colours
# ------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
RESET='\033[0m'

# ------------------------------------------------------------
# Write out the small python helpers used for:
#   - a live progress bar while a model downloads
#   - realtime (token-by-token) display of chat answers
# Only needed/written when python3 is available.
# ------------------------------------------------------------
write_helper_scripts() {
    [ "$HAVE_PYTHON3" -eq 1 ] || return 0
    mkdir -p "$HELPER_DIR" 2>/dev/null || return 1

    cat > "$PULL_PROGRESS_PY" <<'PYEOF'
#!/usr/bin/env python3
# Reads newline-delimited JSON progress events from stdin (Hailo-Ollama
# /api/pull with stream=true) and renders a live progress bar per layer.
import sys
import json

GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
RED = "\033[0;31m"
CYAN = "\033[0;36m"
RESET = "\033[0m"

BAR_WIDTH = 30


def fmt_bytes(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "?"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024.0:
            return f"{n:.1f}{unit}"
        n /= 1024.0
    return f"{n:.1f}PB"


def draw_bar(label, completed, total):
    total = max(total, 1)
    completed = min(completed, total)
    pct = completed / total * 100
    filled = int(BAR_WIDTH * pct / 100)
    bar = "#" * filled + "-" * (BAR_WIDTH - filled)
    label = (label[:20] + "...") if len(label) > 23 else label
    sys.stdout.write(
        f"\r  {CYAN}{label:<23}{RESET} [{GREEN}{bar}{RESET}] "
        f"{pct:5.1f}%  {fmt_bytes(completed):>9} / {fmt_bytes(total):<9}"
    )
    sys.stdout.flush()


def main():
    last_key = None
    had_bar = False
    saw_any = False

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue

        saw_any = True

        if obj.get("error"):
            if had_bar:
                print()
                had_bar = False
            print(f"  {RED}Error: {obj['error']}{RESET}")
            continue

        status = obj.get("status") or ""
        total = obj.get("total")
        completed = obj.get("completed")
        digest = obj.get("digest") or status

        if isinstance(total, (int, float)) and total > 0 and isinstance(completed, (int, float)):
            if digest != last_key:
                if had_bar:
                    print()
                last_key = digest
            draw_bar(status or digest, completed, total)
            had_bar = True
        else:
            if had_bar:
                print()
                had_bar = False
            if status:
                print(f"  {YELLOW}{status}{RESET}")
            last_key = None

    if had_bar:
        print()
    if not saw_any:
        # Nothing parsed as JSON progress - nothing else to do,
        # caller already showed a generic "finished" message.
        pass


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
PYEOF

    cat > "$CHAT_STREAM_PY" <<'PYEOF'
#!/usr/bin/env python3
# Reads newline-delimited JSON chat chunks from stdin (Hailo-Ollama
# /api/chat with stream=true), prints each answer token as it arrives
# so the user sees the answer being written in realtime, and writes
# the fully assembled answer to the output file given as argv[1].
import sys
import json

RED = "\033[0;31m"
RESET = "\033[0m"


def main():
    if len(sys.argv) < 2:
        print("usage: chat_stream.py <output-file>", file=sys.stderr)
        sys.exit(2)

    out_path = sys.argv[1]
    chunks = []

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue

        if obj.get("error"):
            sys.stdout.write(f"\n{RED}Error: {obj['error']}{RESET}\n")
            sys.stdout.flush()
            continue

        content = ""
        message = obj.get("message")
        if isinstance(message, dict):
            content = message.get("content") or ""
        elif isinstance(obj.get("response"), str):
            content = obj.get("response") or ""

        if content:
            sys.stdout.write(content)
            sys.stdout.flush()
            chunks.append(content)

        if obj.get("done"):
            break

    try:
        with open(out_path, "w") as f:
            f.write("".join(chunks))
    except OSError:
        pass


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
PYEOF

    return 0
}

# ------------------------------------------------------------
# Utility functions
# ------------------------------------------------------------
pause() {
    echo
    read -r -p "Press ENTER to continue..." _
}

header() {
    clear
    echo
    echo -e "${CYAN}============================================================${RESET}"
    echo -e "${WHITE}          Hailo-10H LLM Manager${RESET}"
    echo -e "${CYAN}============================================================${RESET}"
    echo
}

server_is_running() {
    if curl --silent --max-time 2 "$BASE_URL/api/version" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

cleanup_dead_pid() {
    if [ -f "$SERVER_PID" ]; then
        PID="$(cat "$SERVER_PID" 2>/dev/null || true)"
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            # Our tracked server is alive - make sure we're pointed at
            # whatever port it actually started on (it may have picked
            # a fallback port on a previous run of this script).
            if [ -f "$SERVER_PORT_FILE" ]; then
                local saved_port
                saved_port="$(cat "$SERVER_PORT_FILE" 2>/dev/null || true)"
                if [[ "$saved_port" =~ ^[0-9]+$ ]]; then
                    SERVER_PORT="$saved_port"
                    BASE_URL="http://${SERVER_HOST}:${SERVER_PORT}"
                fi
            fi
        else
            # No live tracked process - clear state and go back to the
            # default port so the next start tries 8000 first again.
            rm -f "$SERVER_PID" "$SERVER_PORT_FILE"
            SERVER_PORT="$DEFAULT_SERVER_PORT"
            BASE_URL="http://${SERVER_HOST}:${SERVER_PORT}"
        fi
    else
        rm -f "$SERVER_PORT_FILE" 2>/dev/null || true
        SERVER_PORT="$DEFAULT_SERVER_PORT"
        BASE_URL="http://${SERVER_HOST}:${SERVER_PORT}"
    fi
}

# ------------------------------------------------------------
# Port selection - if the default port is taken, try the next
# ones automatically instead of just failing.
# ------------------------------------------------------------

# Returns 0 (true) if $1 is free to bind on $SERVER_HOST.
port_is_free() {
    local port="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$SERVER_HOST" "$port" <<'PYEOF'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind((host, port))
    s.close()
    sys.exit(0)
except OSError:
    sys.exit(1)
PYEOF
        return $?
    elif command -v ss >/dev/null 2>&1; then
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[.:]${port}\$"; then
            return 1
        fi
        return 0
    else
        # Last resort: a connect test (less reliable than a bind test,
        # but works with nothing but bash itself).
        if (exec 3<>"/dev/tcp/${SERVER_HOST}/${port}") 2>/dev/null; then
            exec 3>&- 3<&-
            return 1
        fi
        return 0
    fi
}

# Prints the first free port at or after $1 (searching up to $2 ports).
# Returns 1 if none were free in that range.
find_free_port() {
    local start_port="$1" max_tries="${2:-$PORT_SEARCH_RANGE}" port tries=0
    port="$start_port"
    while [ "$tries" -lt "$max_tries" ]; do
        if port_is_free "$port"; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
        tries=$((tries + 1))
    done
    return 1
}

start_server() {
    if server_is_running; then
        echo -e "${GREEN}Hailo-Ollama is already running on ${BASE_URL}.${RESET}"
        return 0
    fi

    echo -e "${YELLOW}Starting Hailo-Ollama...${RESET}"
    cleanup_dead_pid

    # cleanup_dead_pid may have discovered our tracked instance is
    # still alive on a different (fallback) port - re-check before
    # launching a second one.
    if server_is_running; then
        echo -e "${GREEN}Hailo-Ollama is already running on ${BASE_URL}.${RESET}"
        return 0
    fi

    local port
    if ! port="$(find_free_port "$DEFAULT_SERVER_PORT" "$PORT_SEARCH_RANGE")"; then
        echo -e "${RED}Could not find a free port between ${DEFAULT_SERVER_PORT} and $((DEFAULT_SERVER_PORT + PORT_SEARCH_RANGE - 1)).${RESET}"
        return 1
    fi

    if [ "$port" != "$DEFAULT_SERVER_PORT" ]; then
        echo -e "${YELLOW}Port ${DEFAULT_SERVER_PORT} is already in use - using ${port} instead.${RESET}"
    fi

    SERVER_PORT="$port"
    BASE_URL="http://${SERVER_HOST}:${SERVER_PORT}"
    echo "$SERVER_PORT" > "$SERVER_PORT_FILE"

    # Start independently from this shell so SSH disconnects
    # do not terminate the server. OLLAMA_HOST tells hailo-ollama
    # which interface/port to bind (see docs/USAGE.rst).
    OLLAMA_HOST="${SERVER_HOST}:${SERVER_PORT}" \
        nohup hailo-ollama >"$SERVER_LOG" 2>&1 < /dev/null &
    PID=$!
    echo "$PID" > "$SERVER_PID"

    echo "PID:  $PID"
    echo "Port: $SERVER_PORT"
    echo "Log:  $SERVER_LOG"
    echo -n "Waiting for server"

    for i in $(seq 1 30); do
        if server_is_running; then
            echo
            echo -e "${GREEN}Hailo-Ollama is running on ${BASE_URL}.${RESET}"
            return 0
        fi
        echo -n "."
        sleep 1
    done

    echo
    echo -e "${RED}Hailo-Ollama did not start successfully.${RESET}"
    echo
    echo "Last log output:"
    echo "------------------------------------------------------------"
    tail -40 "$SERVER_LOG" 2>/dev/null || true
    echo "------------------------------------------------------------"
    return 1
}

stop_server() {
    cleanup_dead_pid

    if [ -f "$SERVER_PID" ]; then
        PID="$(cat "$SERVER_PID" 2>/dev/null || true)"
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "Stopping Hailo-Ollama (PID $PID)..."
            kill "$PID" 2>/dev/null || true

            for i in $(seq 1 10); do
                if ! kill -0 "$PID" 2>/dev/null; then
                    break
                fi
                sleep 1
            done

            if kill -0 "$PID" 2>/dev/null; then
                echo -e "${YELLOW}Server did not stop gracefully; terminating...${RESET}"
                kill -9 "$PID" 2>/dev/null || true
            fi
        fi
        rm -f "$SERVER_PID"
    fi

    # In case the PID file is stale or the process was started
    # outside this manager.
    pkill -x hailo-ollama 2>/dev/null || true
    sleep 1

    if server_is_running; then
        echo -e "${RED}Hailo-Ollama is still running.${RESET}"
        return 1
    fi

    # Clear saved port state so the next start tries the default
    # port (8000) first again.
    rm -f "$SERVER_PORT_FILE"
    SERVER_PORT="$DEFAULT_SERVER_PORT"
    BASE_URL="http://${SERVER_HOST}:${SERVER_PORT}"

    echo -e "${GREEN}Hailo-Ollama stopped.${RESET}"
}

ensure_server() {
    if ! server_is_running; then
        echo -e "${YELLOW}Hailo-Ollama is not running. Starting it...${RESET}"
        echo
        if ! start_server; then
            return 1
        fi
        echo
    fi
    return 0
}

json_pretty() {
    if command -v jq >/dev/null 2>&1; then
        jq .
    else
        cat
    fi
}

# ------------------------------------------------------------
# JSON helpers (work with or without jq - fixes the raw JSON
# dump you were seeing, since jq isn't installed on your Pi)
# ------------------------------------------------------------

# Reads a Hailo-Ollama style {"models":[...]} JSON blob on stdin
# and prints one model name per line.
json_extract_names() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '
            if .models then
                .models[] |
                if type == "string" then .
                elif .name then .name
                elif .model then .model
                else empty end
            else empty end
        ' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in data.get("models", []):
    if isinstance(m, str):
        print(m)
    elif isinstance(m, dict):
        print(m.get("name") or m.get("model") or "")
' 2>/dev/null
    else
        # Last-resort fallback: pull quoted tokens, skip the "models" key itself.
        grep -oE '"[A-Za-z0-9_.:/-]+"' | tr -d '"' | tail -n +2
    fi
}

# Reads a Hailo-Ollama style {"models":[...]} JSON blob on stdin
# and prints "name<TAB>size" per line (size in bytes, 0 if unknown).
json_extract_name_size() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.models[]? | [(.name // .model // "unknown"), (.size // 0)] | @tsv' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in data.get("models", []):
    if isinstance(m, str):
        print(f"{m}\t0")
    elif isinstance(m, dict):
        name = m.get("name") or m.get("model") or "unknown"
        size = m.get("size") or 0
        print(f"{name}\t{size}")
' 2>/dev/null
    else
        grep -oE '"[A-Za-z0-9_.:/-]+"' | tr -d '"' | tail -n +2 | while read -r n; do printf "%s\t0\n" "$n"; done
    fi
}

# ------------------------------------------------------------
# Numbered list / selection helpers
# ------------------------------------------------------------

# Prints a plain numbered list from the array named in $1.
print_numbered_names() {
    local -n _arr="$1"
    local i
    for i in "${!_arr[@]}"; do
        printf "  %2d) %s\n" "$((i + 1))" "${_arr[$i]}"
    done
}

# Prints a numbered list with a size column, from the name array
# named in $1 and the matching byte-size array named in $2.
print_numbered_names_with_size() {
    local -n _names="$1"
    local -n _sizes="$2"
    local i size_mb
    for i in "${!_names[@]}"; do
        if [[ "${_sizes[$i]}" =~ ^[0-9]+$ ]] && [ "${_sizes[$i]}" -gt 0 ]; then
            size_mb=$(( _sizes[$i] / 1024 / 1024 ))
            printf "  %2d) %-35s %8s MB\n" "$((i + 1))" "${_names[$i]}" "$size_mb"
        else
            printf "  %2d) %s\n" "$((i + 1))" "${_names[$i]}"
        fi
    done
}

# Loops until the user picks a valid number from the array named
# in $1, or 0 to cancel. Result goes in SELECTED_MODEL.
# Returns 0 on a real selection, 1 on cancel.
select_model_by_number() {
    local -n _names="$1"
    local choice idx

    while true; do
        echo
        echo "   0) Cancel"
        read -r -p "Enter number: " choice

        if [ -z "$choice" ]; then
            continue
        fi
        if [ "$choice" = "0" ]; then
            SELECTED_MODEL=""
            return 1
        fi
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Please enter a number from the list.${RESET}"
            continue
        fi

        idx=$((choice - 1))
        if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#_names[@]}" ]; then
            echo -e "${RED}Invalid number. Try again.${RESET}"
            continue
        fi

        SELECTED_MODEL="${_names[$idx]}"
        return 0
    done
}

# Numbered yes/no confirmation. Returns 0 for yes, 1 for no.
confirm_numbered() {
    local prompt="${1:-Are you sure?}"
    local choice
    while true; do
        echo
        echo -e "${YELLOW}${prompt}${RESET}"
        echo "  1) Yes"
        echo "  2) No"
        read -r -p "Choose: " choice
        case "$choice" in
            1) return 0 ;;
            2) return 1 ;;
            *) echo -e "${RED}Please enter 1 or 2.${RESET}" ;;
        esac
    done
}

# ------------------------------------------------------------
# Hardware / software information
# ------------------------------------------------------------
hardware_status() {
    header
    echo -e "${WHITE}Hailo hardware/runtime status${RESET}"
    echo

    if command -v hailortcli >/dev/null 2>&1; then
        hailortcli fw-control identify
    else
        echo -e "${RED}hailortcli not found.${RESET}"
    fi

    echo
    echo -e "${WHITE}Hailo packages:${RESET}"
    dpkg -l 2>/dev/null | grep -E \
        'h10-hailort|hailo-h10-all|hailo-gen-ai-model-zoo|h10-hailort-pcie-driver' \
        || true

    echo
    echo -e "${WHITE}Hailo-Ollama:${RESET}"
    if server_is_running; then
        echo -e "${GREEN}RUNNING${RESET}"
        curl --silent "$BASE_URL/api/version" | json_pretty
    else
        echo -e "${YELLOW}NOT RUNNING${RESET}"
    fi

    pause
}

# ------------------------------------------------------------
# Available models (from Hailo, not yet necessarily downloaded)
# Populates AVAILABLE_MODELS array. Returns 1 if none found.
# ------------------------------------------------------------
get_available_models() {
    ensure_server || return 1

    RESPONSE="$($CURL "$BASE_URL/hailo/v1/list" 2>&1)" || {
        echo -e "${RED}Could not retrieve model list.${RESET}"
        echo "$RESPONSE"
        return 1
    }

    AVAILABLE_MODELS=()
    while IFS= read -r NAME; do
        [ -z "$NAME" ] && continue
        AVAILABLE_MODELS+=("$NAME")
    done < <(echo "$RESPONSE" | json_extract_names)

    if [ "${#AVAILABLE_MODELS[@]}" -eq 0 ]; then
        echo -e "${YELLOW}No models returned by the server.${RESET}"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# Installed models (already downloaded to this Pi)
# Populates INSTALLED_MODELS and INSTALLED_SIZES arrays.
# Returns 1 if none found.
# ------------------------------------------------------------
get_installed_models() {
    ensure_server || return 1

    RESPONSE="$($CURL "$BASE_URL/api/tags" 2>&1)" || {
        echo -e "${RED}Could not retrieve installed models.${RESET}"
        echo "$RESPONSE"
        return 1
    }

    INSTALLED_MODELS=()
    INSTALLED_SIZES=()
    while IFS=$'\t' read -r NAME SIZE; do
        [ -z "$NAME" ] && continue
        INSTALLED_MODELS+=("$NAME")
        INSTALLED_SIZES+=("${SIZE:-0}")
    done < <(echo "$RESPONSE" | json_extract_name_size)

    if [ "${#INSTALLED_MODELS[@]}" -eq 0 ]; then
        echo -e "${YELLOW}No models have been downloaded yet.${RESET}"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# Download model
# ------------------------------------------------------------
download_model() {
    header
    echo -e "${WHITE}Download a Hailo model${RESET}"
    echo
    echo -e "${CYAN}Models available from Hailo:${RESET}"
    echo

    if ! get_available_models; then
        pause
        return 1
    fi

    print_numbered_names AVAILABLE_MODELS

    if ! select_model_by_number AVAILABLE_MODELS; then
        echo -e "${YELLOW}Cancelled.${RESET}"
        pause
        return
    fi
    MODEL="$SELECTED_MODEL"

    echo
    echo -e "${YELLOW}Downloading:${RESET} $MODEL"
    echo
    echo "This may take some time."
    echo

    # stream=true allows us to display progress/messages returned
    # by Hailo-Ollama.
    if [ "$HAVE_PYTHON3" -eq 1 ] && [ -f "$PULL_PROGRESS_PY" ]; then
        curl --no-buffer --silent --show-error \
            "$BASE_URL/api/pull" \
            -H 'Content-Type: application/json' \
            -d "{\"model\":\"$MODEL\",\"stream\":true}" \
            | python3 "$PULL_PROGRESS_PY"
        DOWNLOAD_STATUS=${PIPESTATUS[0]}
    else
        curl --no-buffer --silent --show-error \
            "$BASE_URL/api/pull" \
            -H 'Content-Type: application/json' \
            -d "{\"model\":\"$MODEL\",\"stream\":true}"
        DOWNLOAD_STATUS=$?
    fi

    echo
    if [ "$DOWNLOAD_STATUS" -eq 0 ]; then
        echo -e "${GREEN}Download request finished.${RESET}"
    else
        echo -e "${RED}Download request failed.${RESET}"
    fi
    pause
}

# ------------------------------------------------------------
# Remove model
# ------------------------------------------------------------
remove_model() {
    header
    echo -e "${WHITE}Remove a downloaded model${RESET}"
    echo

    if ! get_installed_models; then
        pause
        return 1
    fi

    print_numbered_names_with_size INSTALLED_MODELS INSTALLED_SIZES

    if ! select_model_by_number INSTALLED_MODELS; then
        echo -e "${YELLOW}Cancelled.${RESET}"
        pause
        return
    fi
    MODEL="$SELECTED_MODEL"

    if ! confirm_numbered "Delete '$MODEL'? This cannot be undone."; then
        echo "Cancelled."
        pause
        return
    fi

    echo
    RESPONSE="$(
        curl --silent --show-error \
            -X DELETE "$BASE_URL/api/delete" \
            -H 'Content-Type: application/json' \
            -d "{\"model\":\"$MODEL\"}" \
            2>&1
    )"
    STATUS=$?

    if [ "$STATUS" -eq 0 ]; then
        echo -e "${GREEN}Model removal request completed.${RESET}"
        echo "$RESPONSE" | json_pretty
    else
        echo -e "${RED}Failed to remove model.${RESET}"
        echo "$RESPONSE"
    fi

    pause
}

# ------------------------------------------------------------
# Model information
# ------------------------------------------------------------
model_info() {
    header
    echo -e "${WHITE}Model information${RESET}"
    echo

    if ! get_installed_models; then
        pause
        return 1
    fi

    print_numbered_names_with_size INSTALLED_MODELS INSTALLED_SIZES

    if ! select_model_by_number INSTALLED_MODELS; then
        return
    fi
    MODEL="$SELECTED_MODEL"

    echo
    RESPONSE="$(
        curl --silent --show-error \
            "$BASE_URL/api/show" \
            -H 'Content-Type: application/json' \
            -d "{\"model\":\"$MODEL\"}" \
            2>&1
    )"
    echo "$RESPONSE" | json_pretty
    pause
}

# ------------------------------------------------------------
# Loaded models
# ------------------------------------------------------------
loaded_models() {
    ensure_server || return 1

    header
    echo -e "${WHITE}Models currently loaded in Hailo-Ollama${RESET}"
    echo
    curl --silent --show-error "$BASE_URL/api/ps" | json_pretty
    pause
}

# ------------------------------------------------------------
# Interactive chat
# ------------------------------------------------------------
chat() {
    header
    echo -e "${WHITE}Hailo-Ollama Interactive Chat${RESET}"
    echo

    if ! get_installed_models; then
        pause
        return 1
    fi

    print_numbered_names_with_size INSTALLED_MODELS INSTALLED_SIZES

    if ! select_model_by_number INSTALLED_MODELS; then
        return
    fi
    MODEL="$SELECTED_MODEL"

    echo
    echo -e "${GREEN}Chatting with $MODEL${RESET}"
    echo
    echo "Commands:"
    echo "  /quit    Return to main menu"
    echo "  /exit    Return to main menu"
    echo "  /clear   Start a new conversation"
    echo
    echo "------------------------------------------------------------"

    # Conversation history.
    # Stored as a JSON array using jq if available, otherwise python3.
    MESSAGES='[]'

    while true; do
        echo
        printf "${CYAN}You>${RESET} "
        IFS= read -r PROMPT

        case "$PROMPT" in
            /quit|/exit)
                echo
                echo "Returning to main menu..."
                return
                ;;
            /clear)
                MESSAGES='[]'
                echo -e "${YELLOW}Conversation cleared.${RESET}"
                continue
                ;;
            "")
                continue
                ;;
        esac

        # We can only show the answer being written in realtime when
        # python3 is available to parse the streamed NDJSON chunks -
        # otherwise fall back to a single blocking request.
        CAN_STREAM=0
        if [ "$HAVE_PYTHON3" -eq 1 ] && [ -f "$CHAT_STREAM_PY" ]; then
            CAN_STREAM=1
        fi

        if command -v jq >/dev/null 2>&1; then
            MESSAGES="$(
                jq --arg content "$PROMPT" \
                    '. + [{"role":"user","content":$content}]' \
                    <<< "$MESSAGES"
            )"
            REQUEST="$(
                jq -n \
                    --arg model "$MODEL" \
                    --argjson messages "$MESSAGES" \
                    --argjson stream "$([ "$CAN_STREAM" -eq 1 ] && echo true || echo false)" \
                    '{model: $model, messages: $messages, stream: $stream}'
            )"
        elif command -v python3 >/dev/null 2>&1; then
            MESSAGES="$(python3 -c '
import json, sys
msgs = json.loads(sys.argv[1])
msgs.append({"role": "user", "content": sys.argv[2]})
print(json.dumps(msgs))
' "$MESSAGES" "$PROMPT")"
            REQUEST="$(python3 -c '
import json, sys
print(json.dumps({"model": sys.argv[1], "messages": json.loads(sys.argv[2]), "stream": sys.argv[3] == "1"}))
' "$MODEL" "$MESSAGES" "$CAN_STREAM")"
        else
            echo -e "${RED}jq or python3 is required for interactive conversation history.${RESET}"
            echo "Install one with:"
            echo
            echo "  sudo apt install jq"
            echo
            pause
            return
        fi

        echo
        printf "${GREEN}Hailo>${RESET} "

        if [ "$CAN_STREAM" -eq 1 ]; then
            # Stream the response so the answer appears as it's being
            # generated, instead of waiting for the whole thing.
            OUT_FILE="$(mktemp)"
            ERR_FILE="$(mktemp)"

            curl --no-buffer --silent --show-error \
                --max-time 0 \
                "$BASE_URL/api/chat" \
                -H 'Content-Type: application/json' \
                -d "$REQUEST" \
                2> "$ERR_FILE" \
                | python3 "$CHAT_STREAM_PY" "$OUT_FILE"
            STATUS=${PIPESTATUS[0]}
            echo

            if [ "$STATUS" -ne 0 ]; then
                echo -e "${RED}Chat request failed.${RESET}"
                cat "$ERR_FILE" 2>/dev/null
                rm -f "$OUT_FILE" "$ERR_FILE"
                continue
            fi

            ASSISTANT="$(cat "$OUT_FILE" 2>/dev/null)"
            rm -f "$OUT_FILE" "$ERR_FILE"

            if [ -z "$ASSISTANT" ]; then
                echo -e "${YELLOW}(empty response)${RESET}"
                continue
            fi
        else
            RESPONSE="$(
                curl --silent --show-error \
                    --max-time 0 \
                    "$BASE_URL/api/chat" \
                    -H 'Content-Type: application/json' \
                    -d "$REQUEST" \
                    2>&1
            )"
            STATUS=$?

            if [ "$STATUS" -ne 0 ]; then
                echo
                echo -e "${RED}Chat request failed.${RESET}"
                echo "$RESPONSE"
                continue
            fi

            if command -v jq >/dev/null 2>&1; then
                if ! echo "$RESPONSE" | jq -e . >/dev/null 2>&1; then
                    echo
                    echo "$RESPONSE"
                    continue
                fi
                ASSISTANT="$(echo "$RESPONSE" | jq -r '.message.content // .response // empty')"
            else
                ASSISTANT="$(python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
msg = data.get("message", {})
content = msg.get("content") if isinstance(msg, dict) else None
print(content or data.get("response") or "")
' "$RESPONSE" 2>/dev/null)" || {
                    echo
                    echo "$RESPONSE"
                    continue
                }
            fi

            if [ -z "$ASSISTANT" ]; then
                echo
                echo "$RESPONSE" | json_pretty
                continue
            fi

            echo "$ASSISTANT"
        fi

        # Add assistant answer to history.
        if command -v jq >/dev/null 2>&1; then
            MESSAGES="$(
                jq --arg content "$ASSISTANT" \
                    '. + [{"role":"assistant","content":$content}]' \
                    <<< "$MESSAGES"
            )"
        else
            MESSAGES="$(python3 -c '
import json, sys
msgs = json.loads(sys.argv[1])
msgs.append({"role": "assistant", "content": sys.argv[2]})
print(json.dumps(msgs))
' "$MESSAGES" "$ASSISTANT")"
        fi
    done
}

# ------------------------------------------------------------
# Server log
# ------------------------------------------------------------
show_log() {
    header
    echo -e "${WHITE}Hailo-Ollama log${RESET}"
    echo
    echo "Log file: $SERVER_LOG"
    echo
    echo "------------------------------------------------------------"
    if [ -f "$SERVER_LOG" ]; then
        tail -100 "$SERVER_LOG"
    else
        echo "No log file found."
    fi
    echo "------------------------------------------------------------"
    pause
}

# ------------------------------------------------------------
# Restart server
# ------------------------------------------------------------
restart_server() {
    header
    stop_server
    echo
    start_server
    pause
}

# ------------------------------------------------------------
# Main menu
# ------------------------------------------------------------
main_menu() {
    while true; do
        cleanup_dead_pid
        header

        if server_is_running; then
            SERVER_STATUS="${GREEN}RUNNING${RESET}"
        else
            SERVER_STATUS="${RED}STOPPED${RESET}"
        fi

        echo -e "Server: $SERVER_STATUS"
        echo -e "API:    ${BASE_URL}"
        echo
        echo "  1) Start server"
        echo "  2) Stop server"
        echo "  3) Restart server"
        echo
        echo "  4) Chat with a model"
        echo "  5) Download model"
        echo "  6) List downloaded models"
        echo "  7) Remove downloaded model"
        echo "  8) Model information"
        echo "  9) Show loaded models"
        echo
        echo " 10) List available Hailo models"
        echo " 11) Hardware / software status"
        echo " 12) Show server log"
        echo
        echo "  0) Exit"
        echo

        read -r -p "Select an option: " OPTION

        case "$OPTION" in
            1) start_server; pause ;;
            2) stop_server; pause ;;
            3) restart_server ;;
            4) chat ;;
            5) download_model ;;
            6)
                header
                echo -e "${WHITE}Models downloaded to this Raspberry Pi${RESET}"
                echo
                if get_installed_models; then
                    print_numbered_names_with_size INSTALLED_MODELS INSTALLED_SIZES
                fi
                pause
                ;;
            7) remove_model ;;
            8) model_info ;;
            9) loaded_models ;;
            10)
                header
                echo -e "${WHITE}Models available from Hailo${RESET}"
                echo
                if get_available_models; then
                    print_numbered_names AVAILABLE_MODELS
                fi
                pause
                ;;
            11) hardware_status ;;
            12) show_log ;;
            0)
                echo
                echo "Goodbye."
                exit 0
                ;;
            *)
                echo
                echo -e "${RED}Invalid option.${RESET}"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------
# Startup
# ------------------------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required."
    exit 1
fi

if ! command -v hailo-ollama >/dev/null 2>&1; then
    echo "ERROR: hailo-ollama is not installed."
    exit 1
fi

if [ "$HAVE_PYTHON3" -eq 1 ]; then
    if ! write_helper_scripts; then
        echo -e "${YELLOW}Warning: could not write helper scripts to ${HELPER_DIR}; falling back to plain output.${RESET}"
        HAVE_PYTHON3=0
    fi
else
    echo -e "${YELLOW}Note: python3 not found - download progress bar and realtime chat streaming are disabled.${RESET}"
    sleep 1
fi

main_menu
