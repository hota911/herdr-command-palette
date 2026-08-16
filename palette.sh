#!/usr/bin/env bash
# Action `hota911.command-palette.open` entrypoint: reads commands.json, lets the
# user pick a command via fzf, resolves its `arguments` into a plain argv array,
# and runs the herdr CLI. Runs inside the popup pane opened by open.sh, so a
# real TTY is available for fzf.
#
# The error-display pattern (print the message via die(), then wait for a
# keypress before exiting) is adapted from Jan Tvrdík's jt.command-palette
# (MIT), https://github.com/JanTvrdik/herdr-command-palette.
#
# Bash 3.2 compatible (macOS stock bash): no mapfile, no associative arrays,
# no `${var,,}`.
set -uo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"

# die prints an error, waits for a keypress so the popup doesn't vanish
# before the user can read it, then exits non-zero.
die() {
  printf '%s\n' "$1" >&2
  printf '\n(press any key to close)\n' >&2
  read -r -n 1 -s _ 2>/dev/null || true
  exit 1
}

# require_clean_fzf_rc RC — classifies fzf's exit status for the fzf calls
# that pick from a real candidate list (main picker, select, confirm; input
# has its own handling since --print-query makes "no match" a normal
# outcome there, not a cancel). 0 means the caller should proceed; 1 (no
# match) and 130 (interrupted, i.e. Esc/Ctrl-C) are clean cancels and exit
# the whole script with status 0; anything else (2: fzf usage/runtime
# error) is a genuine failure and must not be silently treated as a cancel.
require_clean_fzf_rc() {
  case "$1" in
    0) return 0 ;;
    1|130) exit 0 ;;
    *) die "command-palette: fzf exited with an unexpected status ($1)" ;;
  esac
}

# resolve_context maps a static context key to the ORIGIN_* value captured by open.sh.
# Prints the value and returns 0, or returns 1 for an unknown key.
resolve_context() {
  case "$1" in
    pane_id) printf '%s' "$ORIGIN_PANE_ID" ;;
    tab_id) printf '%s' "$ORIGIN_TAB_ID" ;;
    workspace_id) printf '%s' "$ORIGIN_WORKSPACE_ID" ;;
    cwd) printf '%s' "$ORIGIN_CWD" ;;
    *) return 1 ;;
  esac
}

# resolve_computed_context derives a neighboring resource ID from the ordered
# list returned by herdr and stores it in the global $value. It runs in the
# main shell so die() terminates the palette rather than a subshell.
resolve_computed_context() {
  computed_key="$1"

  case "$computed_key" in
    next_workspace_id)
      direction="next"
      list_desc="workspace list"
      collection="workspaces"
      id_field="workspace_id"
      origin_id="$ORIGIN_WORKSPACE_ID"
      raw=$("$herdr_bin" workspace list 2>&1)
      rc=$?
      ;;
    previous_workspace_id)
      direction="previous"
      list_desc="workspace list"
      collection="workspaces"
      id_field="workspace_id"
      origin_id="$ORIGIN_WORKSPACE_ID"
      raw=$("$herdr_bin" workspace list 2>&1)
      rc=$?
      ;;
    next_tab_id)
      direction="next"
      list_desc="tab list"
      collection="tabs"
      id_field="tab_id"
      origin_id="$ORIGIN_TAB_ID"
      raw=$("$herdr_bin" tab list --workspace "$ORIGIN_WORKSPACE_ID" 2>&1)
      rc=$?
      ;;
    previous_tab_id)
      direction="previous"
      list_desc="tab list"
      collection="tabs"
      id_field="tab_id"
      origin_id="$ORIGIN_TAB_ID"
      raw=$("$herdr_bin" tab list --workspace "$ORIGIN_WORKSPACE_ID" 2>&1)
      rc=$?
      ;;
    *)
      return 1
      ;;
  esac

  if [ "$rc" -ne 0 ]; then
    die "command-palette: herdr $list_desc failed:"$'\n'"$raw"
  fi
  if ! printf '%s' "$raw" | jq -e --arg collection "$collection" \
    '.result[$collection] | type == "array"' >/dev/null 2>&1; then
    die "command-palette: herdr $list_desc returned an unexpected shape"
  fi
  if printf '%s' "$raw" | jq -e --arg collection "$collection" --arg field "$id_field" '
    def has_invalid_id($field):
      if type != "object" then true
      else .[$field] as $id
      | if ($id | type) != "string" then true
        else $id == "" or ($id | contains("\u0000")) or ($id | contains("\n"))
        end
      end;
    [.result[$collection][] | select(has_invalid_id($field))] | length > 0
  ' >/dev/null 2>&1; then
    die "command-palette: herdr $list_desc returned a candidate without a valid $id_field"
  fi

  if ! value=$(printf '%s' "$raw" | jq -er \
    --arg collection "$collection" \
    --arg field "$id_field" \
    --arg origin "$origin_id" \
    --arg direction "$direction" '
      [.result[$collection][][ $field ]] as $ids
      | ($ids | index($origin)) as $index
      | if $index == null then empty
        elif $direction == "next" then $ids[(($index + 1) % ($ids | length))]
        else $ids[(($index + ($ids | length) - 1) % ($ids | length))]
        end
    '); then
    die "command-palette: herdr $list_desc did not include the origin $id_field"
  fi
}

