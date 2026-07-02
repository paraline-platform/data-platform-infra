# P2 — Tối ưu code (1–2 tuần, song song được với P1)

> **Điều kiện tiên quyết:** P0. Các mục trong P2 độc lập nhau — làm theo thứ tự nào cũng được, thứ tự dưới đây xếp theo tác động.

---

## P2.1 — `run-dbt.sh`: dùng image GHCR thay pip-install runtime

### Chưa tối ưu chỗ nào?
`data-platform-processing/scripts/run-dbt.sh` hiện:
1. Parse YAML bằng `grep -A3` (dòng 57–58) — vỡ khi ai đó thêm comment/đổi thứ tự key.
2. Tạo ConfigMap bằng cách **liệt kê cứng từng file model** (dòng 104–113) — thêm 1 model mới là phải sửa script. Dấu hiệu "không dynamic" rõ nhất toàn codebase.
3. `pip install dbt` mỗi lần chạy trong `python:3.11-slim` — chậm 2–3 phút, không reproducible.
4. Mỉa mai nhất: **CI đã build sẵn dbt image lên GHCR (`docker/dbt/Dockerfile` COPY sẵn project) nhưng không nơi nào dùng nó.**

### Tại sao cách mới tối ưu hơn?
- Image được CI build + validate đúng version **một lần**; Job chỉ chạy — startup từ ~3 phút còn ~10 giây.
- "Thêm model mới" thành thao tác zero-touch với hạ tầng (model nằm trong image, không trong tay script).
- Reproducible: chạy lại image tag cũ = chạy lại đúng code + đúng dependencies cũ.

### Các bước

**Bước 1.** Sửa `dbt/profiles.yml` — commit vào repo, đọc config qua env vars (không còn generate bằng script):

```yaml
# dbt/profiles.yml — an toàn commit vì không chứa secret, mọi thứ env-specific qua env_var
data_platform:
  target: "{{ env_var('DBT_TARGET', 'dev') }}"
  outputs:
    dev: &spark_output
      type: spark
      method: thrift
      host: "{{ env_var('DBT_THRIFT_HOST', 'spark-thrift-server.data-modeling.svc.cluster.local') }}"
      port: 10000
      schema: "{{ env_var('DBT_SCHEMA', 'dbt_dev') }}"
      threads: "{{ env_var('DBT_THREADS', '1') | as_number }}"
      connect_retries: 5
      connect_timeout: 60
      retry_all: true
    uat:  { <<: *spark_output }
    prod: { <<: *spark_output }
```

**Bước 2.** Cập nhật `docker/dbt/Dockerfile` COPY luôn profiles:

```dockerfile
FROM python:3.11-slim
WORKDIR /dbt
RUN pip install --no-cache-dir "dbt-core>=1.8.0,<2.0.0" "dbt-spark[PyHive]>=1.8.0,<2.0.0"
COPY dbt/ .
ENV DBT_PROFILES_DIR=/dbt
ENTRYPOINT ["dbt"]
```

**Bước 3.** Viết lại `run-dbt.sh` (~40 dòng thay vì 263) — render Job bằng heredoc, image từ GHCR:

