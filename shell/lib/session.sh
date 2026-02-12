#!/usr/bin/env bash
# Copilot Session - functions for managing individual conversation sessions.
#
# This module provides functions for sending messages, receiving responses,
# and managing the lifecycle of a conversation session with the Copilot CLI.
#
# Requires: json_rpc.sh

# --- Session State ---
# The active session ID (set by copilot_client_create_session / resume)
COPILOT_SESSION_ID=""
# Last assistant message content from send_and_wait
COPILOT_SESSION_LAST_RESPONSE=""
# Last session events JSON array from get_messages
COPILOT_SESSION_MESSAGES=""

# --- Session Functions ---

# Send a message to the current session.
#
# Arguments:
#   $1 - The prompt text (required)
#   $2 - Optional session ID (defaults to COPILOT_SESSION_ID)
#
# Sets:
#   COPILOT_JSONRPC_LAST_RESPONSE - The full send response
#
# Usage:
#   copilot_session_send "What is 2+2?"
#   message_id=$(copilot_jsonrpc_get_result_field '.messageId')
#
# Returns 0 on success, 1 on failure.
copilot_session_send() {
    local prompt="$1"
    local session_id="${2:-$COPILOT_SESSION_ID}"

    if [[ -z "$session_id" ]]; then
        echo "ERROR: No active session. Create or resume a session first." >&2
        return 1
    fi

    if [[ -z "$prompt" ]]; then
        echo "ERROR: prompt is required" >&2
        return 1
    fi

    local params
    params=$(jq -c -n \
        --arg sid "$session_id" \
        --arg prompt "$prompt" \
        '{"sessionId":$sid,"prompt":$prompt}')

    if ! copilot_jsonrpc_request "session.send" "$params"; then
        echo "ERROR: Failed to send message" >&2
        return 1
    fi

    return 0
}

# Send a message and wait for the session to become idle.
#
# This function sends a prompt, then polls for events until it receives
# a session.idle event, indicating the assistant has finished responding.
#
# Arguments:
#   $1 - The prompt text (required)
#   $2 - Optional session ID (defaults to COPILOT_SESSION_ID)
#   $3 - Timeout in seconds (default: 60)
#   $4 - Poll interval in seconds (default: 1)
#
# Sets:
#   COPILOT_SESSION_LAST_RESPONSE - The last assistant message content (text)
#   COPILOT_JSONRPC_LAST_RESPONSE - The last raw JSON-RPC response
#
# Returns 0 on success (idle reached), 1 on failure or timeout.
copilot_session_send_and_wait() {
    local prompt="$1"
    local session_id="${2:-$COPILOT_SESSION_ID}"
    local timeout="${3:-60}"
    local poll_interval="${4:-1}"

    COPILOT_SESSION_LAST_RESPONSE=""

    if [[ -z "$session_id" ]]; then
        echo "ERROR: No active session. Create or resume a session first." >&2
        return 1
    fi

    if [[ -z "$prompt" ]]; then
        echo "ERROR: prompt is required" >&2
        return 1
    fi

    # Send the message
    local params
    params=$(jq -c -n \
        --arg sid "$session_id" \
        --arg prompt "$prompt" \
        '{"sessionId":$sid,"prompt":$prompt}')

    if ! copilot_jsonrpc_request "session.send" "$params"; then
        echo "ERROR: Failed to send message" >&2
        return 1
    fi

    # Poll for events until we see session.idle
    local deadline
    deadline=$(( $(date +%s) + timeout ))
    local last_assistant_content=""

    while true; do
        local now
        now=$(date +%s)
        if [[ $now -ge $deadline ]]; then
            echo "ERROR: Timeout after ${timeout}s waiting for session.idle" >&2
            COPILOT_SESSION_LAST_RESPONSE="$last_assistant_content"
            return 1
        fi

        # Try to read next message from the stream.
        # The CLI sends notifications as events occur.
        if copilot_jsonrpc_read_message; then
            local msg="$COPILOT_JSONRPC_LAST_RESPONSE"

            # Check if this is a notification
            local method
            method=$(echo "$msg" | jq -r '.method // empty' 2>/dev/null)

            if [[ "$method" == "session.event" ]]; then
                local event_type
                event_type=$(echo "$msg" | jq -r '.params.event.type // empty' 2>/dev/null)

                case "$event_type" in
                    "assistant.message")
                        last_assistant_content=$(echo "$msg" | jq -r '.params.event.data.content // empty' 2>/dev/null)
                        ;;
                    "session.idle")
                        COPILOT_SESSION_LAST_RESPONSE="$last_assistant_content"
                        return 0
                        ;;
                    "session.error")
                        local error_msg
                        error_msg=$(echo "$msg" | jq -r '.params.event.data.message // "Unknown error"' 2>/dev/null)
                        echo "ERROR: Session error: $error_msg" >&2
                        COPILOT_SESSION_LAST_RESPONSE="$last_assistant_content"
                        return 1
                        ;;
                esac
            fi
        fi

        # Brief sleep to avoid busy-waiting
        sleep "$poll_interval"
    done
}

