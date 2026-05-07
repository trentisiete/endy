#!/usr/bin/env bash
# endy shell completion (bash + zsh).
#
# Bash:
#   source /path/to/endy/scripts/endy-completion.sh
#
# Zsh:
#   autoload -Uz compinit bashcompinit
#   compinit
#   bashcompinit
#   source /path/to/endy/scripts/endy-completion.sh
#
# `endy install` will offer to wire this into your shell rc on first run.

_endy_complete() {
  local cur prev words cword
  if declare -F _get_comp_words_by_ref >/dev/null 2>&1; then
    _get_comp_words_by_ref -n : cur prev words cword
  else
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]:-}"
    words=("${COMP_WORDS[@]}")
    cword="$COMP_CWORD"
  fi

  local subs="install start stop status doctor orchestrator tmux-help \
              watch web spawn ask chat help \
              codex opencode cmd commandcode hermes claude"

  local agents="codex opencode cmd hermes claude"
  local watch_subs="list tree dir log chat attach panel browse follow view followup kill kill-all gc purge delete purge-session"
  local help_topics="opencode cmd hermes claude tmux"
  local web_opts="--localhost --host --port --token"
  local spawn_opts="--full-auto --supervised --persona --model --cwd --max-turns --orchestrator --orchestrator-agent --parent-task --resume --skills --"
  local chat_opts="--persona --model --cwd --resume --parent-task --orchestrator --orchestrator-agent --full-auto --no-select"

  # First positional: the subcommand.
  if [[ "$cword" -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$subs" -- "$cur") )
    return 0
  fi

  local sub="${words[1]}"
  case "$sub" in
    spawn|ask|chat)
      if [[ "$cword" -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "$agents" -- "$cur") )
        return 0
      fi
      case "$prev" in
        --persona|--agent|--skills) COMPREPLY=(); return 0 ;;
        --model)                    COMPREPLY=(); return 0 ;;
        --cwd|--dir)                COMPREPLY=( $(compgen -d -- "$cur") ); return 0 ;;
      esac
      if [[ "$sub" == "spawn" ]]; then
        COMPREPLY=( $(compgen -W "$spawn_opts" -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "$chat_opts" -- "$cur") )
      fi
      return 0
      ;;
    watch)
      if [[ "$cword" -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "$watch_subs" -- "$cur") )
        return 0
      fi
      local watch_sub="${words[2]}"
      case "$watch_sub" in
        list|tree|browse)
          COMPREPLY=( $(compgen -W "--all --orch --cwd --agent" -- "$cur") )
          ;;
        dir)
          COMPREPLY=( $(compgen -d -- "$cur") )
          ;;
        log|view|follow|chat|attach|kill|followup|purge|delete|purge-session)
          # Task ID — list from .logs
          local ids
          local logs_dir="${ENDY_LOGS_DIR:-$HOME/Downloads/endy/.logs}"
          if [[ -d "$logs_dir" ]]; then
            ids="$(ls -1 "$logs_dir"/task-*.meta 2>/dev/null \
                   | sed -E 's|.*/task-([0-9]+-[0-9]+-[0-9a-f]+)\.meta|\1|')"
            COMPREPLY=( $(compgen -W "$ids" -- "$cur") )
          fi
          ;;
        kill-all)
          COMPREPLY=( $(compgen -W "--agent --cwd --orch --done --everything" -- "$cur") )
          ;;
      esac
      return 0
      ;;
    help)
      COMPREPLY=( $(compgen -W "$help_topics" -- "$cur") )
      return 0
      ;;
    web)
      case "$prev" in
        --host|--token) COMPREPLY=(); return 0 ;;
        --port)         COMPREPLY=(); return 0 ;;
      esac
      COMPREPLY=( $(compgen -W "$web_opts" -- "$cur") )
      return 0
      ;;
    orchestrator|orch)
      case "$prev" in
        --cwd|--dir) COMPREPLY=( $(compgen -d -- "$cur") ); return 0 ;;
        --agent)     COMPREPLY=( $(compgen -W "$agents" -- "$cur") ); return 0 ;;
      esac
      COMPREPLY=( $(compgen -W "--agent --cwd --no-attach" -- "$cur") )
      return 0
      ;;
    start)
      COMPREPLY=( $(compgen -W "--clean --no-attach --serve-opencode --logs" -- "$cur") )
      return 0
      ;;
    codex|opencode|cmd|commandcode|hermes|claude)
      COMPREPLY=( $(compgen -W "--root" -- "$cur") )
      return 0
      ;;
  esac

  COMPREPLY=()
  return 0
}

complete -F _endy_complete endy 2>/dev/null || true
