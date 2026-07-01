#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"

api_count=0
workflow_count=0
package_only_count=0
no_marker_count=0
static_only_count=0
total=0

package_only=()
no_marker=()
static_only=()

printf 'scenario\tmarkers\n'
for script in "$ROOT"/scenarios/*/test/run.sh; do
  [ -f "$script" ] || continue
  scenario="${script#"$ROOT"/scenarios/}"
  scenario="${scenario%%/*}"
  markers=()

  if rg -q 'curl|kubectl port-forward|workflow-server|BASE_URL' "$script"; then
    markers+=("api")
  fi
  if rg -q 'wfctl|workflow-server' "$script"; then
    markers+=("workflow")
  fi
  if rg -q 'go test' "$script"; then
    markers+=("gotest")
  fi
  if rg -q 'grep -q.*\$CONFIG|grep -q.*config' "$script"; then
    markers+=("static")
  fi

  has_api=0
  has_workflow=0
  has_gotest=0
  has_static=0
  for marker in "${markers[@]}"; do
    case "$marker" in
      api) has_api=1 ;;
      workflow) has_workflow=1 ;;
      gotest) has_gotest=1 ;;
      static) has_static=1 ;;
    esac
  done

  total=$((total + 1))
  [ "$has_api" -eq 1 ] && api_count=$((api_count + 1))
  [ "$has_workflow" -eq 1 ] && workflow_count=$((workflow_count + 1))

  if [ "$has_gotest" -eq 1 ] && [ "$has_api" -eq 0 ] && [ "$has_workflow" -eq 0 ]; then
    package_only_count=$((package_only_count + 1))
    package_only+=("$scenario")
  fi
  if [ "${#markers[@]}" -eq 0 ]; then
    no_marker_count=$((no_marker_count + 1))
    no_marker+=("$scenario")
  fi
  if [ "$has_static" -eq 1 ] && [ "$has_api" -eq 0 ] && [ "$has_workflow" -eq 0 ]; then
    static_only_count=$((static_only_count + 1))
    static_only+=("$scenario")
  fi

  if [ "${#markers[@]}" -eq 0 ]; then
    printf '%s\t%s\n' "$scenario" "none"
  else
    printf '%s\t%s\n' "$scenario" "${markers[*]}"
  fi
done

printf '\nsummary\n'
printf 'total=%d\n' "$total"
printf 'api_boundary=%d\n' "$api_count"
printf 'workflow_boundary=%d\n' "$workflow_count"
printf 'package_test_only=%d\n' "$package_only_count"
printf 'static_only=%d\n' "$static_only_count"
printf 'no_marker=%d\n' "$no_marker_count"

printf '\npackage_test_only\n'
printf '%s\n' "${package_only[@]:-}"

printf '\nstatic_only\n'
printf '%s\n' "${static_only[@]:-}"

printf '\nno_marker\n'
printf '%s\n' "${no_marker[@]:-}"