```bash
#!/usr/bin/env bash
set -euo pipefail
ENV=${1:?usage: run-dbt.sh <env> [command] [dbt-opts...]}
COMMAND=${2:-run}; shift 2 || true
IMAGE="${DBT_IMAGE:-ghcr.io/paraline-platform/dbt:latest-stg}"   # sau P3.7: bắt buộc sha tag
JOB_NAME="dbt-${COMMAND}-$(date +%s)"
NAMESPACE="data-modeling"

# env → schema/threads: 1 map nhỏ tại đây (hoặc kubectl get cm nếu muốn 1 nguồn duy nhất)
case "$ENV" in
  dev)  SCHEMA=dbt_dev;  THREADS=1 ;;
  uat)  SCHEMA=dbt_uat;  THREADS=2 ;;
  prod) SCHEMA=dbt_prod; THREADS=4 ;;
  *) echo "env không hợp lệ: $ENV"; exit 1 ;;
esac

kubectl apply -f - <<MANIFEST
apiVersion: batch/v1
kind: Job
metadata: { name: ${JOB_NAME}, namespace: ${NAMESPACE}, labels: { app: dbt, env: "${ENV}" } }
spec:
  ttlSecondsAfterFinished: 300
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: dbt
          image: ${IMAGE}
          args: ["${COMMAND}", "--target", "${ENV}", $(printf '"%s", ' "$@" | sed 's/, $//')]
          env:
            - { name: DBT_TARGET,  value: "${ENV}" }
            - { name: DBT_SCHEMA,  value: "${SCHEMA}" }
            - { name: DBT_THREADS, value: "${THREADS}" }
          resources:
            requests: { cpu: "200m", memory: "512Mi" }
            limits:   { cpu: "500m", memory: "1Gi" }
MANIFEST

kubectl wait --for=condition=ready pod -l job-name=${JOB_NAME} -n ${NAMESPACE} --timeout=120s || true
kubectl logs -n ${NAMESPACE} -l job-name=${JOB_NAME} -f || true
kubectl wait --for=condition=complete job/${JOB_NAME} -n ${NAMESPACE} --timeout=600s \
  && echo "✓ dbt ${COMMAND} SUCCEEDED" \
  || { echo "✗ dbt ${COMMAND} FAILED"; exit 1; }
```

> **Lưu ý image pull từ GHCR:** nếu package private, tạo `imagePullSecrets` trong namespace `data-modeling` (`kubectl create secret docker-registry ghcr-pull --docker-server=ghcr.io ...`) hoặc set package thành public.
> Sau P3, Job dbt sẽ do Airflow/Argo quản — script này chỉ còn là tiện ích dev.

### Verify
```bash
./scripts/run-dbt.sh dev debug    # kết nối Thrift OK, không còn bước pip install trong log
./scripts/run-dbt.sh dev run      # models chạy như trước
```

---

## P2.2 — Custom Spark image có sẵn Iceberg/S3A JARs

### Chưa tối ưu chỗ nào?
`spark-jobs/iceberg-test.yaml` dùng initContainer tải **6 JARs từ internet mỗi lần chạy** (~50MB). Chậm, phụ thuộc Maven Central sống, không air-gap được. Comment trong DAG 04 tự thú nhận: *"Spark chưa có S3A JARs đầy đủ trong dev (cần custom image)"*.

### Các bước

**Bước 1.** Tạo `data-platform-processing/docker/spark/Dockerfile`:

```dockerfile
FROM apache/spark:3.5.3

# JARs bake vào /opt/spark/jars → classpath mặc định, không cần spark.jars config
ARG ICEBERG_VER=1.6.1
ARG HADOOP_AWS_VER=3.3.4
ARG AWS_SDK_VER=1.12.587

USER root
RUN set -ex; cd /opt/spark/jars && \
    curl -fsSLO "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-3.5_2.12/${ICEBERG_VER}/iceberg-spark-runtime-3.5_2.12-${ICEBERG_VER}.jar" && \
    curl -fsSLO "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VER}/hadoop-aws-${HADOOP_AWS_VER}.jar" && \
    curl -fsSLO "https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/${AWS_SDK_VER}/aws-java-sdk-bundle-${AWS_SDK_VER}.jar"
USER spark
```

> `aws-java-sdk-bundle` (1 JAR) thay cho 4 JAR sdk lẻ (s3/core/sts/dynamodb) — chính là dependency mà hadoop-aws khai báo chính thức.

**Bước 2.** Thêm job build vào `.github/workflows/ci.yml` của processing (copy pattern job `build-dbt-image`, đổi context/file → `docker/spark/Dockerfile`, image → `ghcr.io/paraline-platform/spark`).

**Bước 3.** Trong các spark-jobs YAML: đổi `image: apache/spark:3.5.3` → `ghcr.io/paraline-platform/spark:<tag>`; **xoá** initContainer setup JARs + volume workdir + key `spark.jars` (JARs đã ở classpath mặc định). Spec ngắn đi ~2/3.

**Bước 4.** Creds S3A không hardcode nữa (gộp với P1): xoá `fs.s3a.access.key/secret.key` khỏi sparkConf, thay bằng env từ Secret trong driver/executor spec:

