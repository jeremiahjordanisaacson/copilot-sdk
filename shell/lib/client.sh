#!/usr/bin/env bash
# Copilot CLI SDK Client - Main entry point for the Shell/Bash Copilot SDK.
#
# This module provides functions for managing the connection to the Copilot CLI
# server and session management capabilities.
#
# Requires: json_rpc.sh, sdk_protocol_version.sh

# --- Client State ---
COPILOT_CLIENT_STATE="disconnected"  # disconnected | connecting | connected | error
COPILOT_CLIENT_CLI_PATH=""
COPILOT_CLIENT_LOG_LEVEL="info"

# --- Client Functions ---

# Start the Copilot CLI client.
#
# Spawns the CLI server process and verifies the protocol version.
#
# Arguments:
#   $1 - Path to the copilot CLI binary (default: "copilot" from PATH)
#   $2 - Log level (default: "info")
#
# Returns 0 on success, 1 on failure.
copilot_client_start() {
    local cli_path="${1:-copilot}"
    local log_level="${2:-info}"

    if [[ "$COPILOT_CLIENT_STATE" == "connected" ]]; then
        echo "Client is already connected." >&2
        return 0
    fi

    COPILOT_CLIENT_STATE="connecting"
    COPILOT_CLIENT_CLI_PATH="$cli_path"
    COPILOT_CLIENT_LOG_LEVEL="$log_level"

    # Start the JSON-RPC transport with the CLI process
    if ! copilot_jsonrpc_start "$cli_path" "--log-level" "$log_level"; then
        COPILOT_CLIENT_STATE="error"
        echo "ERROR: Failed to start Copilot CLI process" >&2
        return 1
    fi

    # Verify protocol version
    if ! _copilot_client_verify_protocol_version; then
        COPILOT_CLIENT_STATE="error"
        copilot_jsonrpc_stop
        return 1
    fi

    COPILOT_CLIENT_STATE="connected"
    return 0
}

# Stop the Copilot CLI client and clean up resources.
#
# Returns 0 on success.
copilot_client_stop() {
    copilot_jsonrpc_stop
    COPILOT_CLIENT_STATE="disconnected"
    return 0
}

# Send a ping to the server and verify connectivity.
#
# Arguments:
#   $1 - Optional message to include in the ping
#
# Sets:
#   COPILOT_JSONRPC_LAST_RESPONSE - The full ping response
#
# Usage:
#   copilot_client_ping "hello"
#   protocol_version=$(copilot_jsonrpc_get_result_field '.protocolVersion')
#
# Returns 0 on success, 1 on failure.
copilot_client_ping() {
    local message="${1:-}"

    local params
    if [[ -n "$message" ]]; then
        params=$(jq -c -n --arg msg "$message" '{"message":$msg}')
    else
        params='{}'
    fi

    copilot_jsonrpc_request "ping" "$params"
}

# Create a new conversation session.
#
# Arguments:
#   $1 - Optional model name (string)
#   $2 - Optional system message (string)
#
# Sets:
#   COPILOT_SESSION_ID - The ID of the created session
#   COPILOT_JSONRPC_LAST_RESPONSE - The full create session response
#
# Returns 0 on success, 1 on failure.
copilot_client_create_session() {
    local model="${1:-}"
    local system_message="${2:-}"

    _copilot_client_ensure_connected || return 1

    local params='{}'
    if [[ -n "$model" ]] && [[ -n "$system_message" ]]; then
        params=$(jq -c -n \
            --arg model "$model" \
            --arg sysMsg "$system_message" \
            '{"model":$model,"systemMessage":$sysMsg}')
    elif [[ -n "$model" ]]; then
        params=$(jq -c -n --arg model "$model" '{"model":$model}')
    elif [[ -n "$system_message" ]]; then
        params=$(jq -c -n --arg sysMsg "$system_message" '{"systemMessage":$sysMsg}')
    fi

    if ! copilot_jsonrpc_request "session.create" "$params"; then
        echo "ERROR: Failed to create session" >&2
        return 1
    fi

    COPILOT_SESSION_ID=$(copilot_jsonrpc_get_result_field '.sessionId')
    if [[ -z "$COPILOT_SESSION_ID" ]] || [[ "$COPILOT_SESSION_ID" == "null" ]]; then
        echo "ERROR: No sessionId in response" >&2
        return 1
    fi

    return 0
}

