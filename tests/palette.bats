#!/usr/bin/env bats
# End-to-end argument-resolution tests for palette.sh. fzf and herdr are
# controlled at their process boundaries; the real palette script and jq
# transformations execute unchanged.

setup() {
  load test_helper
  ROOT="$(repo_root)"
  TEST_PLUGIN_ROOT="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$TEST_PLUGIN_ROOT"

  export HERDR_PLUGIN_ROOT="$TEST_PLUGIN_ROOT"
  export HERDR_BIN_PATH="$ROOT/tests/stubs/herdr"
  export HERDR_STUB_CALLS="$BATS_TEST_TMPDIR/herdr-calls"
  export HERDR_STUB_ARGV_CALLS="$BATS_TEST_TMPDIR/herdr-argv"
  export ORIGIN_PANE_ID="w1:p1"
  export ORIGIN_TAB_ID="w1:t2"
  export ORIGIN_WORKSPACE_ID="w1"
  export ORIGIN_CWD="$BATS_TEST_TMPDIR"
  export PATH="$ROOT/tests/stubs:$PATH"
}

run_catalog_command() {
  export HERDR_PLUGIN_ROOT="$ROOT"
  export FZF_STUB_SELECT_ID="$1"
  run bash "$ROOT/palette.sh"
}

assert_last_argv() {
  local expected
  expected=$(jq -cn --args '$ARGS.positional' -- "$@")
  [ "$(tail -n 1 "$HERDR_STUB_ARGV_CALLS")" = "$expected" ]
}

write_navigation_catalog() {
  local group="$1"
  local key="$2"
  jq -n --arg group "$group" --arg key "$key" '
    {
      schema_version: 1,
      expected_herdr_protocol: 22,
      commands: [{
        id: "navigation.test",
        title: "Navigation test",
        description: "Resolve one computed context key.",
        command: [$group, "focus"],
        arguments: [{source: "context", key: $key}]
      }]
    }
  ' >"$TEST_PLUGIN_ROOT/commands.json"
}

run_navigation() {
  write_navigation_catalog "$1" "$2"
  run bash "$ROOT/palette.sh"
}

@test "next workspace focuses the following workspace in list order" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"},{"workspace_id":"w2","label":"two"},{"workspace_id":"w3","label":"three"}]}}'

  run_navigation workspace next_workspace_id

  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "workspace focus w2" ]
}

@test "previous workspace focuses the preceding workspace in list order" {
  export ORIGIN_WORKSPACE_ID="w2"
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"},{"workspace_id":"w2","label":"two"},{"workspace_id":"w3","label":"three"}]}}'

  run_navigation workspace previous_workspace_id

  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "workspace focus w1" ]
}

@test "next workspace wraps from the last workspace to the first" {
  export ORIGIN_WORKSPACE_ID="w3"
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"},{"workspace_id":"w2","label":"two"},{"workspace_id":"w3","label":"three"}]}}'

  run_navigation workspace next_workspace_id

  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "workspace focus w1" ]
}

@test "previous workspace wraps from the first workspace to the last" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"},{"workspace_id":"w2","label":"two"},{"workspace_id":"w3","label":"three"}]}}'

  run_navigation workspace previous_workspace_id

  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "workspace focus w3" ]
}

@test "a single workspace resolves to itself" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"}]}}'

  run_navigation workspace next_workspace_id

  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "workspace focus w1" ]
}

@test "workspace navigation reports a list command failure" {
  export HERDR_STUB_LIST_STATUS=1
  export HERDR_STUB_LIST_ERROR="socket unavailable"

  run_navigation workspace next_workspace_id

  [ "$status" -eq 1 ]
  [[ "$output" == *"command-palette: herdr workspace list failed:"* ]]
  [[ "$output" == *"socket unavailable"* ]]
}

@test "workspace navigation rejects an unexpected list shape" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":{}}}'

  run_navigation workspace next_workspace_id

  [ "$status" -eq 1 ]
  [[ "$output" == *"command-palette: herdr workspace list returned an unexpected shape"* ]]
}