```yaml
driver:
  envFrom:
    - secretRef: { name: minio-credentials }   # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
executor:
  envFrom:
    - secretRef: { name: minio-credentials }
# S3A tự đọc AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY qua EnvironmentVariableCredentialsProvider
```

### Verify
```bash
./scripts/run-spark-job.sh dev small iceberg-test        # job xanh, không còn initContainer download
kubectl logs -n data-processing iceberg-hms-test-driver | grep -i "snapshot"   # Iceberg hoạt động
```

---

## P2.3 — Refactor `make_spark_submit_task` → `SparkKubernetesOperator` trực tiếp

### Chưa tối ưu chỗ nào?
`dags/spark_profiles.py:206-249` bọc `SparkKubernetesOperator` trong `PythonOperator` rồi tự gọi `op.execute(context)`. Hậu quả:
- **`on_kill` không hoạt động** → bấm kill task trên UI **không kill Spark job** — rò rỉ tài nguyên thật trên cluster.
- Mất retry semantics per-operator, mất deferrable mode, UI hiển thị sai loại task, log link không chuẩn.
- Operator không được Airflow quản lý vòng đời — mọi tính năng tương lai của provider đều bị chặn.

### Cách sửa
`application_file` là **template field** — render Jinja được, nên profile chọn lúc trigger (nằm trong `params`) dùng thẳng trong template, không cần PythonOperator trung gian.

**Bước 1.** Tạo `dags/specs/pipeline-etl.yaml.j2`:

```yaml
{% set profiles = var.json.get('spark_profiles', {}) %}
{% set p = profiles.get(params.spark_profile, profiles.get('small', {})) %}
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: pipeline-etl-{{ ts_nodash | lower }}
  namespace: data-processing
spec:
  type: Scala
  mode: cluster
  image: ghcr.io/paraline-platform/spark:{{ var.value.get('spark_image_tag', 'latest-stg') }}
  mainClass: org.apache.spark.examples.SparkPi
  mainApplicationFile: local:///opt/spark/examples/jars/spark-examples_2.12-3.5.3.jar
  arguments: ["10"]
  sparkVersion: "3.5.3"
  restartPolicy: { type: Never }
  driver:
    serviceAccount: spark-operator-spark
    labels: { trigger: airflow }
    cores: {{ p.driver.cores | default(1) }}
    coreLimit: "{{ p.driver.coreLimit | default('1') }}"
    memory: "{{ p.driver.memory | default('512m') }}"
  executor:
    labels: { trigger: airflow }
    instances: {{ p.executor.instances | default(1) }}
    cores: {{ p.executor.cores | default(1) }}
    memory: "{{ p.executor.memory | default('512m') }}"
```

**Bước 2.** Trong DAG:

```python
from airflow.providers.cncf.kubernetes.operators.spark_kubernetes import SparkKubernetesOperator

submit = SparkKubernetesOperator(
    task_id="submit_spark",
    namespace="data-processing",
    application_file="specs/pipeline-etl.yaml.j2",   # relative với dags folder
    kubernetes_conn_id="kubernetes_default",
    do_xcom_push=False,
)
```

**Bước 3.** Xoá `make_spark_submit_task` + `build_spark_spec` + `SparkJobConfig.base_spec()` khỏi `spark_profiles.py`. Giữ `spark_profile_param()` cho dropdown UI — nhưng sửa nó đọc mô tả từ Variable nếu có, fallback chỉ còn **danh sách tên profile** (không kèm số liệu cứng, tránh UI nói dối khi Variable và fallback lệch nhau):

```python
def spark_profile_param(default: str = "small"):
    from airflow.models.param import Param
    return Param(default, enum=VALID_PROFILES,
                 description="Resource profiles — xem giá trị thật: Admin → Variables → spark_profiles")
```

### Tại sao chọn Jinja template thay vì giữ dataclass builder?
Cả hai đều "dynamic". Khác biệt quyết định: template đưa spec cho **operator thật** quản → giữ nguyên on_kill/retry/deferrable. Dataclass builder chỉ đáng giữ nếu có hàng chục job cùng khuôn — lúc đó cho nó **sinh ra file .j2**, chứ không bao giờ bọc operator trong PythonOperator.

