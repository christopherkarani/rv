# Known limits

What rv does not do, stated plainly so you can decide where to rely on
it. Each limit links to where it is explained in more depth.

How this was checked: each item was confirmed in the source or its tests
on this branch. The macOS items come from the source and recorded
measurements; they were not run for these guides.

## Releases and platforms

- **No signed release yet.** The newest release, v0.2.2, is unsigned. The installer checks
  downloads against `SHA256SUMS` but does not yet check `SHA256SUMS`
  against a release key, and on macOS an unsigned binary only warns. See
  [Install](install.md#release-status-read-this-first).
- **Linux needs glibc 2.35 or later** (Ubuntu 22.04+, Debian 12+, Fedora
  36+, RHEL 10+). musl (Alpine) is not supported. macOS needs 15 or later
  on Apple Silicon.
- **Caged MCP servers on Linux need kernel 6.7 or later with Landlock**
  (ABI 4) and seccomp filters. On older kernels a server that asks for a
  sandbox is refused and one that does not runs uncaged. The Linux cage
  has been tested on x86-64 only.
- **The Linux custodian needs systemd and PAM,** must be installed from a
  root-owned copy of rv, and accounts with no password, fingerprint-only
  login, or a PAM factor kept in the home directory cannot approve. Its
  own limits (a password typed where the agent can watch, a prompt the
  agent starts) are in
  [docs/security/mcp-linux-custodian.md](../security/mcp-linux-custodian.md#known-limits).
- **Placeholders for MCP servers are macOS only.** On Linux a server with
  `"placeholders"` is refused.
- **Contained workspaces, micro-VMs and the on-device judge are macOS
  only.** Linux runs packs only.

## The secrets gateway

- **macOS can send a `GET` or `HEAD` up to three times.** When the
  upstream drops the connection before answering, macOS's URLSession
  retries a `GET` or `HEAD`, credential included, up to three times in
  all; it has no setting to stop this. `POST`, `PUT`, `PATCH`, `DELETE`
  and `OPTIONS` are sent once. On Linux every request is sent once. Do
  not put a credential behind the gateway for an API where a repeated
  `GET` has an effect.
- **Linux cuts off answers over 64 MiB from a fast upstream.** On Linux at
  most 64 MiB of one answer can wait for the client. An answer larger
  than that, from an upstream faster than the gateway forwards it, is cut
  off without the chunked terminator, so the client sees it as
  incomplete. On loopback a 256 MiB answer was cut after 32 MiB.
- **`rv run` is not a sandbox.** The command runs as you and can read
  anything you can, including where the real values are stored.
- **An MCP server's cage does not stop it asking your keychain or a
  provider for a value itself.**
- **`approve` rules are refused outside a workspace.** There is no
  approver for `rv run` or an MCP server, so requests an `approve` rule
  matches are refused under `rv run`, and an MCP placeholder server with
  such a secret is refused.
- **`secrets.json` is not signed.** The `mcp.json` signature does not
  cover it, so a later change to a secret's upstream changes what an MCP
  server's placeholder is spent on without a new review. Serve writes the
  binding to stderr each time a placeholder server starts.

See [Secrets placeholders](secrets-placeholders.md#what-is-protected-and-what-is-not).

## The MCP gateway

- **Restarts: at most five in any ten minutes.** After that the server
  stays failed until the MCP client restarts `rv mcp serve`. The window
  slides, so a server that fails every two minutes or so is restarted
  indefinitely, its secrets resolved again each time.
- **Each remote server gets at most 64 calls and about 160 requests
  in flight** (a retry or a legacy stream's first messages can pass the
  160 briefly). Past either, rv does not send the request; nothing in
  flight is touched. An approved call that is not sent spends its approval. The
  limits are per remote server, not per serve process: on Linux, where
  each request is a connection, several saturated remotes add up and can
  still run rv out of file descriptors.
- **One slow server holds back every tool** until it starts or its
  `startTimeoutSeconds` runs out.
- **A timed-out call may still run.** rv asks the server to cancel and
  stops waiting; it cannot make the server stop.
- **A server that handles one request at a time is restarted after a
  call times out,** because it cannot answer rv's ping while busy.
- **Signals do not reach what a server started outside its process
  group** (`setsid`, a `docker run` container).
- **A running serve keeps the pins it started with.** After `rv mcp
  trust`, restart the MCP host.
- **Approval in the client's own prompt needs no custodian.** Whoever
  controls the MCP host can answer rv's in-client prompt. With an agent
  that controls its host, only `deny`, and calls held for
  `rv mcp approve`, are protected by the custodian.
- **On Linux, OAuth tokens from `rv mcp connect` are a file** in
  `~/.config/rv/mcp-oauth/` (mode 0600), readable by anything running as
  you.
- **Some fields of a pinned tool are forwarded as the server sent them**
  (vendor schema keywords, `enum` and `default` values, `icons`,
  `_meta`), and `rv mcp trust` does not cap how long a field it shows may
  be. Tool result text is forwarded byte for byte; rendering it safely is
  the MCP host's job.
- **Messages whose JSON keys differ only by Unicode normalization** are
  treated as having duplicate keys and dropped.
- **`mcp.tool.changed` and `mcp.hosts.ungoverned` have no OCSF mapping
  yet.**

## The guard that keeps agents from adding MCP servers around rv

While the gateway is in use, the hook guard refuses an agent's writes to
host MCP configs and host CLIs that add servers (`claude mcp add` and
the like). It reads command text, so it is not a boundary:

- **22 spellings are known gaps, recorded as expected failures in the
  test suite** (`Tests/RVEngineTests/MCPHostSpellingTests.swift`): 20 are
  `mcp install` with the `mcp` word given as a variable or command
  substitution (`chronic $M install srv`), bare and behind four wrappers;
  asking there would fire on every `$PM install`. The other two are a
  glob class closed only by a brace alternative, and a nameref whose
  target is built from an expansion.
- **Not guarded:** a nested agent started with servers rv does not govern
  (`claude --mcp-config …`, `claude --plugin-dir …`, `codex -c
  mcp_servers…`); a program that writes a config without its command line
  visible as text (a script or scheduled job written earlier, a shell fed
  an expansion, text decoded by `base64 -d`, `rev`, `tr` or a `printf`
  format, output joined across commands, a git hook or pager set up
  earlier); a glob the filesystem expands into a host and its group word;
  a config file name written through a brace or glob spelling.
- **It also asks for some harmless commands**, such as a `cat` of a path
  with an escaped space under `~/Library/Application Support`.

### Every case

While the gateway is in use, the hook guard also keeps an agent from
adding servers around it: writes to a host's own MCP config
(`~/.claude.json`, `.mcp.json`, Cursor, Codex, Gemini, Claude Code
plugins, ...) and host CLIs that add servers (`claude mcp add`, `npx
@anthropic-ai/claude-code mcp add`, `mcp install`, `@smithery/cli`) ask
or deny as `core.mcp:mcp-host-config`. Where a word may run (the
program, any word after a runner, or an operand of a program not known
to leave its operands alone), a brace or glob spelling of a host
program, its group word or `mcp install` is resolved by every word it
can produce, as bash expands comma groups and `{x..y}` ranges, into
several words where bash splits them, a blank inside an alternative
included (`claude m{c,}p add`, `clau?e mcp add`, `chronic m[c]p
install`, `chronic mc{o..p} install`, `{claude,mcp} add`, `claude
{mcp,add,srv,"x y"}`, `mcp {,} install`). The filesystem is not
consulted, so a wildcard or class is assumed satisfiable; a POSIX class
matches any one character, and a bracket range is judged as any range
its case-folded text may have been (`cl[M-c]ude` and `cl[!A-Z]ude` may
be `claude`). A word with a blank outside every brace is only itself,
and a word past the spelling budget (over 256 characters, unless it
holds no brace and its shortest match is longer than any host word,
such as a presigned URL; over 64 brace words; or 1,000,000 matching
steps per command) may be any words. `ls`, `cp`, `mv`, `rm`, `mkdir`,
`touch`, `cat` and `git add|status|diff|rm`, run by their plain names
(no path, no git option first; behind `sudo`, `env`, `nice`,
`timeout`, `command`, `exec`, `nohup`, `time`, `doas` or `busybox`
too, but not `stdbuf`, `xargs` or `watch`), never run an operand, so
only their operands' literal words and carried text count (`ls mcp *`,
`cp -r packages/mcp "$DEST"`, `touch {a..z}{0..9}` allow; `ls mcp
install` and `stdbuf -o0 ls mcp $DIR` ask), unless the line, or the
carried text being read, may define or redefine a command (a function,
alias or hash entry; `PATH`, zsh's `path`, `FPATH`/`fpath`,
`module_path`, `BASH_ENV`, `ENV` or `ZDOTDIR` named as written anywhere
but where it is only read, such as `$PATH`, `${PATH%%:*}`, `${PATH:-…}`,
`find -path` or `~/path/x`, once line continuations, a `$` opening a
quote, and quotes are removed (`export $'PATH'=…` and zsh's
`${PATH::=…}` count); a name built from escapes or expansions is not
recognised, so instead any operand of an assigning builtin, or
`printf -v` name, whose name before `=` or `[` holds `$` or a backtick
counts (`export P$'\x41'TH=…`, `export ${N}TH=…`; `export FOO=$BAR`
does not); `env -P` or `-S`, or `--split-string` or an abbreviation such
as `--split`; a function flag such as `typeset -fu`; `source`/`.`, `eval`,
`trap`, `autoload` or a dynamic program: `ls() { "$@"; }; ls mcp $X`,
`: "${PATH:=./bin}"; ls mcp $X` and `echo 'alias ls=eval; ls mcp $X' |
sh` ask, as does a printer's text read beside output rv cannot read,
`{ cat ./defs.sh; echo 'ls mcp $X'; } | sh`). A segment rv's splitter cannot scan
(a head still `{` or `(` that does not peel, such as `{claude,zzqx} mcp
add`) asks when its line may name a host CLI; so do odd heads that only
look like a group, such as `{claude}mcp` or `{claude,codex}-helper
--version`.
Carried text is read when it holds a host stem (also one broken only by
`[…]` extras a package spec drops, `install-m[x]cp`) or such a word
(`watch 'chronic m?p install srv'`). The text is split at blanks and
`;|&()<>`; where a brace or class span holds one of those, each run of
pieces the span joins is spelled as one more word (`watch "'cl[;a]ude'
'm[;c]p' add s -- x"`). Text where two such runs cross (share a piece
without one holding the other, `'{c?aude,x y}{,a b}'`), whose joined
words pass four times its length, or whose brace word expands past 64
words counts as naming a host. The 64-word rule has one exception: an
integer range in a word with no glob character is judged as one word,
since only its digits differ (`touch f{1..100}`). These are guesses at the shell's words once
quotes are gone, and classes are closed on the text as written, before
braces expand. Where nothing runs the word (a `grep` or
`rg` operand, a commit message) and in text such a command carries,
only literal words count (`grep -rn claude * | head` allows). A
variable or substitution rv cannot read (`$c`, `"$SUB"`, `${x}`,
`$(…)`, and ANSI-C `$'…'`, which rv cannot tell from a variable there),
used as the program at any position after a runner it does not strip
and followed anywhere by a group word (`stdbuf -o0 $c mcp add`, and so
`node "$ENTRY" mcp list`; also a `find` start path or option value and
an `xargs` or `watch` option value, since rv cannot tell `"$N"` from an
unquoted `$N` that splits into a program: `find . -maxdepth "$DEPTH"
-name config` and `xargs -P "$N" grep -l config` ask), or in a
completing position of a `claude`, `codex`, `gemini`, `opencode` or
`cursor-agent` mutation, counts as that word; so does one in the
subcommand position after a literal `mcp` or `fastmcp` where it may run
(`chronic mcp "$SUB" srv`, `chronic mcp $(…) srv`). `$IFS` or
`${IFS}`, in any quoting, on a line that runs something and may name a
host CLI asks as text rv's tokenizer cannot follow (`claude${IFS}mcp
add`, `sh -c 'claude${IFS}mcp add'`). *Known limits:* a nested agent
started with servers rv does not govern (`claude --mcp-config …`,
`claude --plugin-dir …`, `codex -c mcp_servers…`), and a program that
writes a config without its name on the command line (a script or a
scheduled job written to disk earlier, by the shell or the file tool;
a shell fed an expansion; text decoded or rendered by a program such
as `base64 -d`, `rev`, `tr` or a `printf` format (`'cla%sude …' u`);
output joined across commands other than `echo`/`printf`/`print`, such
as two `cat <<<…`; a tarball, directory or URL whose name the agent
chooses; Claude Code's native build reached through the working
directory, a variable or a renamed copy (`cd …/claude/versions &&
./2.0.14 …`, `$D/versions/…`); or a git hook — which `git commit -m`
still runs — diff/pager tool or `.ackrc`/lesskey file set up earlier).
Also not caught: a value rv cannot read standing for the `mcp` host
word of the `mcp install` installer, in any position and after any
runner (`chronic $M install srv`, `stdbuf $M install srv`; asking there
would fire on every `$PM install`); a glob the filesystem expands into
several words that supply both a host and its group (`* add x` in a
directory holding only `claude` and `mcp`); a brace, glob or dynamic
spelling of a stem inside opaque text never re-parsed as a shell command line
(`python3 -c "os.system('claude m{c,}p add')"`); a config file name
written through a brace or glob spelling (`echo {} > .{mcp,x}.json`);
in carried text, a class only a brace alternative closes
(`watch "'cl[{],x};a]ude' 'm[{],x};c]p' add s -- x"`); and a lookup
variable reached through a nameref whose target is an expansion
(`N=PA; declare -n R=${N}TH; R=./bin; ls mcp $X`).
Text that names a host mutation asks even as data (`git commit -m 'run
claude mcp add x'`, `grep 'claude mcp add' docs/`, `grep claude "$f"`),
as do dynamic programs given `config` (`"$GIT" config user.name`) and
carried text that may name a host CLI or installer and runs past the
guard's read budget. `mcp install` asks wherever a program may run it,
whatever the server (`op run -- mcp install srv`, `mcp -- install srv`,
`watch '…'`, `ssh host '…'`, `echo '…' | sh`), so the two words as any
other program's operands ask too (`ls mcp install`). It is left alone
as the value of a tool's own directory, workspace or filter option
(`make -C|--directory`, `npm -C|--prefix|-w|--workspace`, `pnpm
-C|--dir|--filter`, `bun --cwd|-F|--filter`: `make -C mcp install`;
`pnpm -w mcp install` and `yarn --cwd mcp install` ask) and as text on a
line that runs nothing: one `grep`, `rg` (no `--pre` or
`--hostname-bin`), `echo`, `printf`, `git commit|tag` or `gh pr|issue
create|comment|edit`, written with no
backslash in its program or subcommand, and no pipe, list, redirect,
substitution or parenthesis anywhere (`git commit -m 'add mcp install
docs'`; after `cd x &&` it asks). Text that may name a host CLI and
that rv's shell tokenizer cannot follow asks on any other line: a
backslash before a quote or blank (`watch "sh -c \"claude mcp add
x\""`, `'\''`, `claude\ mcp`), `\'` inside `$'…'`, and zsh `=(…)`; so
does such text with a glob that may be a host word, which any bare `*`
or `dir/*` word may be. This also asks for some harmless commands, such
as `cat ~/Library/Application\ Support/Claude/…`, any such line with a
bare wildcard (`ls ~/Library/Application\ Support/*`, `grep -rn
"\"version\"" * | head`), `jq ".a[\"x\"]" config.json` or a commit
message with `\"` after `cd x &&`; and for a brace word over 256
characters where it may run, such as a long JSON body given to `curl
-d`. zsh `=claude` counts as `claude`.

## The hook guard

- **Search tools:** a search with no explicit path (Claude `Grep`/`Glob`,
  Cursor `Grep`) scans the working directory and can match inside
  non-ignored secret files there; rv does not read file contents.
- **Observe mode's protection of `rvd` is lexical.** It raises the bar on
  stopping or replacing `rvd` but does not catch `kill` by a numeric pid,
  interpreter or script forms, or a renamed `launchctl`. A command whose
  program rv cannot see is sent to Terminal on an observe host
  (`observe.floor:unanalyzable`), never hard-denied (a command the
  engine already denies keeps that deny, except a deny observe only
  watches, `out-of-repo-write`, `unresolved-path` or `unwrap-limited`,
  which becomes `observe.floor:unanalyzable` too):
  - a dynamic command word (`$x`, `$(…)`, backticks), a dynamic `eval`,
    or a dynamic `trap` action (`trap "$X" EXIT`);
  - a shell (`sh`, `bash`, `zsh`, `dash`, `ksh`, `mksh`, `ash`, `yash`,
    `fish`, `csh`, `tcsh`, `nu`, `xonsh`) or interpreter that reads its
    program from stdin, unless what it reads is a literal here-string, a
    literal heredoc, or the output of commands that are all a literal
    `echo`, a `printf` with no `%` or escape other than `\n`, a `cat` of
    literal paths or of a literal heredoc, or a silent builtin (`cd`,
    `test`, `export`, …). So `… | sed 's/^/launchctl /' | sh`,
    `python3 -c "print(…)" | sh`, `… | base64 -d | sh` and
    `printf '\x6c…' | sh` go to Terminal whatever the producer is. A
    literal feed is read, not trusted: its text is scanned like the line
    and read by every observe floor rule (`echo 'echo … | base64 -d |
    sh' | sh` goes to Terminal, and so does an rv admin command, a
    `secret-tool` call or an rvd stop fed to a shell). A scheduler that
    reads its job from stdin (`at`, `batch`, `crontab` with no job file)
    is a reader too: `… | base64 -d | at now` goes to Terminal, and a
    literal job is read like a shell's (a crontab's commands without
    their schedule fields, `%` read as a newline), so `echo 'rv host mode
    cursor off' | at now` and `echo '* * * * * rv …' | crontab -` do as
    well. A crontab line rv cannot split into a schedule and a command,
    a crontab that sets `SHELL`, and `crontab -e` (its editor reads
    stdin) go to Terminal. A job file (`at -f job.sh`, `crontab
    jobs.txt`) is not read, like `sh job.sh`. rv does not model how a
    shell combines redirects (zsh joins several inputs; bash 3.2 and dash
    read `{fd}<` as fd 0): a reader's stdin is read only when it has one
    source, a pipe or a single literal here-string, heredoc or file on
    fd 0, and no other input redirect. A second source, a numbered,
    named or duplicated input redirect (`3<…`, `{fd}<…`, `0>&3`, `<&3`),
    or a script operand naming a descriptor (`/dev/stdin`, `/dev/fd/3`,
    `/proc/self/fd/3`, in any case, or a glob or brace pattern that may
    expand to one) makes it unreadable, so the reader goes to
    Terminal. A script operand's stdin is read too when the reader
    redirects it. In a pipeline the producers are the
    stages before the reader; inside a compound command (`if`, `for`,
    `while`, `case`), a `{ …; }`/`( … )` group or a function body they
    are every other command of the text, each of which must print whole
    lines (no `echo -n`, no backslash). Wrappers are seen through on both
    sides (`command`, `builtin`, `env`, `sudo`, `exec`, `nohup`, `time`,
    `nice`, `timeout`, `stdbuf`, `caffeinate`, `arch`, `xcrun`, `X=1`),
    and command names are matched unescaped, case-folded and by basename
    (`\sh`, `Bash`, `/BIN/SH`). The line is split the way the shell
    splits it: quotes (`$'\''` included), heredoc bodies (an apostrophe in
    one does not hide the lines after it), continuations, groups and
    `$((…))`;
  - a shell or interpreter running `<(…)` or zsh's `=(…)`, a dynamic
    here-string or heredoc, `source /dev/stdin` or a dynamic script
    operand (`bash "$SCRIPT"`);
  - a shell on a line that names `BASH_ENV` or `ENV` (a startup file
    the shell reads first), or that sets a variable whose name is
    dynamic (`export "$(cat vars)"`) or declares a nameref whose target
    is not a literal name (`declare -n r="$v"`, `declare -n r`);
  - a same-line definition that changes what a name runs: a function or
    alias named like a command the floor reads (`echo(){ …; }`, `alias
    cat=…`), a function whose body is not a group, `coproc`, `>&p`, and
    `hash -p`; any other function or alias used as a stdin reader is
    floored like a shell;
  - text the shells may split differently than rv does (an unbalanced
    group, a `}` in argument position, which zsh closes on and bash does
    not), and a command too large to walk within budget (over 4096
    commands, or fed texts too large to read: every reader of a text
    is charged for it, so thousands of readers of one big heredoc run
    out of budget);
  - dynamic or encoded inline code (`osascript -e "$(…)"`,
    `python3 -c "…os.system(base64.b64decode(…))"`), and inline code
    that runs a command over input rv cannot read: stdin from a
    producer rv cannot read, `perl -n`/`-p`, a dynamic argument or
    assignment (`perl -e 'system @ARGV' "$X"`), or code that reads
    stdin, arguments, the environment, a file or the network;
  - `awk` whose program runs a command (`system`, a `|` to or from a
    command), and GNU `sed` with the `e` command or `s///e` flag,
    whatever feeds them;
  - `ssh` whose remote command has a dynamic word (`ssh localhost
    "$X"`; the remote shell re-parses it), or a dynamic or unreadable
    `ProxyCommand`, `LocalCommand`, `KnownHostsCommand` or
    `RemoteCommand`;
  - `xargs`, `find -exec` or `parallel` running a shell, an interpreter,
    `awk`, `sed`, `ssh`, a dynamic verb, or `kill`, `pkill`, `killall`,
    `launchctl`, `systemctl`, `rv` or `rvd` (their operands come from
    input), and `parallel` with no verb.

  What the lexical floors read is the command line itself: the words of
  each command (which the observe floors, not enforce, also re-read with
  heredoc bodies removed and one command at a time),
  the inline `-c` script of a shell, the text a shell or
  interpreter is fed from a literal pipe, here-string or heredoc, and the
  string literals of inline interpreter code. They do not read files. So
  a literal verb with dynamic arguments (`xargs rm`), an inner script
  whose commands are all literal (`bash -c 'for f in *; do echo $f;
  done'`) and a literal script file stay observed, and the file's
  contents are not checked: `bash x.sh`, `sh < x.sh` and `cat x.sh | sh`
  run whatever `x.sh` holds. An agent that writes a decoded script to a
  file and then runs it (`echo … | base64 -d > /tmp/x.sh && sh
  /tmp/x.sh`), or a build step that stops `rvd`, is not modelled.
- **Where observe's command reading differs from the shell.** These
  observe-floor gaps let a program through that rv reads differently
  than the shell runs it (0.2.2 allowed them all):
  - a heredoc body is attached to the last command of its line, not to
    the command that holds the `<<`;
  - with several stdin redirects on one command, rv reads the first,
    where the shell uses the last;
  - `$$'…'` and `\$'…'` are read as ANSI-C quoting, which they are not;
  - wrappers rv does not see through: `ionice`, `chrt`, `taskset`,
    `flock`, `unbuffer`, `numactl`, `prlimit`, `chpst`, `busybox sh`,
    `su -c`, `sudo --user root sh`, `bash --rcfile`;
  - zsh's short `for x (a) …` loop;
  - and, the other way round, `$(( … ))` arithmetic is sometimes read as
    a command (a false positive).

  The floors are lexical and will always have gaps like these. The
  structural fix is for the hook's fallback to fail closed after a
  deliberate `rvd` stop instead of stepping aside.
- **Interpreter forms observe does not read.** Inline code whose
  command is built from literal pieces (`python3 -c
  "import os; os.system('launch'+'ctl …')"`, the same code piped in by a
  literal `echo`, or in a heredoc) passes when it reads no input rv
  cannot see; the floor reads code for a few markers, not its meaning.
  Also not read: a script file an interpreter runs (`python3 x.py`,
  `awk -f x.awk`, `sed -f x.sed`), an `ssh -F` config file's
  `ProxyCommand`, an environment variable set by an earlier call, and
  an interpreter not on the list (`python*`, `pypy*`, `node`, `bun`,
  `deno`, `ruby`, `perl`, `php`, `lua`, `luajit`, `osascript`,
  `Rscript`, `tclsh`, `pwsh`).
  Once `rvd` is absent, an observe host lets calls run unchecked, rv's
  config and wiring included. Running `rvd` in the system domain, where a
  process running as you cannot stop it, is future work; use enforce
  where that matters.
- **Observe sends some everyday commands to Terminal.** The floor above
  cannot tell a tool's generated setup code from an attacker's, so
  `eval "$(tool …)"` always goes to Terminal, and so does any other
  `eval` of a command's output:
  - shell setup: `eval "$(brew shellenv)"`,
    `eval "$(/opt/homebrew/bin/brew shellenv)"`;
  - version managers and environment loaders: `eval "$(pyenv init -)"`,
    `eval "$(rbenv init -)"`, `eval "$(fnm env)"`,
    `eval "$(mise activate bash)"`, `eval "$(direnv hook zsh)"`,
    `eval "$(direnv export bash)"`;
  - prompts and shell integrations: `eval "$(starship init zsh)"`,
    `eval "$(zoxide init zsh)"`, `eval "$(fzf --zsh)"`;
  - completions: `eval "$(gh completion -s zsh)"`,
    `eval "$(kubectl completion zsh)"`, `eval "$(cargo completions zsh)"`,
    `eval "$(pip completion --zsh)"`;
  - agents and credentials: `eval "$(ssh-agent -s)"`, `eval $(ssh-agent)`,
    `eval "$(op signin)"`,
    `eval "$(aws configure export-credentials --format env)"`.

  Run those in Terminal or put them in your shell's startup file. A
  `find -exec` or `xargs` that runs a shell (`find . -exec sh -c 'echo
  {}' \;`) goes to Terminal too, as do `pgrep node | xargs kill`, `ssh
  host 'echo $HOME'` (rv cannot tell single from double quotes there),
  `curl … | sh` installers, `cat <<EOF | sh` whose body expands (`$`,
  backticks), and `awk` programs that call `system` or pipe to a command.
  A shell or interpreter reading stdin inside a compound command, group
  or function body goes to Terminal when any other command there is not
  a literal producer (`(npm ci && cat x | sh)`), as does a line that
  defines a function named like a command rv reads (`cd() { …; }`) or
  has a `}` argument inside a group. rv also cannot see what a git alias or
  extension runs, so observe sends an unknown git subcommand (`git st`,
  `git lg`) to Terminal even when `core.git` is off. Every string
  literal of inline interpreter code is read as a command it may run,
  so code that only prints an rv admin command or names `secret-tool`
  goes to Terminal (`python3 -c 'print("rv host mode cursor off")'`,
  `python3 -c 'print("secret-tool")'`, `node -e 'console.log("rv
  allowlist add rm")'`), as one that prints an rvd stop already did.
  Editing a crontab through a pipe whose input rv cannot read
  (`(crontab -l; echo '0 3 * * * job') | crontab -`) goes to Terminal
  too, as do `crontab -e` and a literal crontab that sets `SHELL`.
  A reader with more than one input, or with any numbered, named or
  duplicated input redirect, goes to Terminal even when every input is
  harmless (`sh 3</dev/null < script.sh`, `echo ls | sh </dev/null`,
  `sh <<< ls <<< pwd`), as does a script operand that names a descriptor
  (`sh /dev/stdin <<< ls`, `awk -f -`), and a here-string handed to a
  script (`python3 parse.py <<< 'rv …'`) is read like a program. A
  script operand, `-f` file or input redirect whose name holds glob or
  brace characters (`*`, `?`, `[`, `{`, `(`, `^`, `#`, a later `~`) goes to
  Terminal even when it names a plain file, quoted or not (`sh
  'build[1].sh'`), and so does a shell on a line that mentions `BASH_ENV`
  or `ENV` for any reason (`ENV=prod bash deploy.sh`).
- **On an observe host, reading rv's install is observed.** A command
  that names one of rv's hook, service or binary files and is proven to
  only read (`ls`, `stat`, `cat`, `head`, `tail`, `wc`, `codesign` display
  or verify, `log show`, written plainly) runs and is recorded like any
  other observed command. Anything else that names one, including a read
  through another program, quoting or a redirect, is enforced. rv's
  config directory is enforced on every command that names it.
- **Plain allows are not logged** in the audit log, only denies,
  overrides and changes.

## The audit log

- **The chain is unkeyed.** A process running as you can rewrite the
  file and recompute every hash, or cut off the tail. Compare the
  forwarded `rv_chain_head` off the machine to catch that.
- **An older CLI** that meets rvd's "audit log unwritable" answer says
  rvd is not reachable and points at `rv doctor` instead of the audit
  log.

## Anything running as you

rv's config directory is yours to write. rv's hook guard refuses an
agent's attempts to edit it, but a process running as you outside any
agent can still edit or delete `~/.config/rv`. rv flags an edited
`mcp.json` and refuses to use it, and the custodian refuses a rolled-back
one, but it cannot stop the edit.
