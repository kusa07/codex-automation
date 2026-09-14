#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"; touch "$tmp/environment.yaml" "$tmp/caller.yaml"
cat > "$tmp/bin/yq" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --version) echo 'yq version 4.44.1' ;;
  -e) exit 0 ;;
  -r) case "$2" in
    *schema_version*) echo "${YQ_SCHEMA:-1}" ;; *.github.owner_id*) echo 32902649 ;; *.github.owner*) echo kusa07 ;;
    *repository.full_name*) echo kusa07/example-project ;; *repository.id*) echo 12345 ;; *secret.id*) echo codex-auth-example-project ;;
    *active_workflow_sha*) echo 352857a387b1f855920fb8d1587091b31e518c21 ;;
    *automation.repository*) echo kusa07/codex-automation ;;
    *automation.workflow_path*) echo .github/workflows/codex-run.yml ;;
    *google_cloud.project_id*) echo codex-automation-506111 ;; *google_cloud.project_number*) echo 896979145485 ;; *workload_identity_pool*) echo github ;;
    *workload_identity_provider_resource*) echo projects/896979145485/locations/global/workloadIdentityPools/github/providers/github-actions ;; *workload_identity_provider*) echo github-actions ;;
    *workflow.path*) echo .github/workflows/codex-connectivity-test.yml ;; *runner.enabled*) echo true ;; *runner.scope*) echo repository ;;
    *) echo '' ;; esac ;;
esac
FAKE
system_path="$PATH"
chmod +x "$tmp/bin/yq"; export PATH="$tmp/bin:$PATH"
out="$("$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$tmp/caller.yaml")"
grep -q 'ONBOARD_PLAN=PASS' <<<"$out"; grep -q 'SECRET_ID=codex-auth-example-project' <<<"$out"
touch "$tmp/template"
if "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$tmp/caller.yaml" --template "$tmp/template" --output "$tmp/rendered.yml" --mode apply --approve >/dev/null 2>&1; then echo 'Batch A apply was accepted' >&2; exit 1; fi
[[ ! -e "$tmp/rendered.yml" ]] || { echo 'Batch A apply wrote a caller workflow' >&2; exit 1; }
mkdir "$tmp/malicious-bin"
cat > "$tmp/malicious-bin/yq" <<FAKE
#!/usr/bin/env bash
if [[ "\$1" == -r && "\$2" == *automation.repository* ]]; then printf 'kusa07/good|bad\\n'; else exec "$tmp/bin/yq" "\$@"; fi
FAKE
chmod +x "$tmp/malicious-bin/yq"
if PATH="$tmp/malicious-bin:$tmp/bin:$system_path" "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$tmp/caller.yaml" >/dev/null 2>&1; then echo 'malicious automation repository was accepted' >&2; exit 1; fi
mkdir "$tmp/invalid-bin"
cat > "$tmp/invalid-bin/yq" <<'INVALID'
#!/usr/bin/env bash
case "$1" in --version) echo 'yq version 4.44.1' ;; -e) exit 0 ;; -r) echo 2 ;; esac
INVALID
chmod +x "$tmp/invalid-bin/yq"
if PATH="$tmp/invalid-bin:$system_path" "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$tmp/caller.yaml" >/dev/null 2>&1; then echo 'unsupported schema was accepted' >&2; exit 1; fi
PATH="$system_path"
if "$ROOT/scripts/onboarding/onboard-caller.sh" --environment "$tmp/environment.yaml" --caller "$tmp/caller.yaml" >/dev/null 2>&1; then echo 'missing yq was accepted' >&2; exit 1; fi
echo 'config: PASS'
