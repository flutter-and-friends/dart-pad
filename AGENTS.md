# Agent setup and Workflow

## Rebuild & redeploy

Changes here ship through the fitd26 deployment's **`dart-services`** image
(`flutter-in-the-dark/deploy/Dockerfile.dart-services`), which uses this repo as
its Docker build context (`DART_PAD_PATH`, default `../dart-pad`). After any
pushed change, show the user the exact rebuild/redeploy steps:

1. Remind them to pull THIS checkout before building (the image builds from the
   local checkout, not from a fetched ref).
2. `docker compose build dart-services && docker compose up -d dart-services`.

The `artifacts/` + `project_templates/` are **gitignored and generated** by
`dart tool/grind.dart build-project-templates` + `build-storage-artifacts`
inside the image build against the pinned Flutter SDK. Never hand-edit them as
a "fix" without fixing the grind step that produces them — that local-vs-build
divergence is what caused the production `require.js` iframe bug.
