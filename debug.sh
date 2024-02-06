#!/bin/bash

# @author Michael-Topchiev

stopIfAlreadyDebugging() {
  local -r DEPLOYMENT="$1"
  local -r NAMESPACE="$2"
  local ALREADY_DEBUGGING=$(kubectl get deployment $DEPLOYMENT -n $NAMESPACE -o json | jq -r '.spec.template.spec.containers[] | select(.command==["/dev-entrypoint"])')
  if [ "$ALREADY_DEBUGGING" != "" ]; then
    echo "already debugging the deployment!"
    exit 1
  fi
}

debug() {
  # debug <deployment-name> <container-name> <namespace-name> <port> <image-type> <worker-ip> <basedir> [-f]
  # parameter values should be validated before calling this function!

  local -r DEPLOYMENT="$1"
  local -r CONTAINER="$2"
  local -r NAMESPACE="$3"
  local -r PORT="$4"
  local -r IMAGE_TYPE=$5
  local -r IP="$6"
  local -r BASEDIR="$7"
  local -r FORCE="$8" # optional

  stopIfAlreadyDebugging $DEPLOYMENT $NAMESPACE

  printf "${COLOR}extracting source image from the deployment...${NC}\n"
  local SOURCE_IMAGE=$(kubectl get deployment $DEPLOYMENT -n $NAMESPACE -o json | jq -r ".spec.template.spec.containers[] | select(.name==\"$CONTAINER\") | .image")
  if [ "$SOURCE_IMAGE" == "" ]; then
    echo "failed to extract source image from the deployment, please check parameters."
    exit 1
  fi
  echo "source image: $SOURCE_IMAGE"

  if [ "$DEV_SOURCE_IMAGE_OVERRIDE" != "" ]; then
    echo "Source image overridden with $DEV_SOURCE_IMAGE_OVERRIDE"
    SOURCE_IMAGE=$DEV_SOURCE_IMAGE_OVERRIDE
  fi

  # digest of the image will be used as a tag for the debugger image
  printf "${COLOR}pulling the source image from the registry...${NC}\n"
  $GLOBAL_DOCKER pull $SOURCE_IMAGE
  local SOURCE_IMAGE_WITH_DIGEST=$($GLOBAL_DOCKER inspect --format='{{index .RepoDigests 0}}' $SOURCE_IMAGE)
  local DEBUGGER_IMAGE_TAG=$(awk -F'@sha256:' '{ print $2 }' <<<$SOURCE_IMAGE_WITH_DIGEST)

  printf "${COLOR}validating the source image digest/tag...${NC}\n"
  if [[ "$DEBUGGER_IMAGE_TAG" =~ [^a-z0-9] ]] || [[ ${#DEBUGGER_IMAGE_TAG} -ne 64 ]]; then
    echo "error: retrieved invalid image digest: $DEBUGGER_IMAGE_TAG" >/dev/stderr
    exit 1
  fi
  echo "using image digest $DEBUGGER_IMAGE_TAG as the debugger image tag"

  # Must login before running this script: 'docker login quay.io -u michael_topchiev -p ...'
  # TODO: check if logged in, otherwise prompt to log in
  printf "${COLOR}building and uploading the debug image, if not already there...${NC}\n"
  [ -z $GLOBAL_DOCKER ] && GLOBAL_DOCKER=docker
  local DEBUGGER_IMAGE=$GLOBAL_REGISTRY_URL/$GLOBAL_REGISTRY_LIBRARY/$GLOBAL_DEBUGGER_IMAGE:$DEBUGGER_IMAGE_TAG
  if ! $GLOBAL_DOCKER manifest inspect $DEBUGGER_IMAGE >/dev/null || [ -n "$FORCE" ]; then
    echo "building debugger image $DEBUGGER_IMAGE ..."
    $GLOBAL_DOCKER build --rm -f $BASEDIR/image/Dockerfile.$IMAGE_TYPE -t $DEBUGGER_IMAGE --build-arg FROM_IMAGE="$SOURCE_IMAGE" --build-arg AUTHORIZED_KEYS="$(cat ~/.ssh/id_rsa.pub)" --build-arg GO_VERSION="$DEV_GO_VERSION" $BASEDIR/image
    $GLOBAL_DOCKER push $DEBUGGER_IMAGE
  fi

  printf "${COLOR}making a backup copy of the service deployment...${NC}\n"
  local MAKE_BACKUP=n
  kubectl get cm backup-$DEPLOYMENT -n $NAMESPACE >/dev/null 2>&1 || MAKE_BACKUP=y
  if [ $MAKE_BACKUP == "n" ]; then
    if yesOrNo "backup copy of the deployment '$DEPLOYMENT' already exists, overwrite?"; then
      kubectl delete cm backup-$DEPLOYMENT -n $NAMESPACE
      MAKE_BACKUP=y
    fi
  fi
  if [ $MAKE_BACKUP == "y" ]; then
    kubectl create configmap backup-$DEPLOYMENT -n $NAMESPACE --from-literal=$DEPLOYMENT="$(kubectl get deploy $DEPLOYMENT -n $NAMESPACE -o yaml)"
  fi

  printf "${COLOR}patching the service deployment...${NC}\n"
  kubectl patch deployment $DEPLOYMENT -n $NAMESPACE --patch "$(
    cat <<EOF
{
    "spec": {
        "replicas":1,
        "template": {
            "spec": {
                "containers": [{
                        "name": "$CONTAINER",
                        "args": null,
                        "command": ["/dev-entrypoint"],
                        "image": "$DEBUGGER_IMAGE",
                        "imagePullPolicy": "Always",
                        "livenessProbe": null,
                        "readinessProbe": null,
                        "resources": null,
                        "securityContext": {
                            "capabilities": {
                                "add": ["CAP_AUDIT_WRITE", "CAP_SYS_CHROOT"],
                                "drop": null
                            },
                           "runAsUser": 0,
                           "runAsNonRoot": false
                        }
                    }
                ]
            }
        }
    }
}
EOF
  )"

  printf "${COLOR}exposing the debugger pod with a kubernetes node-port service...${NC}\n"
  local -r SVC_NAME="dev-${DEPLOYMENT:0:55}-svc"
  kubectl delete svc "$SVC_NAME" -n $NAMESPACE --ignore-not-found=true
  kubectl expose deployment $DEPLOYMENT --name="$SVC_NAME" --type=NodePort --port=2222 --target-port=2222 -n $NAMESPACE
  kubectl patch svc $SVC_NAME -p "{\"spec\":{\"ports\":[{\"port\":2222,\"targetPort\":2222,\"nodePort\":$PORT}]}}" -n $NAMESPACE
}

validateWorkerIp() {
  local -n IP=$1 # passed by reference

  if [ "$IP" == "localhost" ]; then
    echo "'localhost' is specified as the worker node IP address - port-forward will be used"
    return
  fi

  if [ -z "$IP" ]; then
    echo "worker node IP address is not specified, one of the worker nodes IP will be used"
    IP=$(kubectl get nodes -o wide --no-headers | sort | awk '{print $6}' | head -n 1)
  fi

  if ! valid_ip $IP; then
    echo "error: specified IP address is invalid" >/dev/stderr
    exit 1
  fi

  if ! ping $IP -w 1 -c 1 >/dev/null; then
    echo "error: specified IP address does not respond to ping" >/dev/stderr
    exit 1
  fi

  if ! kubectl get nodes -o wide --no-headers | grep -w -q $IP; then
    if ! yesOrNo "specified IP address does not appear to belong to any of the workers, are you sure you want to use it?"; then
      echo "Aborted"
      exit 1
    fi
  fi

  echo "IP address $IP will be used as the service SSH host name"
}

# Test an IP address for validity
function valid_ip() {
  local ip=$1
  local stat=1

  if [ "$1" == "localhost" ]; then
    return 0
  fi
  if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    OIFS=$IFS
    IFS='.'
    ip=($ip)
    IFS=$OIFS
    [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 &&
      ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
    stat=$?
  fi
  return $stat
}

withRetry() {
  local h=1
  until eval "$@"; do
    echo "Command $1 failed with exit code $?. Attempt number: $h"
    h=$((h + 1))
    if [ "$h" -ge 20 ]; then
      echo "Command $1 failed $h in a row something appears to be wrong"
      return 1
    fi
    sleep 15
  done
  return 0
}

yesOrNo() {
  local PROMPT="${YELLOW}$1 ${NC}"
  while true; do

    read -p "$PROMPT" yn
    case $yn in
    [Yy]*) return 0 ;;
    [Nn]*) return 1 ;;
    *) echo "Please answer yes or no." ;;
    esac
  done
}

