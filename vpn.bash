# bash completion for vpn (https://github.com/mmh/aws-vpn)
# shellcheck shell=bash
# source this file from ~/.bashrc

_vpn_complete() {
  local cur prev cmds slugs
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"
  cmds="all status disconnect down list ls logs prompt --help --version"
  slugs=$(timeout 1 aws-vpn-client list-profiles 2> /dev/null \
    | jq -r 'sort_by(.["imported-at"]) | .[]["profile-name"]' 2> /dev/null)

  if (( COMP_CWORD == 1 )); then
    mapfile -t COMPREPLY < <(compgen -W "$cmds $slugs" -- "$cur")
  elif [[ $prev == disconnect || $prev == down ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$slugs all" -- "$cur")
  elif [[ $prev == logs ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$slugs" -- "$cur")
  fi
}

complete -F _vpn_complete vpn
