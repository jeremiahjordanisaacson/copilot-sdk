#!/usr/bin/env bash
# Copilot CLI SDK for Shell/Bash
#
# Main entry point that sources all SDK modules.
# Source this file in your script to use the Copilot SDK:
#
#   source /path/to/copilot_sdk.sh
#
# Requirements:
#   - bash 4.0 or later (for coproc, associative arrays, etc.)
#   - jq (for JSON parsing and construction)
#   - copilot CLI binary in PATH (or provide path to copilot_client_start)
#
# Copyright (c) Microsoft Corporation. All rights reserved.

# Strict mode for sourced modules
set -euo pipefail

# --- Version Check ---
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: Copilot Shell SDK requires bash 4.0 or later (current: ${BASH_VERSION})" >&2
    return 1 2>/dev/null || exit 1
fi

# --- Resolve SDK directory ---
# Handle the case where this file is sourced from different locations.
COPILOT_SDK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Source SDK modules ---
# Order matters: protocol version first, then transport, then higher-level modules.
source "${COPILOT_SDK_DIR}/sdk_protocol_version.sh"
source "${COPILOT_SDK_DIR}/json_rpc.sh"
source "${COPILOT_SDK_DIR}/client.sh"
source "${COPILOT_SDK_DIR}/session.sh"

# --- SDK Info ---
COPILOT_SDK_NAME="copilot-sdk-shell"
COPILOT_SDK_VERSION="0.1.0"