@test "workspace navigation rejects a candidate without a workspace id" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"},{"label":"missing"}]}}'

  run_navigation workspace next_workspace_id

  [ "$status" -eq 1 ]
  [[ "$output" == *"command-palette: herdr workspace list returned a candidate without a valid workspace_id"* ]]
}

@test "workspace navigation rejects a numeric workspace id" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"},{"workspace_id":7,"label":"numeric"}]}}'

  run_navigation workspace next_workspace_id

  [ "$status" -eq 1 ]
  [[ "$output" == *"command-palette: herdr workspace list returned a candidate without a valid workspace_id"* ]]
}

@test "workspace navigation rejects an object workspace id" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"},{"workspace_id":{"nested":"w2"},"label":"object"}]}}'

  run_navigation workspace next_workspace_id

  [ "$status" -eq 1 ]
  [[ "$output" == *"command-palette: herdr workspace list returned a candidate without a valid workspace_id"* ]]
}

@test "workspace navigation rejects a list that omits the origin workspace" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w2","label":"two"}]}}'

  run_navigation workspace next_workspace_id

  [ "$status" -eq 1 ]
  [[ "$output" == *"command-palette: herdr workspace list did not include the origin workspace_id"* ]]
}

@test "next tab focuses the following tab within the origin workspace" {
  export HERDR_STUB_TAB_LIST_JSON='{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"one"},{"tab_id":"w1:t2","workspace_id":"w1","label":"two"},{"tab_id":"w1:t3","workspace_id":"w1","label":"three"}]}}'

  run_navigation tab next_tab_id

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$HERDR_STUB_CALLS")" = "tab list --workspace w1" ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "tab focus w1:t3" ]
}

@test "previous tab focuses the preceding tab within the origin workspace" {
  export HERDR_STUB_TAB_LIST_JSON='{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"one"},{"tab_id":"w1:t2","workspace_id":"w1","label":"two"},{"tab_id":"w1:t3","workspace_id":"w1","label":"three"}]}}'

  run_navigation tab previous_tab_id

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$HERDR_STUB_CALLS")" = "tab list --workspace w1" ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "tab focus w1:t1" ]
}

@test "next tab wraps from the last tab to the first" {
  export ORIGIN_TAB_ID="w1:t3"
  export HERDR_STUB_TAB_LIST_JSON='{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"one"},{"tab_id":"w1:t2","workspace_id":"w1","label":"two"},{"tab_id":"w1:t3","workspace_id":"w1","label":"three"}]}}'

  run_navigation tab next_tab_id

  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "tab focus w1:t1" ]
}

@test "previous tab wraps from the first tab to the last" {
  export ORIGIN_TAB_ID="w1:t1"
  export HERDR_STUB_TAB_LIST_JSON='{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"one"},{"tab_id":"w1:t2","workspace_id":"w1","label":"two"},{"tab_id":"w1:t3","workspace_id":"w1","label":"three"}]}}'

  run_navigation tab previous_tab_id

  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "tab focus w1:t3" ]
}

@test "a single tab resolves to itself" {
  export HERDR_STUB_TAB_LIST_JSON='{"result":{"tabs":[{"tab_id":"w1:t2","workspace_id":"w1","label":"two"}]}}'

  run_navigation tab next_tab_id

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$HERDR_STUB_CALLS")" = "tab list --workspace w1" ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "tab focus w1:t2" ]
}

@test "the real catalog wires Workspace Next to next_workspace_id" {
  export HERDR_PLUGIN_ROOT="$ROOT"
  export FZF_STUB_SELECT_ID="workspace.next"
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"},{"workspace_id":"w2","label":"two"}]}}'

  run bash "$ROOT/palette.sh"

  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "workspace focus w2" ]
}

@test "the real catalog wires Workspace Previous to previous_workspace_id" {
  export HERDR_PLUGIN_ROOT="$ROOT"
  export FZF_STUB_SELECT_ID="workspace.previous"
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"},{"workspace_id":"w2","label":"two"}]}}'

  run bash "$ROOT/palette.sh"

  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "workspace focus w2" ]
}