# fetch_workspace_list_for_labels runs `herdr workspace list` and validates
# its shape, storing the raw JSON in the global $ws_list_raw. Used by the
# tabs and agents selectors to resolve workspace_id -> label for prefixing
# cross-workspace candidates (they only carry workspace_id themselves). Not a
# function returning via command substitution: die() must run in the main
# shell, not a subshell, or `exit` inside it would only end the subshell.
fetch_workspace_list_for_labels() {
  if ! ws_list_raw=$("$herdr_bin" workspace list 2>&1); then
    die "command-palette: herdr workspace list failed:"$'\n'"$ws_list_raw"
  fi
  if ! printf '%s' "$ws_list_raw" | jq -e '.result.workspaces | type == "array"' >/dev/null 2>&1; then
    die "command-palette: herdr workspace list returned an unexpected shape"
  fi
}

# 1. Check fzf and jq are available.
for bin in fzf jq; do
  command -v "$bin" >/dev/null 2>&1 || die "command-palette: $bin is not installed"
done

# 2. Check the origin context captured by open.sh.
if [ -z "${ORIGIN_PANE_ID:-}" ] || [ -z "${ORIGIN_TAB_ID:-}" ] || [ -z "${ORIGIN_WORKSPACE_ID:-}" ]; then
  die "command-palette: missing origin context (ORIGIN_PANE_ID/ORIGIN_TAB_ID/ORIGIN_WORKSPACE_ID)"
fi

# 3. Read the catalog. Die on missing/unreadable/invalid JSON; no schema
# validation at runtime (done in CI, see scripts/check-compat.sh).
if [ -z "${HERDR_PLUGIN_ROOT:-}" ]; then
  die "command-palette: HERDR_PLUGIN_ROOT is not set"
fi
catalog_path="$HERDR_PLUGIN_ROOT/commands.json"
if [ ! -r "$catalog_path" ]; then
  die "command-palette: cannot read catalog: $catalog_path"
fi
if ! jq_err=$(jq empty "$catalog_path" 2>&1); then
  die "command-palette: commands.json is not valid JSON: $jq_err"
fi

# 3b. This plugin defines exactly one catalog format, schema_version 1 (see
# docs/design/command-catalog.md); a catalog claiming a different version
# was not written for this palette.sh.
schema_version=$(jq -r '.schema_version' "$catalog_path")
if [ "$schema_version" != "1" ]; then
  die "command-palette: unsupported commands.json schema_version: $schema_version (expected 1)"
fi

