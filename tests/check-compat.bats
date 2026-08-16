#!/usr/bin/env bats
# scripts/check-compat.sh tests, driven against tests/stubs/herdr (a fake
# herdr CLI reproducing real herdr 0.8.0 output shapes) via HERDR_BIN_PATH —
# see docs/design/command-catalog.md, "Compatibility checks".

setup() {
  load test_helper
  ROOT="$(repo_root)"
  HERDR_BIN_PATH="$(herdr_stub)"
  export HERDR_BIN_PATH
  FIXTURE_REPO=""
}

teardown() {
  if [ -n "$FIXTURE_REPO" ]; then
    rm -rf "$FIXTURE_REPO"
  fi
}

@test "OK on the real catalog against the stub" {
  run bash "$ROOT/scripts/check-compat.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == "OK: herdr 0.8.0 is compatible (protocol 19)" ]]
}

@test "OK when computed context keys supply focus positionals" {
  FIXTURE_REPO="$(setup_fixture_repo "$ROOT/tests/fixtures/schema/valid-computed-context.json")"
  run bash "$FIXTURE_REPO/scripts/check-compat.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == "OK: herdr 0.8.0 is compatible (protocol 19)" ]]
}

@test "FAILs when tab list does not support workspace scoping" {
  HERDR_STUB_TAB_LIST_WITHOUT_WORKSPACE=1
  export HERDR_STUB_TAB_LIST_WITHOUT_WORKSPACE
  run bash "$ROOT/scripts/check-compat.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"herdr tab list -h does not mention --workspace (required by computed tab context)"* ]]
}

@test "FAILs on a protocol mismatch" {
  HERDR_STUB_PROTOCOL=20
  export HERDR_STUB_PROTOCOL
  run bash "$ROOT/scripts/check-compat.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"protocol mismatch: commands.json expects 19, herdr reports 20"* ]]
}

@test "FAILs on a duplicate command id" {
  FIXTURE_REPO="$(setup_fixture_repo "$ROOT/tests/fixtures/catalogs/duplicate-id.json")"
  run bash "$FIXTURE_REPO/scripts/check-compat.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate command ids in commands.json"* ]]
  [[ "$output" == *"dup.id"* ]]
}

@test "FAILs on an unknown subcommand (stub falls back to top-level help)" {
  FIXTURE_REPO="$(setup_fixture_repo "$ROOT/tests/fixtures/catalogs/unknown-subcommand.json")"
  run bash "$FIXTURE_REPO/scripts/check-compat.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"herdr pane teleport -h did not print that subcommand's usage line"* ]]
}

@test "FAILs when a literal flag is missing from the subcommand's help" {
  FIXTURE_REPO="$(setup_fixture_repo "$ROOT/tests/fixtures/catalogs/missing-flag-in-help.json")"
  run bash "$FIXTURE_REPO/scripts/check-compat.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"herdr pane zoom -h does not mention --nonexistent-flag"* ]]
}

@test "FAILs when a required positional is missing" {
  FIXTURE_REPO="$(setup_fixture_repo "$ROOT/tests/fixtures/catalogs/missing-positional.json")"
  run bash "$FIXTURE_REPO/scripts/check-compat.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"workspace.switch.broken: herdr workspace focus requires exactly 1 positional argument(s), commands.json supplies 0"* ]]
}

@test "FAILs when a positional has the wrong name" {
  FIXTURE_REPO="$(setup_fixture_repo "$ROOT/tests/fixtures/catalogs/wrong-positional-name.json")"
  run bash "$FIXTURE_REPO/scripts/check-compat.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"workspace.close.broken: positional #1 is tab_id but herdr workspace close expects <workspace_id>"* ]]
}

@test "FAILs when a flag's value is missing (next token is a known flag)" {
  FIXTURE_REPO="$(setup_fixture_repo "$ROOT/tests/fixtures/catalogs/missing-flag-value.json")"
  run bash "$FIXTURE_REPO/scripts/check-compat.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pane.split.broken: flag --pane is missing its value (next token is --direction)"* ]]
}

@test "FAILs on a surplus positional" {
  FIXTURE_REPO="$(setup_fixture_repo "$ROOT/tests/fixtures/catalogs/surplus-positional.json")"
  run bash "$FIXTURE_REPO/scripts/check-compat.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"workspace.close.surplus: herdr workspace close requires exactly 1 positional argument(s), commands.json supplies 2"* ]]
}
