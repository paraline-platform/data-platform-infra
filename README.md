# data-platform-infra

Kubernetes infrastructure for the Data Lakehouse Platform — Helm charts, Helmfile releases, manifests, and GitOps config.

## Structure

```
platform/
  charts/          # Custom Helm charts (debezium, kafka-cluster, hive-metastore, spark-thrift-server)
  environments/    # Per-env values: stg / uat / prd
  manifests/       # K8s raw manifests (namespaces, RBAC, storage classes)
  spark-profiles/  # Spark resource profiles per env
  values/          # Helm values: base/ + env/ overrides
  helmfile.yaml.gotmpl
  kind-cluster-config.yaml
scripts/
  setup.sh         # Bootstrap: create Kind cluster + apply namespaces + helmfile repos
  deploy.sh        # Deploy: helmfile -e <env> [component]
architecture/      # Architecture diagrams
argocd/            # Argo CD Application manifests (Phase 4)
```

## Quick Start (local dev with Kind)

```bash
# 1. Create cluster + base infra
./scripts/setup.sh

# 2. Deploy all components (dev env)
./scripts/deploy.sh dev

# 3. Deploy specific component
./scripts/deploy.sh dev 06-orchestration
```

## Environments

| Env  | Description |
|------|-------------|
| dev  | Local Kind cluster, small resources, dev passwords |
| uat  | Staging, useExistingSecret, mirrored prod config |
| prod | Production, all secrets via K8s Secrets / Vault |

## Components (Helmfile releases)

NiFi · Kafka (Strimzi) · MinIO · Nessie · Spark Operator · Spark Thrift Server · Airflow · Debezium · DataHub · Argo CD