configureSsh() {
  local SERVICE=$1
  local IP=$2
  local PORT=$3

  # TODO: create ssh config file if it does not exist
  if [ ! -f "$GLOBAL_SSH_CONFIG" ]; then
    echo "SSH config file $GLOBAL_SSH_CONFIG does not exist, please create it." >/dev/stderr
    exit 1
  fi

  local IP_AND_PORT=$(awk -v name="dev-cloud-$SERVICE" -f $BASEDIR/awk/check.awk "$GLOBAL_SSH_CONFIG")

  if [ $IP_AND_PORT == "" ]; then
    echo "failed to find the service host IP address, file $GLOBAL_SSH_CONFIG may be corrupted" >/dev/stderr
    exit 1
  fi

  if [ $IP_AND_PORT == "NA" ]; then
    if ! yesOrNo "the service host is not in the SSH config file, it will be added, proceed?"; then
      echo "Aborted"
      exit 1
    fi
    addServiceHostIp $SERVICE $IP $PORT
    return 0
  fi

  if [ "$IP_AND_PORT" == "$IP:$PORT" ]; then
    return 0 # IP and Port have not changed
  fi

  if ! yesOrNo "the service IP:Port found in the SSH config file is '$IP_AND_PORT', but need to be '$IP:$PORT', the config file will be updated, proceed?"; then
    echo "Aborted"
    exit 1
  fi

  if ! awk -i inplace -v inplace::suffix=.bak -v name="dev-cloud-$SERVICE" -v ip="$IP" -v port="$PORT" -f $BASEDIR/awk/replace.awk "$GLOBAL_SSH_CONFIG"; then
    echo "failed to update host IP address, file $GLOBAL_SSH_CONFIG may be corrupted" >/dev/stderr
    exit 1
  fi
}

addServiceHostIp() {
  local SERVICE=$1
  local IP=$2
  local PORT=$3
  echo >>"$GLOBAL_SSH_CONFIG"
  echo "Host dev-cloud-$SERVICE" >>"$GLOBAL_SSH_CONFIG"
  echo "  HostName $IP" >>"$GLOBAL_SSH_CONFIG"
  echo "  Port $PORT" >>"$GLOBAL_SSH_CONFIG"
  echo "  User root" >>"$GLOBAL_SSH_CONFIG"
  echo "host IP address added"
}
