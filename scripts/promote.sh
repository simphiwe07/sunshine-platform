#!/usr/bin/env bash
# GitOps promotion: point the lab at an image CI built, by digest.
#   scripts/promote.sh             newest image in ECR
#   scripts/promote.sh <git-sha>   a specific build (also how you roll back)
# Writes deploy/charts/sunshine-app/values-lab.yaml; you commit it in a PR and
# Argo CD deploys it after the merge.
set -euo pipefail

REPO_NAME=sunshine-app
FILE=deploy/charts/sunshine-app/values-lab.yaml
export AWS_REGION="${AWS_REGION:-eu-west-1}"
SHA="${1:-}"

if [ -z "$SHA" ]; then
  # newest image that has a git-SHA tag (skips .sig and other artifacts)
  SHA=$(aws ecr describe-images --repository-name "$REPO_NAME" --filter tagStatus=TAGGED \
    --query 'reverse(sort_by(imageDetails,&imagePushedAt))[].imageTags[]' --output text \
    | tr '\t' '\n' | grep -E '^[0-9a-f]{40}$' | head -1)
fi
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "not a full git SHA: '$SHA'" >&2; exit 1; }

DIGEST=$(aws ecr describe-images --repository-name "$REPO_NAME" --image-ids imageTag="$SHA" \
  --query 'imageDetails[0].imageDigest' --output text 2> /dev/null) \
  || { echo "no image tagged $SHA in ECR - did the app workflow finish?" >&2; exit 1; }
URI=$(aws ecr describe-repositories --repository-names "$REPO_NAME" \
  --query 'repositories[0].repositoryUri' --output text)

NEW="image: $URI@$DIGEST"
if grep -qxF "$NEW" "$FILE"; then
  echo "lab already runs $SHA ($DIGEST) - nothing to change"; exit 0
fi
awk -v new="$NEW" '/^image:/ { print new; next } { print }' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"

echo "values-lab.yaml -> $SHA"
echo "                   $DIGEST"
cat << NEXT

Next:
  git checkout -b deploy/${SHA:0:7}
  git commit -am "deploy: sunshine-app ${SHA:0:7}"
  git push -u origin deploy/${SHA:0:7}    # open the PR, merge -> Argo CD syncs
NEXT