# 4-5. Compare the herdr socket API protocol against expected_herdr_protocol.
# Neither an unreadable protocol nor a mismatch blocks execution; both are
# shown as a header warning only.
expected_protocol=$(jq -r '.expected_herdr_protocol' "$catalog_path")
schema_output=$("$herdr_bin" api schema 2>&1)
actual_protocol=$(printf '%s\n' "$schema_output" | sed -n 's/^protocol: *//p' | head -n 1)
main_header="herdr command palette"
if [ -z "$actual_protocol" ]; then
  main_header="warning: could not read protocol from herdr api schema"
elif [ "$actual_protocol" != "$expected_protocol" ]; then
  main_header="warning: catalog expects herdr protocol $expected_protocol, herdr reports $actual_protocol"
fi

# 6. Show the main list: id is a hidden key, title is displayed, catalog order preserved.
selected_line=$(jq -r '.commands[] | "\(.id)\t\(.title)"' "$catalog_path" \
  | fzf --delimiter=$'\t' --with-nth=2 --header="$main_header" --prompt="herdr > ")
rc=$?
require_clean_fzf_rc "$rc"
selected_id=$(printf '%s' "$selected_line" | cut -f1)

cmd_json=$(jq -c --arg id "$selected_id" '.commands[] | select(.id == $id)' "$catalog_path")
if [ -z "$cmd_json" ]; then
  die "command-palette: internal error: selected command not found in catalog"
fi
cmd_description=$(jq -r '.description' <<<"$cmd_json")
group=$(jq -r '.command[0]' <<<"$cmd_json")
subcommand=$(jq -r '.command[1]' <<<"$cmd_json")