# Get all messages/events from the current session history.
#
# Arguments:
#   $1 - Optional session ID (defaults to COPILOT_SESSION_ID)
#
# Sets:
#   COPILOT_SESSION_MESSAGES - JSON array of all session events
#   COPILOT_JSONRPC_LAST_RESPONSE - The full getMessages response
#
# Usage:
#   copilot_session_get_messages
#   echo "$COPILOT_SESSION_MESSAGES" | jq '.[] | select(.type == "assistant.message") | .data.content'
#
# Returns 0 on success, 1 on failure.
copilot_session_get_messages() {
    local session_id="${1:-$COPILOT_SESSION_ID}"

    COPILOT_SESSION_MESSAGES=""

    if [[ -z "$session_id" ]]; then
        echo "ERROR: No active session. Create or resume a session first." >&2
        return 1
    fi

    local params
    params=$(jq -c -n --arg sid "$session_id" '{"sessionId":$sid}')

    if ! copilot_jsonrpc_request "session.getMessages" "$params"; then
        echo "ERROR: Failed to get messages" >&2
        return 1
    fi

    COPILOT_SESSION_MESSAGES=$(copilot_jsonrpc_get_result_field '.events')
    return 0
}

# Abort the currently processing message in the session.
#
# Arguments:
#   $1 - Optional session ID (defaults to COPILOT_SESSION_ID)
#
# Returns 0 on success, 1 on failure.
copilot_session_abort() {
    local session_id="${1:-$COPILOT_SESSION_ID}"

    if [[ -z "$session_id" ]]; then
        echo "ERROR: No active session. Create or resume a session first." >&2
        return 1
    fi

    local params
    params=$(jq -c -n --arg sid "$session_id" '{"sessionId":$sid}')

    if ! copilot_jsonrpc_request "session.abort" "$params"; then
        echo "ERROR: Failed to abort session" >&2
        return 1
    fi

    return 0
}

# Destroy the current session and release resources.
#
# Arguments:
#   $1 - Optional session ID (defaults to COPILOT_SESSION_ID)
#
# Returns 0 on success, 1 on failure.
copilot_session_destroy() {
    local session_id="${1:-$COPILOT_SESSION_ID}"

    if [[ -z "$session_id" ]]; then
        echo "ERROR: No active session." >&2
        return 1
    fi

    local params
    params=$(jq -c -n --arg sid "$session_id" '{"sessionId":$sid}')

    if ! copilot_jsonrpc_request "session.destroy" "$params"; then
        echo "ERROR: Failed to destroy session" >&2
        return 1
    fi

    # Clear session state if this was the active session
    if [[ "$session_id" == "$COPILOT_SESSION_ID" ]]; then
        COPILOT_SESSION_ID=""
        COPILOT_SESSION_LAST_RESPONSE=""
        COPILOT_SESSION_MESSAGES=""
    fi

    return 0
}
