# To-Do App — Infrastructure (CloudFormation nested stacks)

Infrastructure-as-code for a highly available, containerized Django To-Do app on ECS Fargate. A single
**root stack** (`templates/root.yaml`) owns 9 **nested stacks** (network, security, vpc-endpoints,
database, cache, github-oidc, ecr, ecs-alb, autoscaling, cicd-pipeline) as `AWS::CloudFormation::Stack`
resources, wired together with `!GetAtt`.

Two different deploy mechanisms are used, deliberately:
- **`bootstrap.yaml`** (one-time prerequisite, not part of the nested tree) is deployed via **AWS
  CloudFormation Git sync** — small, security-sensitive, rarely changes, benefits from the PR-review step
  Git sync gives you.
- **`root.yaml`** (the actual application infra) is deployed by `.github/workflows/deploy-root-stack.yml`:
  on every push touching `templates/root.yaml`, `templates/stacks/**`, or `deployments/root.yaml`, GitHub
  Actions packages the nested-stack templates to S3 and runs `aws cloudformation deploy` **in the same
  job run** — no intermediate file is ever committed anywhere. Git sync isn't used here at all (see "Why
  root.yaml isn't Git-sync-deployed" below) because it has no mechanism to resolve a nested stack's
  relative `TemplateURL`.

Application code lives in a separate repo: **md6-app-repo**.

## Architecture

```
Internet ──HTTP───▶ ALB (public subnets, 2 AZ)
                       │
                       ▼
              ECS Fargate service (app subnets, 2 AZ)
              ├─ Blue target group  (prod listener :80)
              └─ Green target group (no test listener - CodeDeploy validates via target group health)
                       │
              ┌────────┴────────┐
              ▼                 ▼
      RDS Proxy (data subnets)   ElastiCache Redis (cache subnets)
              │
              ▼
      RDS PostgreSQL (data subnets, db.t3, single-AZ by default)

No NAT Gateway by default — ECS tasks and the RDS Proxy reach ECR, S3, CloudWatch
Logs and Secrets Manager entirely through VPC interface/gateway endpoints. The
data and cache subnet tiers have no internet route of any kind, NAT included.

ECR push (any tag) ──▶ EventBridge (digest override) ──▶ CodePipeline
  ──▶ CodeBuild (run `manage.py migrate`) ──▶ CodeDeploy (blue/green) ──▶ ECS
```

Diagram-as-code source lives under [`diagrams/`](diagrams/) (`diagrams` / mingrammer, standard AWS icons):

```bash
pip install diagrams
# install the Graphviz `dot` binary for your OS (brew/apt/choco install graphviz)
cd diagrams && python architecture_diagram.py   # -> architecture.png
```

## Source of truth

`templates/root.yaml` and `templates/stacks/*.yaml` are the only files you ever edit for the nested
stack. The packaged template (`aws cloudformation package`'s output, with local `TemplateURL`s rewritten
to real S3 URLs) is written to `/tmp` inside the deploy workflow's run and used immediately — it's never
written into the repo, never committed, doesn't exist once the job finishes.

## Stack layout

