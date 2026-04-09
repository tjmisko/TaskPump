#!/bin/bash
# stream-fmt.sh -- format stream-json output from claude -p into readable text
# Pipe docker logs into this: docker logs -f container | stream-fmt.sh

while IFS= read -r line; do
    type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
    case "$type" in
        assistant)
            msg=$(echo "$line" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null)
            if [[ -n "$msg" ]]; then
                echo "$msg"
            fi
            ;;
        result)
            msg=$(echo "$line" | jq -r '.result // empty' 2>/dev/null)
            if [[ -n "$msg" ]]; then
                echo "--- RESULT ---"
                echo "$msg"
            fi
            ;;
        tool_use)
            tool=$(echo "$line" | jq -r '.tool // empty' 2>/dev/null)
            if [[ -n "$tool" ]]; then
                echo "[tool: $tool]"
            fi
            ;;
        tool_result)
            # skip verbose tool results
            ;;
        *)
            # Pass through non-JSON lines (smoke test output, etc.)
            if ! echo "$line" | jq -e . &>/dev/null; then
                echo "$line"
            fi
            ;;
    esac
done
