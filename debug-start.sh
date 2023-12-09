#!/bin/bash

# @author Michael-Topchiev

# usage: ./debug-start.sh app namespace [worker-ip] [-f]

set -e

BASEDIR="$(dirname "$(test -L "$0" && readlink "$0" || echo "$0")")"

if [ -z "$1" ]; then
  echo "service name is required as the first parameter" >/dev/stderr
  exit 1
fi
PARAM_APP=$1

if [ -z "$2" ]; then
  echo "service namespace is required as the second parameter" >/dev/stderr
  exit 1
fi
PARAM_NAMESPACE=$2

if [ -z "$4" ] && [ "$3" == "-f" ]; then
  PARAM_IP="" # optional
  PARAM_FORCE=$3
else
  PARAM_IP=$3
  PARAM_FORCE="$4" # optional
fi

if [ -n "$4" ] && [ "$4" != "-f" ]; then
  echo "invalid 4th parameter value, can only be '-f'"
  exit 1
fi

# --------------------------------------------------------------

source $BASEDIR/config/$PARAM_APP.conf # print good error if not found
source $BASEDIR/config/globals
source $BASEDIR/debug.sh

# --------------------------------------------------------------

# check if the deployment exists
printf "${COLOR}verifying the deployment exists...${NC}\n"
kubectl get deployment $DEV_DEPLOYMENT -n $PARAM_NAMESPACE >/dev/null

stopIfAlreadyDebugging $DEV_DEPLOYMENT $PARAM_NAMESPACE

printf "${COLOR}checking the deployment status...${NC}\n"
UNAVAILABLE_REPLICAS=$(kubectl get deployment $DEV_DEPLOYMENT -n $PARAM_NAMESPACE -o "jsonpath={.status.unavailableReplicas}")
if [ "$UNAVAILABLE_REPLICAS" != "" ]; then
  echo "wait till current deployment finishes pod roll-out and then retry"
  exit 1
fi

printf "${COLOR}validating node IP address...${NC}\n"
validateWorkerIp PARAM_IP

printf "${COLOR}validating SSH configuration...${NC}\n"
configureSsh $PARAM_APP $PARAM_IP $DEV_PORT

printf "${COLOR}extracting service account name...${NC}\n"
DEV_SERVICE_ACCOUNT=$(kubectl get deployment $DEV_DEPLOYMENT -n $PARAM_NAMESPACE -o json | jq -r ".spec.template.spec.serviceAccountName")
[ "$DEV_SERVICE_ACCOUNT" == "null" ] && DEV_SERVICE_ACCOUNT=default
echo "service account name: $DEV_SERVICE_ACCOUNT"

printf "${COLOR}checking if security adjustments are required...${NC}\n"
if kubectl get crd securitycontextconstraints.security.openshift.io >/dev/null 2>&1; then
  if ! kubectl get scc dev >/dev/null 2>&1; then
    # in Openshift scc is required
    echo "${COLOR}creating SCC 'dev'..."
    kubectl apply -f $BASEDIR/scc-dev.yaml
  fi
  # TODO: only add if not already there
  printf "${COLOR}applying SCC to the service account...\n"
  oc adm policy add-scc-to-user dev -z $DEV_SERVICE_ACCOUNT -n $PARAM_NAMESPACE # not required for HO
fi

debug $DEV_DEPLOYMENT $DEV_CONTAINER $PARAM_NAMESPACE $DEV_PORT $DEV_IMAGE_TYPE $PARAM_IP $BASEDIR $PARAM_FORCE

sleep 10 # give the pods time to start

printf "${COLOR}verifying the debugger has started and is accepting connections...${NC}\n"
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "[$PARAM_IP]:$DEV_PORT" >/dev/null 2>&1
if [[ $(grep WSL2 /proc/version) ]]; then
  # if under WSL, then remove keys in Windows as well
  cmd.exe /c ssh-keygen.exe -f "%userprofile%/.ssh/known_hosts" -R "[$PARAM_IP]:$DEV_PORT"
fi
withRetry "ssh-keyscan -4 -p $DEV_PORT -H $PARAM_IP | grep "ecdsa-sha2-nistp256" >> $HOME/.ssh/known_hosts"
#withRetry "ssh -p $DEV_PORT -o ConnectTimeout=5 root@$PARAM_IP true"

printf "${COLOR}cloning source code fork into the debugger...${NC}\n"
ssh -t -p $DEV_PORT root@$PARAM_IP "cd /projects && git clone $DEV_FORK $DEV_DIR && mkdir -p $DEV_DIR/.vscode"
ssh -t -p $DEV_PORT root@$PARAM_IP "cd /projects/$DEV_DIR && git remote add upstream $DEV_UPSTREAM && git fetch upstream"
scp -P $DEV_PORT $BASEDIR/launch/launch-$PARAM_APP.json root@$PARAM_IP:/projects/$DEV_DIR/.vscode/launch.json

printf "${COLOR}configuring git inside the debugger...${NC}\n"
ssh -t -p $DEV_PORT root@$PARAM_IP "git config --global user.email \"$GLOBAL_GIT_USER_EMAIL\" && git config --global user.name \"$GLOBAL_GIT_USER_NAME\""
ssh -t -p $DEV_PORT root@$PARAM_IP "git config --global core.editor \"$GLOBAL_GIT_EDITOR\""

printf "${COLOR}starting VsCode instance...${NC}\n"
VS_CODE="code --folder-uri vscode-remote://ssh-remote+dev-cloud-$PARAM_APP/projects/$DEV_DIR"
eval "$VS_CODE"

echo "debugger successfully started!"
echo "use this command to re-start VsCode if needed: $VS_CODE"