### Verify
- Trigger DAG với `spark_profile=medium` → driver pod có đúng 2 cores/1g.
- **Bấm "Mark Failed"/clear task đang chạy trên UI → SparkApplication bị xoá theo** (điều mà code cũ không làm được).

---

## P2.4 — `spark_profiles.py` ra khỏi tầm quét DAG parser

### Vấn đề
File nằm trong `dags/` → scheduler parse nó **mỗi vòng** như một DAG file (tốn CPU parse, dù không có DAG bên trong).

### Cách sửa
```
dags/
  lib/
    __init__.py
    spark_profiles.py     # chuyển vào đây
  specs/
    pipeline-etl.yaml.j2
  01_hello_airflow.py
  ...
.airflowignore            # tạo ở dags/ root
```

```
# dags/.airflowignore
lib/
specs/
```

Import trong DAG đổi thành `from lib.spark_profiles import spark_profile_param`.

---

## P2.5 — Một chiến lược deploy DAG duy nhất: gitSync

### Chưa tối ưu chỗ nào?
**3 chiến lược tồn tại song song**: `kubectl cp` vào PVC (dev — `deploy-dags.sh`), gitSync (prod config — trỏ vào repo placeholder `your-org/data-platform-dags` **không tồn tại**), bake vào image (`docker/Dockerfile`). Ba cơ chế = ba hành vi khác nhau giữa env = bug chỉ xuất hiện ở prod.

### Lựa chọn

| Chiến lược | Ưu | Nhược |
|---|---|---|
| **gitSync từ repo airflow** ✅ | Vòng lặp dev vài chục giây (push → tự sync); mọi env cùng cơ chế; không rebuild image khi đổi DAG | DAG trên cluster = HEAD của branch (cần branch protection) |
| Bake vào image | Immutable tuyệt đối | Mỗi thay đổi DAG = build + rollout 5–10 phút; với team nhỏ chi phí này không mua được gì đáng kể |
| kubectl cp + PVC | Không có — chỉ là workaround dev | Imperative, lệch env, kéo theo bài toán RWX/EFS cho prod |

**Quyết định:** gitSync cho **mọi env**, cùng repo `data-platform-airflow`, khác branch/tag theo env. Image Airflow chỉ còn rebuild khi đổi **dependencies** (providers) — xoá dòng `COPY dags/` khỏi Dockerfile.

### Các bước

**Bước 1.** `environments/_defaults.yaml` (P1.4):

```yaml
airflow:
  gitSync:
    enabled: true
    repo: "https://github.com/tungnt763/data-platform-airflow.git"
    branch: stg          # dev theo stg; uat.yaml → uat; prod.yaml → prd (sau P4: main + tag)
    period: "60s"
    subPath: "dags"
```

**Bước 2.** Repo private → tạo credentials cho gitSync (deploy key read-only là đủ):

```bash
ssh-keygen -t ed25519 -f gitsync-key -N ""
# Public key → GitHub repo airflow → Settings → Deploy keys (read-only)
kubectl create secret generic airflow-gitsync -n data-orchestration \
  --from-file=gitSshKey=gitsync-key
# values gotmpl: dags.gitSync.sshKeySecret: airflow-gitsync + repo dạng git@github.com:...
```

**Bước 3.** Xoá `dags.persistence` values (gitSync thay PVC), xoá `scripts/deploy-dags.sh`, cập nhật README airflow.

### Verify
Push 1 DAG mới lên `stg` → xuất hiện trong UI trong ≤ ~90s không cần chạy script gì.

---

## P2.6 — CI: DAG import test bằng DagBag

### Vấn đề
`py_compile` chỉ bắt lỗi syntax — không bắt lỗi import provider, DAG cycle, tham số operator sai, top-level code chậm.

### Cách sửa
Tạo `data-platform-airflow/tests/test_dag_integrity.py`:

```python
import warnings
from airflow.models import DagBag

def test_no_import_errors():
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        bag = DagBag(dag_folder="dags", include_examples=False)
    assert bag.import_errors == {}, f"DAG import errors: {bag.import_errors}"

def test_dags_have_required_settings():
    bag = DagBag(dag_folder="dags", include_examples=False)
    for dag_id, dag in bag.dags.items():
        assert dag.catchup is False, f"{dag_id}: catchup phải False (tránh backfill vô tình)"
        assert dag.tags, f"{dag_id}: thiếu tags"
```

