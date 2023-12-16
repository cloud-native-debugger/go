#!/bin/bash

# @author Michael-Topchiev

# usage: ./debug-stop.sh app namespace

BASEDIR="$(dirname "$(test -L "$0" && readlink "$0" || echo "$0")")"

if [ -z "$2" ]; then
  echo "need two parameters: app and namespace" >/dev/stderr
  exit 1
fi

PARAM_APP=$1
PARAM_NAMESPACE="$2"

source $BASEDIR/config/$PARAM_APP.conf # print good error if not found
source $BASEDIR/config/globals

# extract service account name
DEV_SERVICE_ACCOUNT=$(kubectl get deployment $DEV_DEPLOYMENT -n $PARAM_NAMESPACE -o json | jq -r ".spec.template.spec.serviceAccountName")
[ "$DEV_SERVICE_ACCOUNT" == "null" ] && DEV_SERVICE_ACCOUNT=default
echo "service account name: $DEV_SERVICE_ACCOUNT"

BACKUP_FOUND=y
kubectl get cm backup-$DEV_DEPLOYMENT -n $PARAM_NAMESPACE >/dev/null 2>&1 || BACKUP_FOUND=n
if [ $BACKUP_FOUND == "n" ]; then
  echo "backup configmap 'backup-$DEV_DEPLOYMENT' of deployment $DEV_DEPLOYMENT is not found, nothing to restore" >/dev/stderr
  exit 1
fi

kubectl replace -f <(oc get configmap/backup-$DEV_DEPLOYMENT -n $PARAM_NAMESPACE -o "jsonpath={ .data.$DEV_DEPLOYMENT}" | sed '/^  uid:/d' | sed '/^  resourceVersion:/d')

kubectl delete svc "dev-${DEV_DEPLOYMENT:0:55}-svc" -n $PARAM_NAMESPACE --ignore-not-found=true
kubectl delete cm backup-$DEV_DEPLOYMENT -n $PARAM_NAMESPACE

# check if scc removal is needed
if kubectl get crd securitycontextconstraints.security.openshift.io >/dev/null 2>&1; then
  oc adm policy remove-scc-from-user dev -z $DEV_SERVICE_ACCOUNT -n $PARAM_NAMESPACE # not required for HO
fi

echo "Restored deployment '$DEV_DEPLOYMENT' and deleted service 'dev-$DEV_DEPLOYMENT-svc' in namespace $PARAM_NAMESPACE"
