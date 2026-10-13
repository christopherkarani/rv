_rv() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local cmd="${COMP_WORDS[1]}"
  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "opencode workspace test explain packs policy scan allow-once allowlist service hook setup uninstall doctor safety blocks audit secrets mcp managed report operator egress" -- "$cur") )
    return
  fi
  case "$cmd" in
    workspace)
      COMPREPLY=( $(compgen -W "start attach status close" -- "$cur") )
      ;;
    allow-once)
      COMPREPLY=( $(compgen -W "mint list clear" -- "$cur") )
      ;;
    allowlist)
      COMPREPLY=( $(compgen -W "add add-command list remove validate" -- "$cur") )
      ;;
    packs)
      COMPREPLY=( $(compgen -W "enable disable info" -- "$cur") )
      ;;
    policy)
      COMPREPLY=( $(compgen -W "show list draft validate export apply" -- "$cur") )
      ;;
    scan)
      COMPREPLY=( $(compgen -W "sessions" -- "$cur") )
      ;;
    safety)
      COMPREPLY=( $(compgen -W "normal strict" -- "$cur") )
      ;;
    operator)
      COMPREPLY=( $(compgen -W "propose proposal-status" -- "$cur") )
      ;;
    egress)
      COMPREPLY=( $(compgen -W "pending show approve deny denials" -- "$cur") )
      ;;
  esac
}
complete -F _rv rv
