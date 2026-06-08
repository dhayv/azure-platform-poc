#! /usr/bin/env bash

set -euo pipefail

REGISTRY_NAME="devplatformpoc.azurecr.io" # e.g., myacr.azurecr.io
IMAGE_NAME="fastapi"

echo "Setting Variables"

export SHA="$(git rev-parse --short HEAD)" 
export BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Variables Set: SHA=${SHA}, BUILD_TIME=${BUILD_TIME}"

echo "Build and push Docker images"

docker build -t "$REGISTRY_NAME"/"$IMAGE_NAME":$SHA app/
docker push "$REGISTRY_NAME"/"$IMAGE_NAME":$SHA

kubectl apply -f k8s/namespace.yaml

sed -e "s|__SHA__|$SHA|g" -e "s|__BUILD_TIME__|$BUILD_TIME|g" k8s/deploy.yaml \
  | kubectl apply -f -

kubectl apply -f k8s/service.yaml
kubectl rollout status deploy/fastapi-backend -n app


kubectl get pods -n app -o wide

echo "Deployment completed successfully!"