CI (`ci.yml` airflow — thay step Syntax check):

```yaml
      - name: DAG integrity tests
        run: |
          pip install pytest
          AIRFLOW__CORE__LOAD_EXAMPLES=False pytest tests/ -v
```

---

## P2.7 — CI hardening chung (cả 3 repo)

**Concurrency** — PR push liên tục không xếp hàng build (thêm đầu mỗi workflow):

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

**Trivy scan** — sau step build, trước push:

```yaml
      - name: Trivy scan
        uses: aquasecurity/trivy-action@0.28.0
        with:
          image-ref: ${{ env.IMAGE_NAME }}:${{ github.sha }}
          severity: HIGH,CRITICAL
          exit-code: "1"
          ignore-unfixed: true
```

**Pin actions bằng SHA** (chống supply-chain tampering):

```yaml
# TRƯỚC: uses: actions/checkout@v4
# SAU:   uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
# Tra SHA: gh api repos/actions/checkout/git/ref/tags/v4.2.2 --jq .object.sha
# Bật Dependabot cho github-actions để tự bump: .github/dependabot.yml
```

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
```

**Permissions mặc định tối thiểu** (đầu mỗi workflow):

```yaml
permissions:
  contents: read
```

## P2.8 — sqlfluff cho dbt

```yaml
# processing ci.yml — thêm vào job dbt-parse:
      - name: SQL lint
        run: |
          pip install sqlfluff sqlfluff-templater-dbt
          sqlfluff lint dbt/models --dialect sparksql
```

Tạo `.sqlfluff` ở root processing:

```ini
[sqlfluff]
dialect = sparksql
templater = jinja
max_line_length = 120
```

## P2.9 — Reusable workflow build-image

### Vấn đề
Job build-image của airflow ci.yml và processing ci.yml giống nhau ~90%; `sync-branches.yml` giống nhau 100% ở cả 3 repo (5765 bytes nguyên văn).

### Cách sửa
Tạo repo `paraline-platform/.github` (hoặc dùng repo infra), file `.github/workflows/build-image.yml`:

```yaml
name: Build Image (reusable)
on:
  workflow_call:
    inputs:
      image-name: { required: true, type: string }
      dockerfile: { required: true, type: string }
      context:    { required: false, type: string, default: "." }

jobs:
  build:
    runs-on: ubuntu-latest
    permissions: { contents: read, packages: write }
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        if: github.event_name == 'push'
        with: { registry: ghcr.io, username: "${{ github.actor }}", password: "${{ secrets.GITHUB_TOKEN }}" }
      - uses: docker/metadata-action@v5
        id: meta
        with:
          images: ${{ inputs.image-name }}
          tags: type=sha,prefix=${{ github.ref_name }}-,format=short
      - uses: docker/build-push-action@v6
        with:
          context: ${{ inputs.context }}
          file: ${{ inputs.dockerfile }}
          push: ${{ github.event_name == 'push' }}
          tags: ${{ steps.meta.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

Repo con gọi:

```yaml
jobs:
  build-image:
    needs: lint-dags
    uses: paraline-platform/.github/.github/workflows/build-image.yml@main
    with:
      image-name: ghcr.io/paraline-platform/airflow
      dockerfile: docker/Dockerfile
```

Tại sao: sửa một chỗ, hiệu lực mọi repo — DRY thật sự cho CI. `sync-branches.yml` cũng gom tương tự **nếu** còn giữ mô hình branch (sau P4 thì xoá hẳn).

---

## Definition of Done — P2

- [ ] `run-dbt.sh` không còn pip install; dbt Job start ≤ 15s
- [ ] Spark jobs không còn initContainer download JARs; không còn S3A creds trong YAML
- [ ] Kill task Spark trên Airflow UI → SparkApplication bị xoá theo
- [ ] Push DAG lên stg → xuất hiện trên UI ≤ 90s, không chạy script
- [ ] CI airflow chạy DagBag test; CI cả 3 repo có Trivy + concurrency + permissions tối thiểu
- [ ] Chỉ còn 1 bản định nghĩa build-image cho cả org
