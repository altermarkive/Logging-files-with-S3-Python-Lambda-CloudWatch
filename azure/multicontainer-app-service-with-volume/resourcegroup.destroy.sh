#!/bin/sh

set -e

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 PREFIX LOCATION"
    exit 1
else
    PREFIX=$1
    LOCATION=$2
fi

export RESOURCE_GROUP=${PREFIX}rg

# Destroy resource group
RESOURCE_GROUP_EXISTS=$(az group exists --name $RESOURCE_GROUP)
if [ "$RESOURCE_GROUP_EXISTS" = "true" ]; then
  az group delete --name $RESOURCE_GROUP -y
fi
