name: Codex connectivity test

on:
  issues:
    types:
      - labeled

permissions:
  contents: write
  issues: read
  pull-requests: write
  id-token: write

jobs:
  connectivity-test:
    if: github.event.label.name == 'codex-ready'
    uses: __AUTOMATION_REPOSITORY__/__AUTOMATION_WORKFLOW_PATH__@__AUTOMATION_WORKFLOW_SHA__
    with:
      issue_number: ${{ github.event.issue.number }}
      google_cloud_project_id: __GOOGLE_CLOUD_PROJECT_ID__
      workload_identity_provider: __WORKLOAD_IDENTITY_PROVIDER__
