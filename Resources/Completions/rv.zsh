#compdef rv

_rv() {
  local -a commands
  commands=(
    'test:Evaluate a command'
    'explain:Explain a decision'
    'packs:List and enable packs'
    'policy:Typed rules'
    'scan:Session forensics'
    'allow-once:Mint and redeem single-use unlock codes'
    'allowlist:Manage permanent user-layer exceptions'
    'service:Service status'
    'hook:Host hook child'
    'setup:Install hooks'
    'uninstall:Remove rv-owned files'
    'doctor:Read-only health'
    'safety:Show or set normal or strict'
    'blocks:List recent denials'
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
        packs)
          local -a pk
          pk=('enable:Enable a pack' 'disable:Disable a pack' 'info:Pack details')
          _describe -t commands 'packs' pk
          ;;
        policy)
          local -a po
          po=('show:List rules' 'draft:Compile English' 'validate:Validate' 'export:Export' 'apply:Apply')
          _describe -t commands 'policy' po
          ;;
        scan)
          local -a sc
          sc=('sessions:Scan host session stores')
          _describe -t commands 'scan' sc
          ;;
        safety)
          local -a sf
          sf=('normal:File-tool secrets plus shell evaluate' 'strict:Also deny ls / test / stat of a catalog path')
          _describe -t commands 'safety' sf
          ;;
      esac
      ;;
  esac
}

compdef _rv rv
