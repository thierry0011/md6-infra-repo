# Handoff — tearing down and re-spinning up the lab

Living doc for "I'm putting the lab down for a while and will restart it later." Complements
`README.md` (architecture, ongoing operation) — this file is specifically the down/up procedure, meant to
be filled in with real values right after the first successful deploy so future-you doesn't have to
re-derive anything from CloudTrail.

**Not yet filled in** — this repo hasn't been deployed yet. After your first successful
`deploy-root-stack.yml` run, replace the table below with the real values from
`aws cloudformation describe-stacks --stack-name md6-todo-dev-root` and `aws sts get-caller-identity`.

## Current known values (fill in after first deploy)

| Thing | Value |
|---|---|
| AWS account | `<fill in>` |
| Region | `us-east-1` |
| Root stack | `md6-todo-dev-root` (7 nested stacks under it) |
| Bootstrap stack (Git sync, in `md6-bootstrap-repo`) | `<fill in - whatever name you gave it in the console>` |
| GitHub org | `thierry0011` |
| Infra repo | `md6-infra-repo` |
| App repo | `md6-app-repo` |
| Access-logs bucket | `md6-todo-dev-alb-logs-<account-id>` |
| Pipeline artifact bucket | `md6-todo-dev-pipeline-artifacts-<account-id>` |
| Templates bucket (bootstrap) | `md6-todo-dev-cfn-templates-<account-id>` |
| DB credentials secret | `md6-todo-dev-db-credentials` |
| Django secret key secret | `md6-todo-dev-django-secret-key` |
| KMS alias | `alias/md6-todo-dev` |
| RDS instance identifier | `md6-todo-dev-db` |
| RDS Proxy name | `md6-todo-dev-db-proxy` |
| Redis replication group | `md6-todo-dev-redis` |

All of the above (except the KMS key's actual key ID, which is random) are **deterministic names with no
random suffix** — meaning if a resource is left behind after a teardown, a respin's `CREATE` for that
same logical resource will fail with "already exists." That's the whole reason `scripts/teardown.sh`
does more than just `delete-stack`.

## Tearing down

### 1. Delete the root stack + its retained resources (scripted)

```bash
cd Md6-infra-repo
AWS_PROFILE=<your-profile> ./scripts/teardown.sh
```

This does, in order:
1. Empties the pipeline artifact bucket first — it has no `DeletionPolicy` (so CloudFormation's
   default is to delete it), but it refuses to delete while non-empty, and it's non-empty by design at
   teardown time. A non-empty bucket makes its owning nested stack — and so the whole root stack —
   `DELETE_FAILED`. (The ECR repository is *not* touched here — it now lives in `md6-bootstrap-repo`,
   outside this root stack's tree, so root-stack deletion never attempts to delete it.)
2. `aws cloudformation delete-stack` on `md6-todo-dev-root`, then waits for `DELETE_COMPLETE`.
   CloudFormation cascades all 7 nested stacks itself, in the correct dependency order.
3. Cleans up exactly what step 2 deliberately doesn't touch, because every one of these carries
   `DeletionPolicy: Retain` or `Snapshot`: the DB credentials + Django secret key secrets, the ALB
   access-logs bucket, the KMS alias (key itself left pending-retention), and reports on the RDS final
   snapshot (left in place by default — pass `--delete-snapshot` to remove it too).

### 2. `md6-bootstrap-repo`'s stack

Left untouched by the script on purpose — it's Git-sync-managed (no CLI-scriptable delete path) and
cheap to leave running (one S3 bucket, two IAM roles, the ECR repository). If you do want to remove
it: empty the ECR repository first (ECR refuses to delete non-empty repos), then CloudFormation
console → find the stack → *Delete*. Its `TemplatesBucket` has `DeletionPolicy: Retain`, so empty and
delete that bucket by hand afterward if you want it gone too.

## Spinning back up later

1. If `md6-bootstrap-repo`'s stack was deleted, redeploy it first (Git sync, see its README) and
   re-add the GitHub repo secrets/deployment params from its outputs (into both `md6-infra-repo` and
   `md6-app-repo`).
2. Push to `main` (or run `deploy-root-stack.yml` manually) to recreate the root stack + all 7 nested
   children. Put the recreated root stack's `PipelineArtifactBucketName` output into the app repo's
   `ARTIFACT_BUCKET` env var if the pipeline artifact bucket's account-derived name changed.
3. Confirm the RDS instance restored correctly (if you kept the final snapshot, note this template
   creates a **fresh empty database** by default — restoring from that snapshot is a manual
   `RDS > Snapshots > Restore` step, then repoint `DBInstanceIdentifier`, not something this stack
   automates).