# Resume an existing conversation session.
#
# Arguments:
#   $1 - Session ID to resume (required)
#   $2 - Optional model name (string)
#
# Sets:
#   COPILOT_SESSION_ID - The ID of the resumed session
#   COPILOT_JSONRPC_LAST_RESPONSE - The full resume session response
#
# Returns 0 on success, 1 on failure.
copilot_client_resume_session() {
    local session_id="$1"
    local model="${2:-}"

    _copilot_client_ensure_connected || return 1

    if [[ -z "$session_id" ]]; then
        echo "ERROR: session_id is required" >&2
        return 1
    fi

    local params
    if [[ -n "$model" ]]; then
        params=$(jq -c -n \
            --arg sid "$session_id" \
            --arg model "$model" \
            '{"sessionId":$sid,"model":$model}')
    else
        params=$(jq -c -n --arg sid "$session_id" '{"sessionId":$sid}')
    fi

    if ! copilot_jsonrpc_request "session.resume" "$params"; then
        echo "ERROR: Failed to resume session $session_id" >&2
        return 1
    fi

    COPILOT_SESSION_ID=$(copilot_jsonrpc_get_result_field '.sessionId')
    if [[ -z "$COPILOT_SESSION_ID" ]] || [[ "$COPILOT_SESSION_ID" == "null" ]]; then
        echo "ERROR: No sessionId in resume response" >&2
        return 1
    fi

    return 0
}

# Delete a session permanently.
#
# Arguments:
#   $1 - Session ID to delete (required)
#
# Returns 0 on success, 1 on failure.
copilot_client_delete_session() {
    local session_id="$1"

    _copilot_client_ensure_connected || return 1

    if [[ -z "$session_id" ]]; then
        echo "ERROR: session_id is required" >&2
        return 1
    fi

    local params
    params=$(jq -c -n --arg sid "$session_id" '{"sessionId":$sid}')

    if ! copilot_jsonrpc_request "session.delete" "$params"; then
        echo "ERROR: Failed to delete session $session_id" >&2
        return 1
    fi

    local success
    success=$(copilot_jsonrpc_get_result_field '.success')
    if [[ "$success" != "true" ]]; then
        local error_msg
        error_msg=$(copilot_jsonrpc_get_result_field '.error')
        echo "ERROR: Failed to delete session $session_id: $error_msg" >&2
        return 1
    fi

    return 0
}

# List all available models.
#
# Sets:
#   COPILOT_JSONRPC_LAST_RESPONSE - The full list models response
#
# Usage:
#   copilot_client_list_models
#   models=$(copilot_jsonrpc_get_result_field '.models')
#   echo "$models" | jq -r '.[].id'
#
# Returns 0 on success, 1 on failure.
copilot_client_list_models() {
    _copilot_client_ensure_connected || return 1

    if ! copilot_jsonrpc_request "models.list" "{}"; then
        echo "ERROR: Failed to list models" >&2
        return 1
    fi

    return 0
}

# List all available sessions.
#
# Sets:
#   COPILOT_JSONRPC_LAST_RESPONSE - The full list sessions response
#
# Usage:
#   copilot_client_list_sessions
#   sessions=$(copilot_jsonrpc_get_result_field '.sessions')
#   echo "$sessions" | jq -r '.[].sessionId'
#
# Returns 0 on success, 1 on failure.
copilot_client_list_sessions() {
    _copilot_client_ensure_connected || return 1

    if ! copilot_jsonrpc_request "session.list" "{}"; then
        echo "ERROR: Failed to list sessions" >&2
        return 1
    fi

    return 0
}

# --- Internal Functions ---

# Ensure the client is connected.
# Returns 0 if connected, 1 if not.
_copilot_client_ensure_connected() {
    if [[ "$COPILOT_CLIENT_STATE" != "connected" ]]; then
        echo "ERROR: Client not connected. Call copilot_client_start first." >&2
        return 1
    fi

    if ! copilot_jsonrpc_is_connected; then
        COPILOT_CLIENT_STATE="error"
        echo "ERROR: CLI process is no longer running" >&2
        return 1
    fi

    return 0
}

# Verify the protocol version matches between SDK and server.
# Returns 0 on match, 1 on mismatch.
_copilot_client_verify_protocol_version() {
    local expected_version
    expected_version=$(copilot_get_sdk_protocol_version)

    if ! copilot_client_ping; then
        echo "ERROR: Failed to ping server during protocol verification" >&2
        return 1
    fi

    local server_version
    server_version=$(copilot_jsonrpc_get_result_field '.protocolVersion')

    if [[ -z "$server_version" ]] || [[ "$server_version" == "null" ]]; then
        echo "ERROR: SDK protocol version mismatch: SDK expects version $expected_version, but server does not report a protocol version. Please update your server to ensure compatibility." >&2
        return 1
    fi

    if [[ "$server_version" != "$expected_version" ]]; then
        echo "ERROR: SDK protocol version mismatch: SDK expects version $expected_version, but server reports version $server_version. Please update your SDK or server to ensure compatibility." >&2
        return 1
    fi

    return 0
}
