#compdef rv

_rv() {
  local -a commands
  commands=(
    'test:Evaluate a command'
    'explain:Explain a decision'
    'allow-once:Mint and redeem single-use unlock codes'
    'allowlist:Manage permanent user-layer exceptions'
    'service:Service status'
    'hook:Host hook child'
    'setup:Install hooks'
    'uninstall:Remove rv-owned files'
    'doctor:Read-only health'
  )
  _arguments '1: :->cmds' '*:: :->args'
  case $state in
    cmds) _describe -t commands 'rv command' commands ;;
    args)
      case $words[1] in
        allow-once)
          local -a ao
          ao=('mint:Mint a code' 'list:List rows' 'clear:Clear rows')
          _describe -t commands 'allow-once' ao
          ;;
        allowlist)
          local -a al
          al=('add:Add rule' 'add-command:Add exact command' 'list:List' 'remove:Remove' 'validate:Validate')
          _describe -t commands 'allowlist' al
          ;;
      esac
      ;;
  esac
}

compdef _rv rv
