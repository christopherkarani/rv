_rv() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local cmd="${COMP_WORDS[1]}"
  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "run opencode workspace test explain packs policy scan allow-once allowlist service hook setup init uninstall doctor safety blocks host audit secrets login mcp managed report operator egress" -- "$cur") )
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
      if [[ $COMP_CWORD -eq 3 && "${COMP_WORDS[2]}" == ceiling ]]; then
        COMPREPLY=( $(compgen -W "show set" -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "show list draft validate export apply check ceiling rollback" -- "$cur") )
      fi
      ;;
    scan)
      COMPREPLY=( $(compgen -W "sessions" -- "$cur") )
      ;;
    safety)
      COMPREPLY=( $(compgen -W "normal strict" -- "$cur") )
      ;;
    host)
      COMPREPLY=( $(compgen -W "list mode" -- "$cur") )
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
