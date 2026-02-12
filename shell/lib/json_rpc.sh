#!/usr/bin/env bash
# Minimal JSON-RPC 2.0 client for stdio transport using coproc.
#
# This module provides functions for communicating with the Copilot CLI server
# via JSON-RPC 2.0 over stdio using Content-Length framed messages.
# Requires: bash 4+, jq

# --- State ---
# File descriptors for the coproc stdin/stdout
COPILOT_JSONRPC_FD_IN=""
COPILOT_JSONRPC_FD_OUT=""
# PID of the coproc process
COPILOT_JSONRPC_PID=""
# Request ID counter
COPILOT_JSONRPC_REQUEST_ID=0
# Last response (raw JSON)
COPILOT_JSONRPC_LAST_RESPONSE=""
# Last error (raw JSON or empty)
COPILOT_JSONRPC_LAST_ERROR=""

# --- Internal Helpers ---

# Generate the next request ID.
# Sets COPILOT_JSONRPC_REQUEST_ID to the new value.
_copilot_jsonrpc_next_id() {
    COPILOT_JSONRPC_REQUEST_ID=$(( COPILOT_JSONRPC_REQUEST_ID + 1 ))
}

# --- Public Functions ---

# Start the CLI process as a coproc for bidirectional JSON-RPC communication.
#
# Arguments:
#   $1 - Path to the copilot CLI binary (default: "copilot")
#   $2..$n - Additional CLI arguments (optional)
#
# Sets:
#   COPILOT_JSONRPC_FD_IN  - File descriptor for writing to the CLI process stdin
#   COPILOT_JSONRPC_FD_OUT - File descriptor for reading from the CLI process stdout
#   COPILOT_JSONRPC_PID    - PID of the CLI process
#
# Returns 0 on success, 1 on failure.
copilot_jsonrpc_start() {
    local cli_path="${1:-copilot}"
    shift 2>/dev/null || true

    local cli_args=("--headless" "--no-auto-update" "--log-level" "info" "--stdio")
    if [[ $# -gt 0 ]]; then
        cli_args+=("$@")
    fi

    # Verify jq is available
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required but not found in PATH" >&2
        return 1
    fi

    # Verify the CLI binary exists (if not a bare command name)
    if [[ "$cli_path" == */* ]] && [[ ! -x "$cli_path" ]]; then
        echo "ERROR: Copilot CLI not found or not executable at: $cli_path" >&2
        return 1
    fi

    # Start the coproc
    coproc COPILOT_COPROC { "$cli_path" "${cli_args[@]}" 2>/dev/null; }

    if [[ -z "${COPILOT_COPROC_PID:-}" ]]; then
        echo "ERROR: Failed to start copilot CLI process" >&2
        return 1
    fi

    COPILOT_JSONRPC_FD_IN="${COPILOT_COPROC[1]}"
    COPILOT_JSONRPC_FD_OUT="${COPILOT_COPROC[0]}"
    COPILOT_JSONRPC_PID="${COPILOT_COPROC_PID}"
    COPILOT_JSONRPC_REQUEST_ID=0

    return 0
}

# Stop the CLI process and clean up file descriptors.
#
# Returns 0 on success.
copilot_jsonrpc_stop() {
    # Close file descriptors
    if [[ -n "$COPILOT_JSONRPC_FD_IN" ]]; then
        eval "exec ${COPILOT_JSONRPC_FD_IN}>&-" 2>/dev/null || true
        COPILOT_JSONRPC_FD_IN=""
    fi

    # Terminate process
    if [[ -n "$COPILOT_JSONRPC_PID" ]]; then
        kill "$COPILOT_JSONRPC_PID" 2>/dev/null || true
        wait "$COPILOT_JSONRPC_PID" 2>/dev/null || true
        COPILOT_JSONRPC_PID=""
    fi

    COPILOT_JSONRPC_FD_OUT=""
    COPILOT_JSONRPC_REQUEST_ID=0

    return 0
}

# Send a Content-Length framed JSON-RPC message to the CLI process.
#
# Arguments:
#   $1 - The JSON message body (string)
#
# Returns 0 on success, 1 on failure.
copilot_jsonrpc_send_message() {
    local message="$1"

    if [[ -z "$COPILOT_JSONRPC_FD_IN" ]]; then
        echo "ERROR: JSON-RPC connection not started" >&2
        return 1
    fi

    local content_length=${#message}
    local frame
    frame="Content-Length: ${content_length}\r\n\r\n${message}"

    # Write the framed message to the coproc stdin
    printf "Content-Length: %d\r\n\r\n%s" "$content_length" "$message" >&"${COPILOT_JSONRPC_FD_IN}"

    return 0
}

# Read a Content-Length framed JSON-RPC message from the CLI process.
#
# Sets:
#   COPILOT_JSONRPC_LAST_RESPONSE - The raw JSON message body
#
# Returns 0 on success, 1 on failure/EOF.
copilot_jsonrpc_read_message() {
    COPILOT_JSONRPC_LAST_RESPONSE=""

    if [[ -z "$COPILOT_JSONRPC_FD_OUT" ]]; then
        echo "ERROR: JSON-RPC connection not started" >&2
        return 1
    fi

    # Read the Content-Length header line
    local header_line=""
    if ! IFS= read -r header_line <&"${COPILOT_JSONRPC_FD_OUT}"; then
        echo "ERROR: Failed to read header (EOF or broken pipe)" >&2
        return 1
    fi

    # Strip trailing \r if present
    header_line="${header_line%$'\r'}"

    # Parse Content-Length
    if [[ ! "$header_line" =~ ^Content-Length:\ *([0-9]+)$ ]]; then
        echo "ERROR: Invalid header: $header_line" >&2
        return 1
    fi
    local content_length="${BASH_REMATCH[1]}"

    # Read the blank separator line
    local blank_line=""
    IFS= read -r blank_line <&"${COPILOT_JSONRPC_FD_OUT}" || true

    # Read exactly content_length bytes of the body.
    # We use dd for precise byte-level reading from the file descriptor.
    local body=""
    body=$(dd bs=1 count="$content_length" <&"${COPILOT_JSONRPC_FD_OUT}" 2>/dev/null)

    if [[ ${#body} -lt $content_length ]]; then
        echo "ERROR: Short read: expected $content_length bytes, got ${#body}" >&2
        return 1
    fi

    COPILOT_JSONRPC_LAST_RESPONSE="$body"
    return 0
}

# Send a JSON-RPC 2.0 request and wait for the response.
#
# Arguments:
#   $1 - Method name (string)
#   $2 - Params JSON object (string, default: "{}")
#   $3 - Timeout in seconds (integer, default: 30)
#
# Sets:
#   COPILOT_JSONRPC_LAST_RESPONSE - The full JSON-RPC response
#   COPILOT_JSONRPC_LAST_ERROR    - The error object JSON (empty if no error)
#
# Returns 0 on success, 1 on error or timeout.
copilot_jsonrpc_request() {
    local method="$1"
    local params="${2:-\{\}}"
    local timeout="${3:-30}"

    COPILOT_JSONRPC_LAST_RESPONSE=""
    COPILOT_JSONRPC_LAST_ERROR=""

    _copilot_jsonrpc_next_id
    local request_id="$COPILOT_JSONRPC_REQUEST_ID"

    # Build JSON-RPC request using jq for safe JSON construction
    local request
    request=$(jq -c -n \
        --arg method "$method" \
        --arg id "$request_id" \
        --argjson params "$params" \
        '{"jsonrpc":"2.0","id":($id | tonumber),"method":$method,"params":$params}')

    # Send the request
    if ! copilot_jsonrpc_send_message "$request"; then
        COPILOT_JSONRPC_LAST_ERROR='{"code":-1,"message":"Failed to send request"}'
        return 1
    fi

    # Read responses, skipping notifications until we find our response
    local deadline
    deadline=$(( $(date +%s) + timeout ))

    while true; do
        local now
        now=$(date +%s)
        if [[ $now -ge $deadline ]]; then
            COPILOT_JSONRPC_LAST_ERROR='{"code":-1,"message":"Request timed out"}'
            return 1
        fi

        if ! copilot_jsonrpc_read_message; then
            COPILOT_JSONRPC_LAST_ERROR='{"code":-1,"message":"Failed to read response"}'
            return 1
        fi

        local response="$COPILOT_JSONRPC_LAST_RESPONSE"

        # Check if this response has our request ID
        local response_id
        response_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)

        if [[ "$response_id" == "$request_id" ]]; then
            # This is our response. Check for error.
            local has_error
            has_error=$(echo "$response" | jq 'has("error")' 2>/dev/null)

            if [[ "$has_error" == "true" ]]; then
                COPILOT_JSONRPC_LAST_ERROR=$(echo "$response" | jq -c '.error' 2>/dev/null)
                return 1
            fi

            # Success - COPILOT_JSONRPC_LAST_RESPONSE already set
            return 0
        fi

        # Not our response (notification or other) - store and continue
        # Notifications can be processed by the caller if needed
    done
}

# Send a JSON-RPC 2.0 notification (no response expected).
#
# Arguments:
#   $1 - Method name (string)
#   $2 - Params JSON object (string, default: "{}")
#
# Returns 0 on success, 1 on failure.
copilot_jsonrpc_notify() {
    local method="$1"
    local params="${2:-\{\}}"

    local notification
    notification=$(jq -c -n \
        --arg method "$method" \
        --argjson params "$params" \
        '{"jsonrpc":"2.0","method":$method,"params":$params}')

    copilot_jsonrpc_send_message "$notification"
}

# Extract the result field from the last JSON-RPC response.
#
# Usage: result=$(copilot_jsonrpc_get_result)
copilot_jsonrpc_get_result() {
    if [[ -n "$COPILOT_JSONRPC_LAST_RESPONSE" ]]; then
        echo "$COPILOT_JSONRPC_LAST_RESPONSE" | jq -c '.result'
    fi
}

# Extract a specific field from the result of the last JSON-RPC response.
#
# Arguments:
#   $1 - jq expression to extract from .result (e.g., '.sessionId')
#
# Usage: session_id=$(copilot_jsonrpc_get_result_field '.sessionId')
copilot_jsonrpc_get_result_field() {
    local field="$1"
    if [[ -n "$COPILOT_JSONRPC_LAST_RESPONSE" ]]; then
        echo "$COPILOT_JSONRPC_LAST_RESPONSE" | jq -r ".result${field}"
    fi
}

# Check if the JSON-RPC connection is active.
#
# Returns 0 if connected, 1 if not.
copilot_jsonrpc_is_connected() {
    if [[ -n "$COPILOT_JSONRPC_PID" ]] && kill -0 "$COPILOT_JSONRPC_PID" 2>/dev/null; then
        return 0
    fi
    return 1
}
