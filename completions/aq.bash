# bash completion for aq
#
# Install:
#   . completions/aq.bash         # for the current shell
#   # or, per-user, persistent:
#   install -m 0644 completions/aq.bash ~/.local/share/bash-completion/completions/aq
#
# Homebrew users get this wired up automatically (the formula installs it
# into bash_completion.d).

_aq() {
  local cur prev cword
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  cword=$COMP_CWORD

  local base_dir="${HOME}/.local/share/aq"
  local cmds="new start stop console exec scp rm ls snapshot fanout help --version --help"
  local snap_subs="create ls rm tag tree"

  # Enumerate VM names from $BASE_DIR/<vm>/. Filter out reserved per-arch
  # and snapshot infra dirs.
  _aq_vms() {
    [ -d "$base_dir" ] || return
    local n
    for n in "$base_dir"/*/; do
      n="${n%/}"
      n="${n##*/}"
      case "$n" in
        aarch64|x86_64|snapshots|tags) continue ;;
      esac
      printf '%s\n' "$n"
    done
  }

  _aq_snapshot_tags() {
    local tags_dir="$base_dir/tags"
    [ -d "$tags_dir" ] || return
    local n
    for n in "$tags_dir"/*; do
      [ -e "$n" ] || continue
      n="${n##*/}"
      printf '%s\n' "$n"
    done
  }

  # First word after `aq`: subcommand or top-level flag.
  if [ "$cword" = 1 ]; then
    COMPREPLY=($(compgen -W "$cmds" -- "$cur"))
    return 0
  fi

  local sub="${COMP_WORDS[1]}"
  case "$sub" in
    start|stop|console|exec|rm)
      # Single positional: VM name.
      if [ "$cword" = 2 ]; then
        COMPREPLY=($(compgen -W "$(_aq_vms)" -- "$cur"))
      fi
      ;;
    scp)
      # scp completes on local files; for the "<vm>:" form, complete VM
      # names followed by a colon. Tricky to do reliably across bash
      # versions — fall back to filenames + VM-prefixed candidates.
      local vm_candidates=()
      local vm
      while IFS= read -r vm; do
        [ -n "$vm" ] && vm_candidates+=("${vm}:")
      done < <(_aq_vms)
      COMPREPLY=($(compgen -W "${vm_candidates[*]}" -- "$cur") $(compgen -f -- "$cur"))
      ;;
    new)
      # `aq new` accepts flags (-p, --from-snapshot, --count, --size,
      # --memory, --skip-fast-boot) then a VM name. Complete flag values
      # for --from-snapshot.
      case "$prev" in
        --from-snapshot|--from-snapshot=*)
          COMPREPLY=($(compgen -W "$(_aq_snapshot_tags)" -- "$cur"))
          return 0
          ;;
      esac
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "-p --from-snapshot --count --size --memory --skip-fast-boot" -- "$cur"))
      fi
      ;;
    snapshot)
      case "$cword" in
        2)
          COMPREPLY=($(compgen -W "$snap_subs" -- "$cur"))
          ;;
        3)
          # snapshot create <vm> <tag>   → VM name
          # snapshot rm    <tag>          → tag
          # snapshot tag   <tag> <newtag> → tag
          # snapshot tree  [<tag>]        → tag
          local snap_sub="${COMP_WORDS[2]}"
          case "$snap_sub" in
            create)
              COMPREPLY=($(compgen -W "$(_aq_vms)" -- "$cur"))
              ;;
            rm|tag|tree)
              COMPREPLY=($(compgen -W "$(_aq_snapshot_tags)" -- "$cur"))
              ;;
          esac
          ;;
      esac
      ;;
    fanout)
      # fanout <tag> <N> -- <cmd...>
      if [ "$cword" = 2 ]; then
        COMPREPLY=($(compgen -W "$(_aq_snapshot_tags)" -- "$cur"))
      fi
      ;;
  esac
}

complete -F _aq aq
