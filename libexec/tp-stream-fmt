#!/bin/bash
# stream-fmt.sh -- format stream-json output from claude -p into readable text
#
# Usage:
#   tail -f .arachne-agent.log | ./scripts/stream-fmt.sh
#   docker logs -f arachne-agent | ./scripts/stream-fmt.sh
#
# Color key:
#   Blue    = assistant text
#   Yellow  = tool calls
#   Green   = tool results (truncated)
#   Red     = errors
#   Cyan    = ralph iteration markers

BLUE='\033[0;34m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
RESET='\033[0m'

MAX_RESULT_LINES=15

while IFS= read -r line; do
    # Pass through non-JSON lines (ralph iteration markers, smoke test, etc.)
    if ! echo "$line" | jq -e . &>/dev/null 2>&1; then
        if echo "$line" | grep -q "Ralph iteration"; then
            echo -e "${CYAN}${line}${RESET}"
        elif echo "$line" | grep -q "BLOCKED\|ERROR\|error"; then
            echo -e "${RED}${line}${RESET}"
        else
            echo "$line"
        fi
        continue
    fi

    type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
    case "$type" in
        assistant)
            msg=$(echo "$line" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null)
            if [[ -n "$msg" ]]; then
                echo -e "${BLUE}${msg}${RESET}"
            fi
            ;;
        result)
            msg=$(echo "$line" | jq -r '.result // empty' 2>/dev/null)
            cost=$(echo "$line" | jq -r '.cost_usd // empty' 2>/dev/null)
            turns=$(echo "$line" | jq -r '.num_turns // empty' 2>/dev/null)
            if [[ -n "$msg" ]]; then
                echo -e "${GREEN}--- RESULT (${turns} turns, \$${cost}) ---${RESET}"
                echo -e "${GREEN}${msg}${RESET}"
            fi
            ;;
        tool_use)
            tool=$(echo "$line" | jq -r '.tool // empty' 2>/dev/null)
            case "$tool" in
                Read)
                    path=$(echo "$line" | jq -r '.input.file_path // empty' 2>/dev/null)
                    echo -e "${YELLOW}[Read] ${path}${RESET}"
                    ;;
                Edit)
                    path=$(echo "$line" | jq -r '.input.file_path // empty' 2>/dev/null)
                    echo -e "${YELLOW}[Edit] ${path}${RESET}"
                    ;;
                Write)
                    path=$(echo "$line" | jq -r '.input.file_path // empty' 2>/dev/null)
                    echo -e "${YELLOW}[Write] ${path}${RESET}"
                    ;;
                Bash)
                    cmd=$(echo "$line" | jq -r '.input.command // empty' 2>/dev/null)
                    desc=$(echo "$line" | jq -r '.input.description // empty' 2>/dev/null)
                    if [[ -n "$desc" ]]; then
                        echo -e "${YELLOW}[Bash] ${desc}${RESET}"
                    else
                        echo -e "${YELLOW}[Bash] ${cmd:0:120}${RESET}"
                    fi
                    ;;
                Grep)
                    pat=$(echo "$line" | jq -r '.input.pattern // empty' 2>/dev/null)
                    path=$(echo "$line" | jq -r '.input.path // "." ' 2>/dev/null)
                    echo -e "${YELLOW}[Grep] /${pat}/ in ${path}${RESET}"
                    ;;
                Glob)
                    pat=$(echo "$line" | jq -r '.input.pattern // empty' 2>/dev/null)
                    echo -e "${YELLOW}[Glob] ${pat}${RESET}"
                    ;;
                *)
                    echo -e "${YELLOW}[${tool}]${RESET}"
                    ;;
            esac
            ;;
        tool_result)
            # Show truncated output for Bash results (compilation errors, test results)
            tool=$(echo "$line" | jq -r '.tool // empty' 2>/dev/null)
            if [[ "$tool" == "Bash" ]]; then
                output=$(echo "$line" | jq -r '.output // empty' 2>/dev/null)
                if echo "$output" | grep -qi "error\|failed\|FAILED\|panicked"; then
                    echo -e "${RED}$(echo "$output" | tail -n $MAX_RESULT_LINES)${RESET}"
                elif echo "$output" | grep -qi "test result\|Finished\|warning"; then
                    echo -e "${DIM}$(echo "$output" | tail -n 3)${RESET}"
                fi
            fi
            ;;
    esac
done
