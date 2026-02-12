#!/usr/bin/env bash
# Basic example of using the Copilot Shell SDK.
#
# This script demonstrates:
#   1. Starting the Copilot CLI client
#   2. Creating a conversation session
#   3. Sending messages and receiving responses
#   4. Listing models
#   5. Retrieving session history
#   6. Cleaning up resources
#
# Requirements:
#   - bash 4.0+
#   - jq
#   - copilot CLI in PATH (or set COPILOT_CLI_PATH)
#
# Usage:
#   ./basic_example.sh
#   COPILOT_CLI_PATH=/path/to/copilot ./basic_example.sh

set -euo pipefail

# --- Resolve and source the SDK ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_LIB_DIR="${SCRIPT_DIR}/../lib"

source "${SDK_LIB_DIR}/copilot_sdk.sh"

# --- Configuration ---
CLI_PATH="${COPILOT_CLI_PATH:-copilot}"

# --- Cleanup on exit ---
cleanup() {
    echo ""
    echo "Cleaning up..."
    if [[ -n "${COPILOT_SESSION_ID:-}" ]]; then
        copilot_session_destroy "$COPILOT_SESSION_ID" 2>/dev/null || true
    fi
    copilot_client_stop 2>/dev/null || true
    echo "Done."
}
trap cleanup EXIT

# --- Main ---
echo "=== Copilot Shell SDK Example ==="
echo ""

# 1. Start the client
echo "Starting Copilot CLI client..."
if ! copilot_client_start "$CLI_PATH" "info"; then
    echo "FATAL: Could not start Copilot CLI client." >&2
    exit 1
fi
echo "Client started successfully (protocol version: $(copilot_get_sdk_protocol_version))"
echo ""

# 2. List available models
echo "Listing available models..."
if copilot_client_list_models; then
    echo "Available models:"
    copilot_jsonrpc_get_result_field '.models' | jq -r '.[] | "  - \(.id) (\(.name // "unnamed"))"'
    echo ""
else
    echo "Warning: Could not list models (may require authentication)"
    echo ""
fi

# 3. Create a session
echo "Creating a new session..."
if ! copilot_client_create_session; then
    echo "FATAL: Could not create session." >&2
    exit 1
fi
echo "Session created: $COPILOT_SESSION_ID"
echo ""

# 4. Send a simple message and wait for the response
echo "Sending message: 'What is 2+2? Reply with just the number.'"
if copilot_session_send_and_wait "What is 2+2? Reply with just the number."; then
    echo "Response: $COPILOT_SESSION_LAST_RESPONSE"
else
    echo "Warning: send_and_wait did not complete successfully."
    echo "Partial response: $COPILOT_SESSION_LAST_RESPONSE"
fi
echo ""

# 5. Send a follow-up message (conversation context is maintained)
echo "Sending follow-up: 'Now multiply that by 10.'"
if copilot_session_send_and_wait "Now multiply that by 10."; then
    echo "Response: $COPILOT_SESSION_LAST_RESPONSE"
else
    echo "Warning: send_and_wait did not complete successfully."
fi
echo ""

# 6. Get full message history
echo "Retrieving session history..."
if copilot_session_get_messages; then
    local_msg_count=$(echo "$COPILOT_SESSION_MESSAGES" | jq 'length')
    echo "Total events in session: $local_msg_count"

    echo ""
    echo "--- Conversation History ---"
    echo "$COPILOT_SESSION_MESSAGES" | jq -r '
        .[] |
        if .type == "user.message" then
            "User: \(.data.prompt // .data.content // "(no content)")"
        elif .type == "assistant.message" then
            "Assistant: \(.data.content // "(no content)")"
        else
            empty
        end
    '
    echo "--- End History ---"
else
    echo "Warning: Could not retrieve messages."
fi
echo ""

# 7. List sessions to show ours exists
echo "Listing sessions..."
if copilot_client_list_sessions; then
    echo "Active sessions:"
    copilot_jsonrpc_get_result_field '.sessions' | jq -r '.[] | "  - \(.sessionId)"'
fi
echo ""

# 8. Destroy the session (cleanup trap also handles this)
echo "Destroying session $COPILOT_SESSION_ID..."
if copilot_session_destroy; then
    echo "Session destroyed."
    COPILOT_SESSION_ID=""  # Prevent double-destroy in cleanup
fi
echo ""

echo "=== Example Complete ==="