# 7. Resolve `arguments` left to right into a plain bash array. Each resolved
# value becomes exactly one argv element; nothing is re-parsed by the shell.
argv=("$group" "$subcommand")
argc=$(jq '.arguments | length' <<<"$cmd_json")
i=0
while [ "$i" -lt "$argc" ]; do
  arg_def=$(jq -c ".arguments[$i]" <<<"$cmd_json")
  source=$(jq -r '.source' <<<"$arg_def")

  case "$source" in
    literal)
      value=$(jq -r '.value' <<<"$arg_def")
      argv+=("$value")
      ;;

    context)
      key=$(jq -r '.key' <<<"$arg_def")
      case "$key" in
        next_workspace_id|previous_workspace_id|next_tab_id|previous_tab_id)
          resolve_computed_context "$key"
          ;;
        *)
          if ! value=$(resolve_context "$key"); then
            die "command-palette: unexpected context key: $key"
          fi
          ;;
      esac
      if [ "$key" = "cwd" ]; then
        if [ -z "$value" ] || [ ! -d "$value" ]; then
          die "command-palette: origin working directory is unavailable or missing"
        fi
      fi
      argv+=("$value")
      ;;

    input)
      prompt=$(jq -r '.prompt' <<<"$arg_def")
      input_description=$(jq -r '.description // empty' <<<"$arg_def")
      if [ -z "$input_description" ]; then
        input_description="$cmd_description"
      fi
      required=$(jq -r '.required' <<<"$arg_def")
      default_context=$(jq -r '.default_context // empty' <<<"$arg_def")
      validation=$(jq -r '.validation // empty' <<<"$arg_def")

      initial_query=""
      if [ -n "$default_context" ]; then
        if ! initial_query=$(resolve_context "$default_context"); then
          die "command-palette: unexpected default_context key: $default_context"
        fi
      fi

      query_output=$(printf '' | fzf --print-query --query="$initial_query" \
        --header="$input_description" --prompt="$prompt")
      rc=$?
      # --print-query always prints the query as its first line, even on a
      # "no match" exit (1, the normal outcome here since there are no real
      # candidates to match against) — so unlike the other fzf call sites,
      # 1 is not a cancel. Only 130 (Esc/Ctrl-C) is; 2 is a genuine fzf
      # error and must not be treated as if the user simply typed nothing.
      if [ $rc -eq 130 ]; then
        exit 0
      fi
      if [ $rc -ne 0 ] && [ $rc -ne 1 ]; then
        die "command-palette: fzf exited with an unexpected status ($rc)"
      fi
      value=$(printf '%s\n' "$query_output" | sed -n '1p')

      if [ "$required" = "true" ] && [ -z "$value" ]; then
        exit 0
      fi
      if [ "$validation" = "directory" ] && [ -n "$value" ] && [ ! -d "$value" ]; then
        die "command-palette: input is not an existing directory"
      fi
      argv+=("$value")
      ;;

    select)
      selector=$(jq -r '.selector' <<<"$arg_def")
      select_prompt=$(jq -r '.prompt' <<<"$arg_def")
      select_description=$(jq -r '.description // empty' <<<"$arg_def")
      if [ -z "$select_description" ]; then
        select_description="$cmd_description"
      fi
      exclude_key=$(jq -r '.exclude_context // empty' <<<"$arg_def")
      exclude_value=""
      if [ -n "$exclude_key" ]; then
        if ! exclude_value=$(resolve_context "$exclude_key"); then
          die "command-palette: unexpected exclude_context key: $exclude_key"
        fi
      fi

      # Named selectors are mapped to their herdr list command and jq shape
      # here; commands.json never carries a list command or jq filter itself.
      case "$selector" in
        workspaces)
          list_desc="workspace list"
          raw=$("$herdr_bin" workspace list 2>&1)
          rc=$?
          if [ $rc -ne 0 ]; then
            die "command-palette: herdr $list_desc failed:"$'\n'"$raw"
          fi
          if ! printf '%s' "$raw" | jq -e '.result.workspaces | type == "array"' >/dev/null 2>&1; then
            die "command-palette: herdr $list_desc returned an unexpected shape"
          fi
          if printf '%s' "$raw" | jq -e '[.result.workspaces[] | select(.workspace_id == null or .workspace_id == "")] | length > 0' >/dev/null 2>&1; then
            die "command-palette: herdr $list_desc returned a candidate without workspace_id"
          fi
          # Sanitize label control characters (newline/tab/CR): a label is
          # herdr-supplied, not catalog-controlled, and gets embedded raw
          # into this tab-delimited candidate row; left unsanitized, a
          # label containing \n or \t could forge extra rows or shift which
          # field fzf treats as the id.
          if ! candidates=$(printf '%s' "$raw" | jq -r --arg excl "$exclude_value" '
            .result.workspaces[]
            | select($excl == "" or .workspace_id != $excl)
            | ((.label // "") | gsub("[\\n\\r\\t]"; " ")) as $label
            | "\(.workspace_id)\t\($label) (\(.workspace_id))"
          '); then
            die "command-palette: failed to build $list_desc candidates"
          fi
          ;;
        tabs)
          list_desc="tab list"
          raw=$("$herdr_bin" tab list 2>&1)
          rc=$?
          if [ $rc -ne 0 ]; then
            die "command-palette: herdr $list_desc failed:"$'\n'"$raw"
          fi
          if ! printf '%s' "$raw" | jq -e '.result.tabs | type == "array"' >/dev/null 2>&1; then
            die "command-palette: herdr $list_desc returned an unexpected shape"
          fi
          if printf '%s' "$raw" | jq -e '[.result.tabs[] | select(.tab_id == null or .tab_id == "")] | length > 0' >/dev/null 2>&1; then
            die "command-palette: herdr $list_desc returned a candidate without tab_id"
          fi

          # tab list spans all workspaces but only carries workspace_id, so
          # resolve workspace_id -> label to prefix each candidate. Labels
          # are sanitized here (see the "workspaces" case above for why).
          fetch_workspace_list_for_labels
          if ! ws_labels=$(printf '%s' "$ws_list_raw" | jq -c '
            [.result.workspaces[] | select(.workspace_id != null) | {(.workspace_id): ((.label // "") | gsub("[\\n\\r\\t]"; " "))}] | add // {}
          '); then
            die "command-palette: failed to build workspace label lookup"
          fi

          if ! candidates=$(printf '%s' "$raw" | jq -r --arg excl "$exclude_value" --argjson ws "$ws_labels" '
            .result.tabs[]
            | select($excl == "" or .tab_id != $excl)
            | ($ws[.workspace_id] // .workspace_id) as $ws_label
            | ((.label // "") | gsub("[\\n\\r\\t]"; " ")) as $label
            | "\(.tab_id)\t\($ws_label) / \($label) (\(.tab_id))"
          '); then
            die "command-palette: failed to build $list_desc candidates"
          fi
          ;;
        agents)
          list_desc="agent list"
          raw=$("$herdr_bin" agent list 2>&1)
          rc=$?
          if [ $rc -ne 0 ]; then
            die "command-palette: herdr $list_desc failed:"$'\n'"$raw"
          fi
          if ! printf '%s' "$raw" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1; then
            die "command-palette: herdr $list_desc returned an unexpected shape"
          fi
          if printf '%s' "$raw" | jq -e '[.result.agents[] | select(.pane_id == null or .pane_id == "")] | length > 0' >/dev/null 2>&1; then
            die "command-palette: herdr $list_desc returned a candidate without pane_id"
          fi

          # agent list spans all workspaces but only carries workspace_id, so
          # resolve workspace_id -> label to prefix each candidate. Labels
          # are sanitized here (see the "workspaces" case above for why).
          fetch_workspace_list_for_labels
          if ! ws_labels=$(printf '%s' "$ws_list_raw" | jq -c '
            [.result.workspaces[] | select(.workspace_id != null) | {(.workspace_id): ((.label // "") | gsub("[\\n\\r\\t]"; " "))}] | add // {}
          '); then
            die "command-palette: failed to build workspace label lookup"
          fi

          if ! candidates=$(printf '%s' "$raw" | jq -r --arg excl "$exclude_value" --argjson ws "$ws_labels" '
            .result.agents[]
            | select($excl == "" or .pane_id != $excl)
            | ($ws[.workspace_id] // .workspace_id) as $ws_label
            | ((.terminal_title_stripped // "") | gsub("[\\n\\r\\t]"; " ")) as $title
            | "\(.pane_id)\t\($ws_label) / agent: \($title) (\(.pane_id))"
          '); then
            die "command-palette: failed to build $list_desc candidates"
          fi
          ;;
        *)
          die "command-palette: unexpected selector: $selector"
          ;;
      esac

      if [ -z "$candidates" ]; then
        exit 0
      fi

      selected=$(printf '%s\n' "$candidates" \
        | fzf --delimiter=$'\t' --with-nth=2 --header="$select_description" --prompt="$select_prompt")
      rc=$?
      require_clean_fzf_rc "$rc"
      selected_id=$(printf '%s' "$selected" | cut -f1)
      if [ -z "$selected_id" ]; then
        die "command-palette: internal error: selected candidate has no id"
      fi
      argv+=("$selected_id")
      ;;

    *)
      die "command-palette: unexpected argument source: $source"
      ;;
  esac

  i=$((i + 1))
done

# 8. Confirm, if the command asks for it. No is listed first so fzf's cursor
# starts on it: a reflexive Enter cancels instead of confirming. No and Esc
# are clean cancels.
confirm_text=$(jq -r '.confirm // empty' <<<"$cmd_json")
if [ -n "$confirm_text" ]; then
  choice=$(printf 'No\nYes\n' | fzf --header="$confirm_text" --prompt="confirm > ")
  rc=$?
  require_clean_fzf_rc "$rc"
  if [ "$choice" != "Yes" ]; then
    exit 0
  fi
fi

# 9. Run the herdr CLI. Every command runs synchronously: under popup
# placement, a synchronous focus change survives the popup closing (herdr
# 0.8.0, measured 2026-08-16), so no deferred/post-close handling is needed.
# On failure, show group+subcommand+output only; never echo free-input
# values, selected ids, or the working directory.
output=$("$herdr_bin" "${argv[@]}" 2>&1)
rc=$?
if [ $rc -ne 0 ]; then
  die "command-palette: herdr $group $subcommand failed:"$'\n'"$output"
fi

# 10. Success: exit and let the popup close.
exit 0