| Stack | Template | Creates | Depends on (via `!GetAtt`) |
|---|---|---|---|
| — | `bootstrap.yaml` (standalone, **not nested**) | S3 bucket for packaged templates, `InfraDeployRole` (dual-trust: GitHub OIDC for this repo's deploy workflow + `cloudformation.amazonaws.com` as root's execution role) | — |
| `NetworkStack` | `stacks/00-network.yaml` | VPC, 4 dedicated subnet tiers (public/app/data/cache) x 2 AZ, routing, S3 gateway endpoint | — |
| `SecurityStack` | `stacks/01-security.yaml` | 6 security groups (alb→app→proxy→db chain, app→cache, app/proxy→vpce), shared KMS CMK | Network |
| `VpcEndpointsStack` | `stacks/02-vpc-endpoints.yaml` | Interface endpoints: ECR api/dkr, CloudWatch Logs, Secrets Manager | Network, Security |
| `DatabaseStack` | `stacks/03-database.yaml` | RDS PostgreSQL, Secrets Manager credentials, **RDS Proxy** | Network, Security |
| `CacheStack` | `stacks/04-cache.yaml` | ElastiCache Redis (ReplicationGroup, 1 node by default) | Network, Security |
| `GithubOidcStack` | `stacks/06-github-oidc.yaml` | GitHub OIDC provider (conditional) + role for the app repo's CI | — |
| `EcrStack` | `stacks/05-ecr.yaml` | ECR repository (IMMUTABLE tags), policy trusting the OIDC role | Security, GithubOidc |
| `EcsAlbStack` | `stacks/07-ecs-alb.yaml` | ALB (2 target groups, 2 listeners), ALB access-logs bucket, ECS cluster/service/task def | Network, Security, Database, Cache |
| `AutoscalingStack` | `stacks/08-autoscaling.yaml` | Application Auto Scaling (1–4 tasks, CPU target tracking) | EcsAlb |
| `CicdPipelineStack` | `stacks/09-cicd-pipeline.yaml` | CodeStar connection, CodePipeline, CodeBuild (DB migration), CodeDeploy blue/green, EventBridge trigger | Network, Security, Ecr, EcsAlb |

`GithubOidcStack` and `EcrStack` are listed out of numeric order because that's the real dependency
direction: `EcrStack`'s repository policy needs `GithubOidcStack`'s role ARN. Deliberately
one-directional — nested-stack ordering resolves it, no manual two-deploy dance needed.

## Why RDS Proxy, and why the app never touches RDS directly

