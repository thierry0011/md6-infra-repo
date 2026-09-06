#!/usr/bin/env bash
# Tears down the md6-todo-dev root stack cleanly through CloudFormation (a
# single delete-stack call cascades all 9 nested stacks, in the right
# order, automatically - no manual per-resource deletion), then purges the
# handful of resources that deliberately survive stack deletion because of
# their DeletionPolicy (Retain/Snapshot - see each template). Re-run-safe:
# every step checks whether there's anything left to do before acting.
#
# Does NOT touch bootstrap.yaml's stack - it's CloudFormation Git-sync-
# managed, which has no CLI-scriptable delete path. See HANDOFF.md for the
# console steps to remove it, and for why you'd want to leave it in place
# most of the time anyway.
#
# Usage:
#   AWS_PROFILE=admin ./teardown.sh [--yes] [--delete-snapshot] [--schedule-key-deletion-days N]
#
#   --yes                            Skip the "type the stack name" confirmation.
#   --delete-snapshot                Also delete the final RDS snapshot CFN
#                                    creates on DBInstance deletion. Default:
#                                    leave it - it's the only way to restore
#                                    this lab's data later.
#   --schedule-key-deletion-days=N   Schedule the retained KMS key for
#                                    deletion after N days (7-30). Default:
#                                    leave the key pending-retention forever;
#                                    only the alias is removed (so a respin
#                                    can reuse the alias name immediately).
set -euo pipefail

REGION="us-east-1"
PROJECT="md6-todo"
ENV="dev"
PROFILE="${AWS_PROFILE:-default}"
ROOT_STACK="${PROJECT}-${ENV}-root"

aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ACCESS_LOGS_BUCKET="${PROJECT}-${ENV}-alb-logs-${ACCOUNT_ID}"
PIPELINE_ARTIFACT_BUCKET="${PROJECT}-${ENV}-pipeline-artifacts-${ACCOUNT_ID}"
ECR_REPOSITORY="${PROJECT}-${ENV}-app"
DB_SECRET="${PROJECT}-${ENV}-db-credentials"
DJANGO_SECRET="${PROJECT}-${ENV}-django-secret-key"
KMS_ALIAS="alias/${PROJECT}-${ENV}"

DELETE_SNAPSHOT=false
SCHEDULE_KEY_DAYS=""
SKIP_CONFIRM=false

for arg in "$@"; do
  case "$arg" in
    --yes) SKIP_CONFIRM=true ;;
    --delete-snapshot) DELETE_SNAPSHOT=true ;;
    --schedule-key-deletion-days=*) SCHEDULE_KEY_DAYS="${arg#*=}" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

echo "About to tear down: $ROOT_STACK (region $REGION, account $ACCOUNT_ID, profile $PROFILE)"
if [ "$SKIP_CONFIRM" != true ]; then
  read -rp "Type the stack name to confirm: " CONFIRM
  [ "$CONFIRM" = "$ROOT_STACK" ] || { echo "Aborted - input didn't match."; exit 1; }
fi

empty_bucket_all_versions() {
  local bucket="$1"
  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "    $bucket doesn't exist, skipping"
    return
  fi
  local vcount
  vcount=$(aws s3api list-object-versions --bucket "$bucket" --query 'Versions[] | length(@)' --output text)
  if [ "$vcount" != "0" ] && [ "$vcount" != "None" ]; then
    aws s3api list-object-versions --bucket "$bucket" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json > /tmp/teardown-versions.json
    aws s3api delete-objects --bucket "$bucket" --delete file:///tmp/teardown-versions.json >/dev/null
  fi
  local mcount
  mcount=$(aws s3api list-object-versions --bucket "$bucket" --query 'DeleteMarkers[] | length(@)' --output text)
  if [ "$mcount" != "0" ] && [ "$mcount" != "None" ]; then
    aws s3api list-object-versions --bucket "$bucket" \
      --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json > /tmp/teardown-markers.json
    aws s3api delete-objects --bucket "$bucket" --delete file:///tmp/teardown-markers.json >/dev/null
  fi
}

# --- 1. Empty the pipeline artifact bucket -------------------------------
# No DeletionPolicy on this one (defaults to Delete) but it's versioned and
# CodePipeline writes to it continuously on every deploy. A non-empty
# versioned bucket makes CicdPipelineStack - and so the whole root stack -
# fail deletion.
echo "==> Emptying $PIPELINE_ARTIFACT_BUCKET so stack deletion doesn't stall on it..."
empty_bucket_all_versions "$PIPELINE_ARTIFACT_BUCKET"

