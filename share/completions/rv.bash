_rv() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local cmd="${COMP_WORDS[1]}"
  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "test explain allow-once allowlist service hook setup uninstall doctor" -- "$cur") )
    return
  fi
  case "$cmd" in
    allow-once)
      COMPREPLY=( $(compgen -W "mint list clear" -- "$cur") )
      ;;
    allowlist)
      COMPREPLY=( $(compgen -W "add add-command list remove validate" -- "$cur") )
      ;;
  esac
}
complete -F _rv rv