`03-database.yaml` puts an `AWS::RDS::DBProxy` in front of the `AWS::RDS::DBInstance`, both in the
`data` subnet tier. The security group chain enforces this at the network layer, not just by
convention: `db-sg` only accepts port 5432 from `proxy-sg`, and `proxy-sg` only accepts 5432 from
`app-sg` — there is no security group path from the ECS tasks straight to RDS. The app's
`POSTGRES_HOST` environment variable (set in `07-ecs-alb.yaml`'s task definition) is always the
**Proxy** endpoint, never the raw RDS endpoint.

## ECR tagging + EventBridge trigger design

The ECR repository is `ImageTagMutability: IMMUTABLE` — a real security best practice (no tag can ever
be silently repointed at different image content) — which means CI must push one unique tag per build
(e.g. `sha-<gitsha>`) and there's no mutable `latest` pointer to filter on. CodePipeline's native `ECR`
source action always watches one fixed, statically-configured tag, so instead:
- The EventBridge rule (`09-cicd-pipeline.yaml`) has **no `image-tag` filter** — it fires on every
  successful push to the repo, any tag.
- Its target carries an `InputTransformer` that maps the pushed image's digest
  (`$.detail.image-digest`) into a `sourceRevisions` override on `StartPipelineExecution`, pinning that
  specific pipeline run to the exact digest just pushed — a documented AWS pattern (see AWS's
  `create-cwe-ecr-source-cfn.md`), not a workaround.

The app repo's CI must **not** push a `latest` tag — see the comment in `templates/stacks/05-ecr.yaml`
and `templates/stacks/09-cicd-pipeline.yaml`.

## Database migrations under blue/green

Nothing in the container's entrypoint runs `python manage.py migrate` — doing that at container startup
is unsafe under blue/green (old and new task sets briefly run concurrently, and rollback after a failed
migration is messy). Instead, the pipeline has a **Migrate** stage between Source and Deploy: a small
CodeBuild project (`MigrationProject` in `09-cicd-pipeline.yaml`) runs the new image as a one-off Fargate
task via `aws ecs run-task` with the container command overridden to `manage.py migrate --noinput`, waits
for it to stop, and fails the pipeline if its exit code is non-zero — traffic never shifts to the new
task set until migrations have succeeded.

## Health checks

Both ALB target groups check `GET /health/` (not `/`) every 15s. The Django app **must** implement this
path returning a plain `200` with a small JSON body (e.g. `{"status": "ok"}`) — no auth, no DB
dependency, so the health check itself never flaps on a transient DB/cache blip. This is enforced at the
infra layer now; the app repo phase must honor it.

## Two-phase deploy lifecycle

**Phase 1 — bootstrap (one-time, standalone, do this first).** `templates/bootstrap.yaml` /
`deployments/bootstrap.yaml`, deployed via Git sync, create the S3 bucket that packaged templates get
uploaded to, and `InfraDeployRole` — the one role used for everything else from here on.
`bootstrap.yaml` is **not part of the nested-stack tree**.

**Phase 2 — the nested stack (ongoing).** Push a change to `templates/root.yaml`,
`templates/stacks/**`, or `deployments/root.yaml` → `.github/workflows/deploy-root-stack.yml` assumes
`InfraDeployRole` via OIDC, packages `root.yaml` to a local, never-committed file, and runs
`aws cloudformation deploy` against it in that same job.

## Why root.yaml isn't Git-sync-deployed

1. CloudFormation Git sync deploys exactly the one template file named in a deployment file's
   `template-file-path` — it has no mechanism to resolve a nested stack's `TemplateURL` from a relative
   path elsewhere in the repo. `AWS::CloudFormation::Stack` requires `TemplateURL` to already be a real
   `https://` S3 URL, so *something* has to package local templates to S3 before any deploy mechanism can
   see the parent template.
2. The packaged template is a build artifact, not something that belongs in git history — so instead of
   packaging once and committing the result for Git sync to pick up later, the same job that packages it
   also deploys it immediately, and the file never outlives that job.

`InfraDeployRole`'s trust policy reflects this directly: one statement lets GitHub Actions assume it via
OIDC (to call `aws cloudformation deploy`), a second lets `cloudformation.amazonaws.com` assume the
*same* role (as the execution role that actually provisions every resource in the nested stacks).

## One-time prerequisites (console, unavoidable manual steps)

Git sync (for `bootstrap.yaml`) and CodePipeline's GitHub source (in `CicdPipelineStack`) both rely on
**AWS CodeConnections**, which requires a one-time interactive OAuth handshake — this cannot be scripted.

1. **Link this repo for Git sync**: CloudFormation console → *Stacks* → *Create stack* → *With new
   resources* → *Sync from Git* → *Link a Git repository* → GitHub → authorize AWS's GitHub App for this
   repo. (Only needed for `bootstrap.yaml` — `root.yaml` doesn't use Git sync.)
2. **Authorize the application repo's connection**: after `CicdPipelineStack` is created, open
   **Developer Tools → Connections** in the console once and click **Update pending connection** on the
   connection named in the root stack's `AppRepoConnectionArn` output (`md6-app-repo`).

## Deploying, in order

1. **Deploy `bootstrap.yaml`** via Git sync: *Create stack* → *Sync from Git* → deployment file
   `deployments/bootstrap.yaml`, template file `templates/bootstrap.yaml`. Confirm `GitHubOrg` first.
   `CreateOidcProvider` defaults to `"false"` here on the assumption this account already has one (see
   the comment in `deployments/bootstrap.yaml`) — flip to `"true"` if this is actually a fresh account.
   This stack still needs its own one-time execution role, created by hand (console *Create role*, since
   nothing exists yet to create it for you) — scoped narrowly to just what `bootstrap.yaml` itself
   creates (S3 bucket + IAM role/OIDC provider).
2. From `bootstrap.yaml`'s outputs, add two **repository secrets** (Settings → Secrets and variables →
   Actions): `AWS_ROLE_ARN` ← `InfraDeployRoleArn`, `TEMPLATES_BUCKET` ← `TemplatesBucketName`.
3. Push to `main` (or run `deploy-root-stack.yml` manually via *Actions → Run workflow*) — this packages
   and deploys the root stack plus all 9 nested children in one run.
4. Complete the CodeConnections handshake for the app repo (see above).
5. Put the root stack's `GitHubActionsRoleArn` output into the app repo's build workflow as
   `AWS_ROLE_ARN`.

## Bootstrapping the first deploy

`07-ecs-alb.yaml` starts the ECS service on a placeholder image
(`public.ecr.aws/docker/library/httpd:2.4`) so the service has something valid to run before the app
image exists. Once the app repo's CI has pushed at least one image and `CicdPipelineStack` exists, the
EventBridge rule fires automatically and CodeDeploy performs the first real blue/green deployment.

## Getting the ALB endpoint

Nested-stack outputs aren't exported, so `list-exports` won't show them — read the root stack's own
outputs instead:

```bash
aws cloudformation describe-stacks \
  --stack-name md6-todo-dev-root \
  --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue" --output text
```

## A known caveat of ECS + CodeDeploy blue/green under CloudFormation

Once CodeDeploy performs its first blue/green swap, it registers new task definition revisions and
re-points the ECS service outside CloudFormation's knowledge. The consequence: after go-live, avoid
pushing changes to `stacks/07-ecs-alb.yaml` that touch `AppTaskDefinition` / `AppService` (e.g.
`ContainerImage`, `TaskCpu`) — the deploy workflow would try to reconcile the service back to the
stack's last-known state (the placeholder image), fighting CodeDeploy. Safe ongoing changes belong in
the app repo (`ecs/taskdef.json` + `ecs/appspec.yaml`) or in `stacks/08-autoscaling.yaml` /
`stacks/09-cicd-pipeline.yaml`.

## Failure / rollback behavior

On the **first** deploy, a failure in any one nested stack rolls back the whole root operation,
including sibling stacks that had already succeeded. On later **updates**, only the nested stacks
actually touched by that update are rolled back. Stateful resources (KMS key, DB credentials secret,
Django secret key, RDS instance) already carry `Retain`/`Snapshot` `DeletionPolicy`s and are unaffected
by root-stack rollback or deletion.

## Cost / security choices worth knowing about

- **No NAT Gateway by default** (`EnableNatGateway: "false"`). ECS tasks never need general internet
  egress — ECR, S3, CloudWatch Logs and Secrets Manager are all reached via VPC endpoints. The `data`
  and `cache` tiers have **no internet route at all**, NAT or otherwise, regardless of this setting.
  The one place this would normally bite: the ECS bootstrap placeholder image is `public.ecr.aws/...`,
  a public endpoint with no PrivateLink data path. Solved with an ECR pull-through cache
  (`05-ecr.yaml`'s `PublicEcrPullThroughCache`) instead of a NAT Gateway — the task pulls from our own
  private ECR (reachable via the existing `ecr.api`/`ecr.dkr` endpoints), and ECR fetches the upstream
  image on its own side, not over the task's network path.
- **RDS Multi-AZ is off by default** (`DBMultiAZ: "false"`) — the VPC itself is Multi-AZ (all 4 tiers
  span 2 AZs) per the requirement, but a standby RDS replica roughly doubles DB cost. Flip on for a real
  production posture.
- **ElastiCache is a single node by default** (`NumCacheClusters: 1`) — bump to 2+ for automatic
  failover / Multi-AZ (see `04-cache.yaml`).
- **ECR repository is `ImageTagMutability: IMMUTABLE`** — every pushed tag is permanent, never
  silently repointed.
- **All data at rest is KMS-encrypted** with a single rotated CMK (RDS, ElastiCache, Secrets Manager,
  ECR, CloudWatch Logs, pipeline artifacts). ALB access logs are the one exception (SSE-S3 only — an
  AWS limitation on that specific bucket use case, not a choice).
- **CI/CD uses OIDC** — no long-lived AWS credentials anywhere, each role scoped to one repo + branch
  via the `sub` claim.
- **Database migrations run as a gated pipeline stage**, never at container startup, so a bad migration
  blocks the deploy instead of corrupting a live blue/green cutover.
- Every resource is tagged `Project` / `Environment` / `ManagedBy` via `deployments/root.yaml`'s `tags:`
  block, which `deploy-root-stack.yml` passes to `aws cloudformation deploy --tags`.

## Tearing down / spinning back up later

See [`HANDOFF.md`](HANDOFF.md) for the down/up runbook and `scripts/teardown.sh`, which deletes the root
stack (cascades all 9 nested stacks automatically) and then cleans up exactly the handful of resources
their `Retain`/`Snapshot` `DeletionPolicy`s deliberately leave behind.