# --- 1b. Empty the ECR repository ----------------------------------------
# EcrStack's AppRepository has no DeletionPolicy either, and ECR (like S3)
# refuses to delete a non-empty repository.
echo "==> Emptying ECR repository $ECR_REPOSITORY so EcrStack doesn't stall on it..."
if aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" >/dev/null 2>&1; then
  IMAGE_COUNT=$(aws ecr list-images --repository-name "$ECR_REPOSITORY" --query 'imageIds[] | length(@)' --output text)
  if [ "$IMAGE_COUNT" != "0" ] && [ "$IMAGE_COUNT" != "None" ]; then
    aws ecr list-images --repository-name "$ECR_REPOSITORY" --query 'imageIds' --output json > /tmp/teardown-ecr-images.json
    aws ecr batch-delete-image --repository-name "$ECR_REPOSITORY" --image-ids file:///tmp/teardown-ecr-images.json >/dev/null
    echo "    deleted $IMAGE_COUNT image(s) from $ECR_REPOSITORY"
  fi
else
  echo "    $ECR_REPOSITORY doesn't exist, skipping"
fi

# --- 2. Delete the root stack (cascades all 9 nested stacks) -----------
echo "==> Deleting stack $ROOT_STACK ..."
aws cloudformation delete-stack --stack-name "$ROOT_STACK"
echo "==> Waiting for deletion to complete (typically 15-25 min - RDS takes a while)..."
if ! aws cloudformation wait stack-delete-complete --stack-name "$ROOT_STACK"; then
  cat <<EOF

Deletion didn't finish cleanly. Check the stack events:
  aws cloudformation describe-stack-events --stack-name $ROOT_STACK --max-items 20
EOF
  exit 1
fi
echo "==> Root stack deleted."

# --- 3. Clean up the resources it deliberately left behind ---------------
echo "==> Cleaning up retained resources..."

# 3a. Secrets Manager - force-delete (no recovery window) so a respin can
#     recreate a secret with the same name immediately.
for secret in "$DB_SECRET" "$DJANGO_SECRET"; do
  if aws secretsmanager describe-secret --secret-id "$secret" >/dev/null 2>&1; then
    aws secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery >/dev/null
    echo "    deleted secret: $secret"
  else
    echo "    secret already gone: $secret"
  fi
done

# 3b. S3 bucket (versioned, no DeletionPolicy but may still be non-empty at
#     this point if a request came in mid-teardown) - empty then delete.
if aws s3api head-bucket --bucket "$ACCESS_LOGS_BUCKET" 2>/dev/null; then
  empty_bucket_all_versions "$ACCESS_LOGS_BUCKET"
  aws s3api delete-bucket --bucket "$ACCESS_LOGS_BUCKET"
  echo "    deleted bucket: $ACCESS_LOGS_BUCKET"
else
  echo "    bucket already gone: $ACCESS_LOGS_BUCKET"
fi

# 3c. KMS - the alias name is also deterministic, so it must go for a
#     respin to succeed; the underlying key can't be deleted instantly
#     (7-30 day minimum waiting period) and a respin creates a brand new
#     key anyway, so by default we only remove the alias and leave the old
#     key pending (costs ~$1/mo until you schedule its deletion yourself).
if aws kms describe-key --key-id "$KMS_ALIAS" >/dev/null 2>&1; then
  KEY_ID=$(aws kms describe-key --key-id "$KMS_ALIAS" --query 'KeyMetadata.KeyId' --output text)
  aws kms delete-alias --alias-name "$KMS_ALIAS"
  echo "    deleted alias $KMS_ALIAS (underlying key $KEY_ID left pending)"
  if [ -n "$SCHEDULE_KEY_DAYS" ]; then
    aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days "$SCHEDULE_KEY_DAYS" >/dev/null
    echo "    scheduled key $KEY_ID for deletion in $SCHEDULE_KEY_DAYS days"
  else
    echo "    key $KEY_ID left pending forever - pass --schedule-key-deletion-days=N to actually schedule it"
  fi
else
  echo "    KMS alias already gone: $KMS_ALIAS"
fi

# 3d. RDS final snapshot - CloudFormation names it automatically when
#     DBInstance is deleted under a Snapshot policy, using the nested
#     stack's own logical/physical IDs, not a name you can predict from
#     PROJECT/ENV alone - match loosely by substring instead.
SNAPSHOT=$(aws rds describe-db-snapshots \
  --query "DBSnapshots[?contains(DBSnapshotIdentifier, \`${PROJECT}-${ENV}\`)].DBSnapshotIdentifier" \
  --output text)
if [ -n "$SNAPSHOT" ] && [ "$SNAPSHOT" != "None" ]; then
  echo "    final RDS snapshot: $SNAPSHOT"
  if [ "$DELETE_SNAPSHOT" = true ]; then
    aws rds delete-db-snapshot --db-snapshot-identifier "$SNAPSHOT" >/dev/null
    echo "    deleted snapshot: $SNAPSHOT"
  else
    echo "    left in place - pass --delete-snapshot to remove it too (it's your only restore point)"
  fi
else
  echo "    no final RDS snapshot found"
fi

echo
echo "==> Done. Root stack and its retained resources are handled."
echo "==> bootstrap.yaml's stack is untouched by design - see HANDOFF.md if you also want to tear that down."