@test "the real catalog wires Tab Next to next_tab_id" {
  export HERDR_PLUGIN_ROOT="$ROOT"
  export FZF_STUB_SELECT_ID="tab.next"
  export HERDR_STUB_TAB_LIST_JSON='{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"one"},{"tab_id":"w1:t2","workspace_id":"w1","label":"two"},{"tab_id":"w1:t3","workspace_id":"w1","label":"three"}]}}'

  run bash "$ROOT/palette.sh"

  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "tab focus w1:t3" ]
}

@test "the real catalog wires Tab Previous to previous_tab_id" {
  export HERDR_PLUGIN_ROOT="$ROOT"
  export FZF_STUB_SELECT_ID="tab.previous"
  export HERDR_STUB_TAB_LIST_JSON='{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"one"},{"tab_id":"w1:t2","workspace_id":"w1","label":"two"},{"tab_id":"w1:t3","workspace_id":"w1","label":"three"}]}}'

  run bash "$ROOT/palette.sh"

  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$HERDR_STUB_CALLS")" = "tab focus w1:t1" ]
}

@test "the real catalog creates a workspace with a directory and label" {
  local directory="$BATS_TEST_TMPDIR/directory with spaces"
  mkdir -p "$directory"
  FZF_STUB_INPUTS_JSON=$(jq -cn --arg dir "$directory" \
    '{"workspace directory ▸ ": $dir, "new workspace label ▸ ": "work queue; $(noop)"}')
  export FZF_STUB_INPUTS_JSON

  run_catalog_command workspace.new.labeled

  [ "$status" -eq 0 ]
  assert_last_argv workspace create --cwd "$directory" --label 'work queue; $(noop)' --focus
}

@test "the real catalog creates a labeled tab in the origin workspace" {
  export FZF_STUB_INPUTS_JSON='{"new tab label ▸ ":"review queue"}'

  run_catalog_command tab.new.labeled

  [ "$status" -eq 0 ]
  assert_last_argv tab create --workspace w1 --label "review queue" --focus
}

@test "the real catalog clears the origin pane label" {
  run_catalog_command pane.rename.clear

  [ "$status" -eq 0 ]
  assert_last_argv pane rename w1:p1 --clear
}

@test "the real catalog moves the origin pane to a new tab" {
  run_catalog_command pane.move.new-tab

  [ "$status" -eq 0 ]
  assert_last_argv pane move w1:p1 --new-tab --focus
}

@test "the real catalog moves the origin pane to a new workspace" {
  run_catalog_command pane.move.new-workspace

  [ "$status" -eq 0 ]
  assert_last_argv pane move w1:p1 --new-workspace --focus
}

@test "the real catalog moves the origin pane to a new labeled workspace" {
  export FZF_STUB_INPUTS_JSON='{"new workspace label ▸ ":"review queue"}'

  run_catalog_command pane.move.new-workspace.labeled

  [ "$status" -eq 0 ]
  assert_last_argv pane move w1:p1 --new-workspace --label "review queue" --focus
}

@test "the real catalog moves the origin pane to another workspace excluding the origin" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"},{"workspace_id":"w2","label":"two"}]}}'

  run_catalog_command pane.move.workspace

  [ "$status" -eq 0 ]
  assert_last_argv pane move w1:p1 --new-tab --workspace w2 --focus
}

@test "the real catalog moves the origin pane to a right split excluding the origin tab" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"},{"workspace_id":"w2","label":"two"}]}}'
  export HERDR_STUB_TAB_LIST_JSON='{"result":{"tabs":[{"tab_id":"w1:t2","workspace_id":"w1","label":"origin"},{"tab_id":"w2:t1","workspace_id":"w2","label":"target"}]}}'

  run_catalog_command pane.move.tab.right

  [ "$status" -eq 0 ]
  assert_last_argv pane move w1:p1 --tab w2:t1 --split right --focus
}

@test "the real catalog moves the origin pane to a down split excluding the origin tab" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"},{"workspace_id":"w2","label":"two"}]}}'
  export HERDR_STUB_TAB_LIST_JSON='{"result":{"tabs":[{"tab_id":"w1:t2","workspace_id":"w1","label":"origin"},{"tab_id":"w2:t1","workspace_id":"w2","label":"target"}]}}'

  run_catalog_command pane.move.tab.down

  [ "$status" -eq 0 ]
  assert_last_argv pane move w1:p1 --tab w2:t1 --split down --focus
}

