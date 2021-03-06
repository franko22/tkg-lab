#!/bin/bash -e

TKG_LAB_SCRIPTS="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source $TKG_LAB_SCRIPTS/set-env.sh

IAAS=$(yq e .iaas $PARAMS_YAML)
VSPHERE_CONTROLPLANE_ENDPOINT=$3
export KUBERNETES_VERSION=$4

export CLUSTER_NAME=$1
export WORKER_REPLICAS=$2

if [ "$IAAS" = "aws" ];
then
  
  MANAGEMENT_CLUSTER_NAME=$(yq e .management-cluster.name $PARAMS_YAML)
  kubectl config use-context $MANAGEMENT_CLUSTER_NAME-admin@$MANAGEMENT_CLUSTER_NAME

  mkdir -p generated/$CLUSTER_NAME

  cp config-templates/aws-workload-cluster-config.yaml generated/$CLUSTER_NAME/cluster-config.yaml

  export AWS_VPC_ID=$(kubectl get awscluster $MANAGEMENT_CLUSTER_NAME -n tkg-system -ojsonpath="{.spec.networkSpec.vpc.id}")
  export AWS_PUBLIC_SUBNET_ID=$(kubectl get awscluster $MANAGEMENT_CLUSTER_NAME -n tkg-system -ojsonpath="{.spec.networkSpec.subnets[?(@.isPublic==true)].id}")
  export AWS_PRIVATE_SUBNET_ID=$(kubectl get awscluster $MANAGEMENT_CLUSTER_NAME -n tkg-system -ojsonpath="{.spec.networkSpec.subnets[?(@.isPublic==false)].id}")
  export REGION=$(yq e .aws.region $PARAMS_YAML)
  export AWS_SSH_KEY_NAME=tkg-$(yq e .environment-name $PARAMS_YAML)-default

  yq e -i '.AWS_VPC_ID = env(AWS_VPC_ID)' generated/$CLUSTER_NAME/cluster-config.yaml
  yq e -i '.AWS_PUBLIC_SUBNET_ID = env(AWS_PUBLIC_SUBNET_ID)' generated/$CLUSTER_NAME/cluster-config.yaml
  yq e -i '.AWS_PRIVATE_SUBNET_ID = env(AWS_PRIVATE_SUBNET_ID)' generated/$CLUSTER_NAME/cluster-config.yaml
  yq e -i '.CLUSTER_NAME = env(CLUSTER_NAME)' generated/$CLUSTER_NAME/cluster-config.yaml
  yq e -i '.AWS_REGION = env(REGION)' generated/$CLUSTER_NAME/cluster-config.yaml
  yq e -i '.AWS_SSH_KEY_NAME = env(AWS_SSH_KEY_NAME)' generated/$CLUSTER_NAME/cluster-config.yaml
  yq e -i '.WORKER_MACHINE_COUNT = env(WORKER_REPLICAS)' generated/$CLUSTER_NAME/cluster-config.yaml

  if [ ! "$KUBERNETES_VERSION" = "null" ]; then
    yq e -i '.KUBERNETES_VERSION = env(KUBERNETES_VERSION)' generated/$CLUSTER_NAME/cluster-config.yaml
  fi
    
  tanzu cluster create --file=generated/$CLUSTER_NAME/cluster-config.yaml -v 6

  # The following additional step is required when deploying workload clusters to the same VPC as the management cluster in order for LoadBalancers to be created properly
  aws ec2 create-tags --resources $AWS_PUBLIC_SUBNET_ID --tags Key=kubernetes.io/cluster/$CLUSTER_NAME,Value=shared
elif [ "$IAAS" == "azure" ];
then
  tkg create cluster $CLUSTER_NAME \
    --enable-cluster-options oidc \
    --plan dev \
    $KUBERNETES_VERSION_FLAG_AND_VALUE \
    -w $WORKER_REPLICAS -v 6  
else
  tkg create cluster $CLUSTER_NAME \
    --enable-cluster-options oidc \
    --plan dev \
    $KUBERNETES_VERSION_FLAG_AND_VALUE \
    --vsphere-controlplane-endpoint $VSPHERE_CONTROLPLANE_ENDPOINT \
    -w $WORKER_REPLICAS -v 6
fi

# No need to patch the workload-cluster-pinniped-addon secret on the managent cluster and wait for it to reconcile
# This is a hack becasue the tanzu cli does not properly create that secret with the right CA for pinniped from pinniped-info secret
mkdir -p generated/$CLUSTER_NAME/pinniped
kubectl get secret $CLUSTER_NAME-pinniped-addon -n default -ojsonpath="{.data.values\.yaml}" | base64 --decode > generated/$CLUSTER_NAME/pinniped/pinniped-addon-values.yaml
export CA_BUNDLE=`cat keys/letsencrypt-ca.pem | base64`

yq e -i '.pinniped.supervisor_ca_bundle_data = env(CA_BUNDLE)' generated/$CLUSTER_NAME/pinniped/pinniped-addon-values.yaml

add_yaml_doc_seperator generated/$CLUSTER_NAME/pinniped/pinniped-addon-values.yaml

kubectl create secret generic $CLUSTER_NAME-pinniped-addon --from-file=values.yaml=generated/$CLUSTER_NAME/pinniped/pinniped-addon-values.yaml -n default -o yaml --type=tkg.tanzu.vmware.com/addon --dry-run=client | kubectl apply -f-
kubectl annotate secret $CLUSTER_NAME-pinniped-addon --overwrite -n default tkg.tanzu.vmware.com/addon-type=authentication/pinniped
kubectl label secret $CLUSTER_NAME-pinniped-addon --overwrite=true -n default tkg.tanzu.vmware.com/addon-name=pinniped
kubectl label secret $CLUSTER_NAME-pinniped-addon --overwrite=true -n default tkg.tanzu.vmware.com/cluster-name=$CLUSTER_NAME

# NOTE: You won't be able to login successfully for another 10 minutes or so, as you wait for the addon manager on mangement cluster to reconcile and update the
# pinniped-addon secret on the workload cluster.  I have not put a wait step in here so that we don't cause a blocking activity, as you can certainly use the admin
# credentials to work with the cluster.  You will know that the addon has reconciled if you do `kubectl get jobs -A` and you see that the pinniped-post-deploy job has version 2.

tanzu cluster kubeconfig get $CLUSTER_NAME --admin

kubectl config use-context $CLUSTER_NAME-admin@$CLUSTER_NAME

kubectl apply -f tkg-extensions-mods-examples/tanzu-kapp-namespace.yaml
