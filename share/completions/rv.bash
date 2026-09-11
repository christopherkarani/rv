_rv() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local cmd="${COMP_WORDS[1]}"
  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "test explain packs policy scan allow-once allowlist service hook setup uninstall doctor" -- "$cur") )
    return
  fi
  case "$cmd" in
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
      COMPREPLY=( $(compgen -W "show draft validate export apply" -- "$cur") )
      ;;
    scan)
      COMPREPLY=( $(compgen -W "sessions" -- "$cur") )
      ;;
  esac
}
complete -F _rv rv
