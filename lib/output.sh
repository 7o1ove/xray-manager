#!/usr/bin/env bash

RED="\033[31m"
GREEN="\033[92m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

pause(){
    echo
    read -r -p "$(prompt_text "Press Enter to continue...")"
}

info(){
    echo -e "${CYAN}==> $1${RESET}"
}

success(){
    echo
    echo -e "${GREEN}$1${RESET}"
}

warning(){
    echo
    echo -e "${YELLOW}$1${RESET}"
}

error(){
    echo
    echo -e "${RED}$1${RESET}"
}

prompt_text(){
    printf "%b" "${YELLOW}$1${RESET}"
}

confirm_action(){
    local message="$1"
    local answer

    read -r -p "$(prompt_text "${message} [y/N]: ")" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

label(){
    echo -e "${CYAN}$1${RESET}"
}

value(){
    echo -e "${GREEN} $1${RESET}"
}

path_value(){
    echo -e "${YELLOW} $1${RESET}"
}

kv(){
    local key="$1"
    local val="$2"

    echo -e "${CYAN} ${key}${RESET} ${GREEN}${val}${RESET}"
}

path_kv(){
    local key="$1"
    local val="$2"

    echo -e "${CYAN} ${key}${RESET} ${YELLOW}${val}${RESET}"
}

menu_item(){
    local num="$1"
    local text="$2"

    echo -e "${CYAN}${num}.${RESET} ${GREEN}${text}${RESET}"
}

menu_action(){
    local text="$1"

    echo -e "${CYAN}${text}${RESET}"
}

divider(){
    local color="${1:-$CYAN}"
    local char="${2:-=}"
    local width="${3:-42}"
    local line

    line=$(printf "%${width}s" "")
    line="${line// /$char}"
    echo -e "${color}${line}${RESET}"
}

section(){
    local text="$1"
    local color="${2:-$CYAN}"

    echo -e "${color}================= ${text} =================${RESET}"
}

banner(){
    local color="${2:-$CYAN}"

    echo
    divider "$color"
    echo -e "${color}$1${RESET}"
    divider "$color"
    echo
}
