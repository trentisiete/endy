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
              watch web spawn ask chat handoff help \
              codex opencode cmd commandcode hermes claude gemini"

  # Enumerate task ids from every endy install we can locate. Earlier
  # versions hardcoded $HOME/Downloads/endy/.logs, which did not match the
  # npm-installed layout (<install>/.logs/per-dir/<session>/task-*.meta)
  # and broke id completion entirely. This helper walks the endy binary
  # back to its install root and then globs every per-dir/* under it.
  _endy_collect_task_ids() {
    local roots=() endy_bin endy_real endy_root r
    endy_bin="$(command -v endy 2>/dev/null)"
    if [[ -n "$endy_bin" ]]; then
      endy_real="$(readlink -f "$endy_bin" 2>/dev/null || printf '%s\n' "$endy_bin")"
      endy_root="$(dirname "$(dirname "$endy_real")")"
      [[ -d "$endy_root/.logs" ]] && roots+=("$endy_root/.logs")
    fi
    [[ -n "${ENDY_LOGS_DIR:-}" && -d "$ENDY_LOGS_DIR" ]] && roots+=("$ENDY_LOGS_DIR")
    [[ -d "$HOME/Downloads/endy/.logs" ]] && roots+=("$HOME/Downloads/endy/.logs")
    local out=""
    for r in "${roots[@]}"; do
      out+="$(find "$r" -maxdepth 3 -name 'task-*.meta' 2>/dev/null \
              | sed -E 's|.*/task-([0-9]+-[0-9]+-[0-9a-f]+)\.meta|\1|') "
    done
    printf '%s' "$out"
  }

  local agents="codex opencode cmd hermes claude gemini"
  # spawn / chat / handoff also accept the offline `bash` stub for smoke
  # tests of the runtime without burning real-agent credits.
  local spawn_agents="codex opencode cmd hermes claude gemini bash"
  local watch_subs="list tree dir log chat attach panel browse follow view peek handoffs clean-abandoned clean followup kill kill-all gc purge delete purge-session"
  local help_topics="opencode cmd hermes claude gemini tmux"
  local web_opts="--localhost --host --port --token"
  local spawn_opts="--full-auto --supervised --persona --model --cwd --max-turns --orchestrator --orchestrator-agent --parent-task --resume --skills --"
  local chat_opts="--persona --model --cwd --resume --parent-task --orchestrator --orchestrator-agent --full-auto --no-select"
  local handoff_opts="--to --reason --instructions --lines --no-attach --stop-parent"

  # First positional: the subcommand.
  if [[ "$cword" -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$subs" -- "$cur") )
    return 0
  fi

  local sub="${words[1]}"
  case "$sub" in
    spawn|ask|chat)
      if [[ "$cword" -eq 2 ]]; then
        # ask is one-shot blocking, the offline `bash` stub has nothing to
        # answer there. spawn/chat use it for runtime smoke tests.
        if [[ "$sub" == "ask" ]]; then
          COMPREPLY=( $(compgen -W "$agents" -- "$cur") )
        else
          COMPREPLY=( $(compgen -W "$spawn_agents" -- "$cur") )
        fi
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
    handoff)
      # First positional after `handoff` is a task id prefix.
      case "$prev" in
        --to)            COMPREPLY=( $(compgen -W "$agents" -- "$cur") ); return 0 ;;
        --reason|--instructions|--lines) COMPREPLY=(); return 0 ;;
      esac
      if [[ "$cword" -eq 2 ]]; then
        local ids; ids="$(_endy_collect_task_ids)"
        COMPREPLY=( $(compgen -W "$ids" -- "$cur") )
        return 0
      fi
      COMPREPLY=( $(compgen -W "$handoff_opts" -- "$cur") )
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
        log|view|peek|follow|chat|attach|kill|followup|purge|delete|purge-session)
          local ids; ids="$(_endy_collect_task_ids)"
          COMPREPLY=( $(compgen -W "$ids" -- "$cur") )
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