@test "the real catalog renames a selected agent without excluding the origin pane" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"}]}}'
  export HERDR_STUB_AGENT_LIST_JSON='{"result":{"agents":[{"pane_id":"w1:p1","workspace_id":"w1","terminal_title_stripped":"origin"},{"pane_id":"w1:p2","workspace_id":"w1","terminal_title_stripped":"other"}]}}'
  export FZF_STUB_INPUTS_JSON='{"new agent name ▸ ":"reviewer-2"}'

  run_catalog_command agent.rename

  [ "$status" -eq 0 ]
  assert_last_argv agent rename w1:p1 reviewer-2
}

@test "the real catalog sends a literal prompt to an agent excluding the origin pane" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"}]}}'
  export HERDR_STUB_AGENT_LIST_JSON='{"result":{"agents":[{"pane_id":"w1:p1","workspace_id":"w1","terminal_title_stripped":"origin"},{"pane_id":"w1:p2","workspace_id":"w1","terminal_title_stripped":"other"}]}}'
  export FZF_STUB_INPUTS_JSON='{"agent prompt ▸ ":"review \"this\"; $(noop) --flag"}'

  run_catalog_command agent.prompt

  [ "$status" -eq 0 ]
  assert_last_argv agent prompt w1:p2 'review "this"; $(noop) --flag'
}

@test "the real catalog has no protocol warning against the current stub" {
  export FZF_STUB_HEADERS="$BATS_TEST_TMPDIR/headers"

  run_catalog_command pane.rename.clear

  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$FZF_STUB_HEADERS")" = "herdr command palette" ]
  assert_last_argv pane rename w1:p1 --clear
}

@test "an older protocol warns without blocking a real catalog command" {
  export FZF_STUB_HEADERS="$BATS_TEST_TMPDIR/headers"
  export HERDR_STUB_PROTOCOL=19

  run_catalog_command pane.rename.clear

  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$FZF_STUB_HEADERS")" = "warning: catalog expects herdr protocol 22, herdr reports 19" ]
  assert_last_argv pane rename w1:p1 --clear
}

@test "labeled workspace creation rejects an invalid directory before creating anything" {
  FZF_STUB_INPUTS_JSON=$(jq -cn --arg dir "$BATS_TEST_TMPDIR/missing" \
    '{"workspace directory ▸ ": $dir, "new workspace label ▸ ": "review queue"}')
  export FZF_STUB_INPUTS_JSON

  run_catalog_command workspace.new.labeled

  [ "$status" -eq 1 ]
  [[ "$output" == *"input is not an existing directory"* ]]
  [ ! -e "$HERDR_STUB_ARGV_CALLS" ]
}

@test "new catalog inputs cancel when the required label name or prompt is empty" {
  export HERDR_STUB_WORKSPACE_LIST_JSON='{"result":{"workspaces":[{"workspace_id":"w1","label":"one"}]}}'
  export HERDR_STUB_AGENT_LIST_JSON='{"result":{"agents":[{"pane_id":"w1:p2","workspace_id":"w1","terminal_title_stripped":"other"}]}}'
  FZF_STUB_INPUTS_JSON=$(jq -cn --arg dir "$BATS_TEST_TMPDIR" '{"workspace directory ▸ ": $dir}')
  export FZF_STUB_INPUTS_JSON

  local id
  for id in workspace.new.labeled tab.new.labeled pane.move.new-workspace.labeled agent.rename agent.prompt; do
    export HERDR_STUB_ARGV_CALLS="$BATS_TEST_TMPDIR/$id-argv"
    run_catalog_command "$id"

    [ "$status" -eq 0 ]
    if [ -e "$HERDR_STUB_ARGV_CALLS" ]; then
      jq -es 'all(.[]; .[1] == "list")' "$HERDR_STUB_ARGV_CALLS"
    fi
  done
}
