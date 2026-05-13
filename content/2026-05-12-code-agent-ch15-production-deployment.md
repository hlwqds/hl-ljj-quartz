---
title: "Code Agent Ch15: 生产环境部署"
date: "2026-05-12"
tags: ["Code Agent", "生产部署", "Kubernetes", "云原生", "gsd2"]
description: "深入探讨 Code Agent 生产环境部署的架构设计、容器化方案、高可用设计、成本优化与可观测性实践，以 gsd2 项目为案例。"
---

# Code Agent Ch15: 生产环境部署

## 1. 部署架构概述

### 1.1 单体架构 vs 微服务架构

在设计 Code Agent 部署架构时，首先需要根据业务规模、团队结构和迭代速度做出关键的架构决策。单体架构将所有功能模块打包在单一进程中，部署简单、调试方便，但扩展性受限；微服务架构将功能拆分为独立服务，各服务可独立部署和扩展，但增加了运维复杂度。

```mermaid
graph TB
    subgraph "单体架构"
        A1["API Gateway"]
        A2["Code Agent Core<br/>(所有模块)"]
        A3["Database"]
        A1 --> A2 --> A3
    end
    
    subgraph "微服务架构"
        B1["API Gateway"]
        B2["Planning Agent"]
        B3["Execution Agent"]
        B4["Memory Service"]
        B5["Tool Registry"]
        B6["PostgreSQL"]
        B7["Redis"]
        B1 --> B2
        B1 --> B3
        B2 --> B4
        B3 --> B4
        B2 --> B5
        B3 --> B5
        B4 --> B6
        B4 --> B7
    end
```

**架构选择对照表：**

| 维度 | 单体架构 | 微服务架构 |
|------|---------|-----------|
| 部署复杂度 | 低 | 中高 |
| 扩展性 | 垂直扩展为主 | 水平扩展 |
| 故障隔离 | 差 | 好 |
| 技术栈灵活性 | 低 | 高 |
| 团队规模适配 | <10人 | >10人 |
| 调试难度 | 低 | 高 |
| 资源利用率 | 较低 | 较高 |
| 交付速度 | 慢（全量部署） | 快（增量部署） |

### 1.2 部署模式选择

根据业务连续性需求和运维能力，生产环境部署通常有以下模式：

**蓝色-green部署（Blue-Green Deployment）**：保持两套完全相同的生产环境（蓝环境和绿环境），新版本部署到非活跃环境，经过验证后切换流量。这种方式可以实现秒级回滚，但资源成本翻倍。

**金丝雀发布（Canary Release）**：先将新版本部署给小部分用户，验证稳定性后再全量发布。适合风险较高的重大更新，可以有效控制影响范围。

**滚动更新（Rolling Update）**：逐批替换实例，过程中始终有实例在服务。资源利用率高，但回滚时间较长。

**特性开关（Feature Flag）**：通过配置开关控制功能启用/禁用，无需重新部署即可切换功能状态。适合 A/B 测试和快速禁用问题功能。

```mermaid
graph LR
    subgraph "部署流程"
        direction TB
        A[代码提交] --> B[构建镜像]
        B --> C{部署策略}
        C -->|Blue-Green| D[部署到 Idle 环境]
        C -->|Canary| E[1% 流量验证]
        C -->|Rolling| F[逐批更新]
        D --> G[切换流量]
        E --> H{验证通过?}
        H -->|是| I[全量发布]
        H -->|否| J[回滚]
        F --> K[完成更新]
    end
```

对于 gsd2 这类 Code Agent 项目，考虑到推理服务的资源密集型特性，推荐采用**混合策略**：核心调度服务使用蓝绿部署确保高可用，推理 worker 使用金丝雀发布配合自动扩缩容。

### 1.3 gsd2 部署架构设计

gsd2 项目采用分层架构，包含规划层、执行层和记忆层。生产部署时，我们将其拆分为三个独立部署单元：

```mermaid
graph TB
    subgraph "gsd2 部署架构"
        subgraph "接入层"
            LB["负载均衡器<br/>(AWS ALB)"]
            CDN["CDN<br/>(CloudFront)"]
        end
        
        subgraph "网关层"
            GW["API Gateway<br/>(Kong/Nginx)"]
        end
        
        subgraph "核心服务层"
            PL["Planning Service<br/>x3 副本"]
            EX["Execution Service<br/>x5 副本"]
            MM["Memory Service<br/>x2 副本"]
        end
        
        subgraph "推理层"
            GW2["Worker Gateway"]
            W1["Worker 1<br/>(A100)"]
            W2["Worker 2<br/>(A100)"]
            W3["Worker N<br/>(A100)"]
        end
        
        subgraph "数据层"
            PG["PostgreSQL<br/>(主从)"]
            RD["Redis Cluster"]
            S3["Object Storage"]
        end
        
        CDN --> LB
        LB --> GW
        GW --> PL
        GW --> EX
        PL --> MM
        EX --> MM
        EX --> GW2
        GW2 --> W1
        GW2 --> W2
        GW2 --> W3
        MM --> PG
        MM --> RD
        PL --> S3
        EX --> S3
    end
```

这种架构设计的关键考量：

- **规划服务（Planning Service）**：CPU 密集型，主要处理任务分解和流程编排，需要较高主频
- **执行服务（Execution Service）**：混合型，兼顾协调和轻量计算
- **推理 Worker**：GPU 密集型，独立部署以实现资源的弹性伸缩
- **记忆服务（Memory Service）**：内存密集型，需要高速缓存和持久存储的配合

## 2. 容器化部署

### 2.1 Docker 镜像构建

Code Agent 的 Docker 镜像构建需要考虑多阶段构建以减小镜像体积，同时确保运行时性能。以下是 gsd2 各服务的 Dockerfile 示例：

```dockerfile
# Dockerfile.planning-service
# 语法版本
FROM python:3.11-slim as builder

# 安装构建依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# 创建虚拟环境
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# 安装依赖
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 生产镜像
FROM python:3.11-slim

# 安装运行时依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# 从构建阶段复制虚拟环境
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# 设置工作目录
WORKDIR /app

# 复制应用代码
COPY src/ ./src/
COPY config/ ./config/

# 设置非 root 用户
RUN useradd -m -u 1000 agent && chown -R agent:agent /app
USER agent

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# 环境变量
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV SERVICE_NAME=planning-service

EXPOSE 8000

CMD ["python", "-m", "src.planning_service"]
```

```dockerfile
# Dockerfile.inference-worker
FROM nvidia/cuda:12.1.0-runtime-ubuntu22.04 as base

FROM base as builder

# 安装构建工具和 Python
RUN apt-get update && apt-get install -y \
    build-essential \
    python3.11 \
    python3.11-dev \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# 创建虚拟环境
RUN python3.11 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# 安装 PyTorch 和 transformers
RUN pip install --no-cache-dir \
    torch==2.2.0 \
    transformers==4.36.0 \
    accelerate==0.25.0 \
    bitsandbytes==0.41.0 \
    vllm==0.2.0

# 复制应用代码
WORKDIR /app
COPY src/ ./src/
COPY config/ ./config/

# 生产镜像
FROM base

# 安装运行时依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /app /app

ENV PATH="/opt/venv/bin:$PATH"
WORKDIR /app

RUN useradd -m -u 1000 agent && chown -R agent:agent /app
USER agent

HEALTHCHECK --interval=30s --timeout=30s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

EXPOSE 8000

CMD ["python", "-m", "src.inference_worker"]
```

**镜像优化技巧：**

1. **使用 Distroless 或 Alpine 基础镜像**进一步减小体积
2. **并行构建依赖**通过 pip install 的 `--jobs` 参数
3. **依赖分层缓存**将 requirements.txt 单独复制后安装，再复制代码
4. **使用 BuildKit**开启并行构建和更好的缓存

```bash
# 构建命令
DOCKER_BUILDKIT=1 docker build -t gsd2/planning-service:v1.2.0 -f Dockerfile.planning-service .
DOCKER_BUILDKIT=1 docker build -t gsd2/inference-worker:v1.2.0 -f Dockerfile.inference-worker .
```

### 2.2 Kubernetes 部署配置

Kubernetes 是生产环境容器编排的事实标准。以下是 gsd2 各服务的完整 K8s 配置：

```yaml
# k8s/planning-service-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: planning-service
  namespace: gsd2
  labels:
    app: planning-service
    version: v1
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: planning-service
  template:
    metadata:
      labels:
        app: planning-service
        version: v1
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: planning-service-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
        - name: planning-service
          image: gsd2/planning-service:v1.2.0
          imagePullPolicy: Always
          ports:
            - containerPort: 8000
              name: http
          env:
            - name: SERVICE_NAME
              value: "planning-service"
            - name: LOG_LEVEL
              valueFrom:
                configMapKeyRef:
                  name: gsd2-config
                  key: log_level
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: gsd2-secrets
                  key: database-url
            - name: REDIS_URL
              valueFrom:
                secretKeyRef:
                  name: gsd2-secrets
                  key: redis-url
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "2000m"
              memory: "2Gi"
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
          volumeMounts:
            - name: config
              mountPath: /app/config
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: gsd2-config
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app
                      operator: In
                      values:
                        - planning-service
                topologyKey: kubernetes.io/hostname
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: planning-service
```

```yaml
# k8s/inference-worker-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inference-worker
  namespace: gsd2
  labels:
    app: inference-worker
spec:
  replicas: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2
      maxUnavailable: 1
  selector:
    matchLabels:
      app: inference-worker
  template:
    metadata:
      labels:
        app: inference-worker
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
    spec:
      serviceAccountName: inference-worker-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: inference-worker
          image: gsd2/inference-worker:v1.2.0
          imagePullPolicy: Always
          ports:
            - containerPort: 8000
              name: http
          env:
            - name: CUDA_VISIBLE_DEVICES
              valueFrom:
                fieldRef:
                  fieldPath: metadata.annotations['gpus分配的GPU数量']
            - name: MODEL_PATH
              value: /models/code-agent-v1
            - name: MAX_CONCURRENT_REQUESTS
              value: "10"
          resources:
            requests:
              cpu: "4000m"
              memory: "16Gi"
              nvidia.com/gpu: "1"
            limits:
              cpu: "8000m"
              memory: "32Gi"
              nvidia.com/gpu: "1"
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]
          volumeMounts:
            - name: model-cache
              mountPath: /models
      volumes:
        - name: model-cache
          persistentVolumeClaim:
            claimName: model-cache-pvc
      nodeSelector:
        gpu-type: nvidia-a100
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
```

### 2.3 Helm Chart 管理

Helm 是 Kubernetes 的包管理器，可以将复杂的应用配置模板化。以下是 gsd2 的 Helm Chart 结构：

```yaml
# gsd2-chart/values.yaml
# 全局配置
global:
  imageRegistry: registry.example.com
  imagePullSecrets:
    - name: regcred
  storageClass: gp3

# 命名空间配置
namespace: gsd2

# 规划服务配置
planningService:
  enabled: true
  replicaCount: 3
  image:
    repository: gsd2/planning-service
    tag: v1.2.0
    pullPolicy: IfNotPresent
  service:
    type: ClusterIP
    port: 8000
  ingress:
    enabled: true
    className: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
    hosts:
      - host: planning.gsd2.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: planning-service-tls
        hosts:
          - planning.gsd2.example.com
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 10
    targetCPUUtilizationPercentage: 70
    targetMemoryUtilizationPercentage: 80
  persistence:
    enabled: false

# 执行服务配置
executionService:
  enabled: true
  replicaCount: 5
  image:
    repository: gsd2/execution-service
    tag: v1.2.0
  service:
    type: ClusterIP
    port: 8000
  resources:
    requests:
      cpu: 1000m
      memory: 1Gi
    limits:
      cpu: 4000m
      memory: 4Gi
  autoscaling:
    enabled: true
    minReplicas: 5
    maxReplicas: 20
    targetCPUUtilizationPercentage: 70

# 推理 Worker 配置
inferenceWorker:
  enabled: true
  replicaCount: 5
  image:
    repository: gsd2/inference-worker
    tag: v1.2.0
  resources:
    requests:
      cpu: 4000m
      memory: 16Gi
      nvidia.com/gpu: 1
    limits:
      cpu: 8000m
      memory: 32Gi
      nvidia.com/gpu: 1
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 20
    # 基于 GPU 利用率的自动扩缩容
    gpuUtilizationTarget: 80
  nodeSelector:
    gpu-type: nvidia-a100
  tolerations:
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
  persistence:
    enabled: true
    storageClass: gp3
    size: 100Gi

# 记忆服务配置
memoryService:
  enabled: true
  replicaCount: 2
  image:
    repository: gsd2/memory-service
    tag: v1.2.0
  resources:
    requests:
      cpu: 500m
      memory: 4Gi
    limits:
      cpu: 2000m
      memory: 16Gi
  persistence:
    enabled: true
    storageClass: gp3
    size: 50Gi

# PostgreSQL 配置
postgresql:
  enabled: true
  auth:
    username: gsd2
    database: gsd2_prod
  primary:
    persistence:
      enabled: true
      storageClass: gp3
      size: 100Gi
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        cpu: 2000m
        memory: 4Gi
  readReplicas:
    replicaCount: 2
    resources:
      requests:
        cpu: 250m
        memory: 512Mi

# Redis 配置
redis:
  enabled: true
  architecture: replication
  auth:
    enabled: true
    password: ""
  master:
    persistence:
      enabled: true
      storageClass: gp3
      size: 10Gi
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
  replica:
    replicaCount: 2
    persistence:
      enabled: true
      size: 10Gi

# 监控配置
monitoring:
  enabled: true
  prometheus:
    enabled: true
    scrapeInterval: 15s
  grafana:
    enabled: true
    adminPassword: ""

# 日志配置
logging:
  enabled: true
  elasticsearch:
    enabled: true
    volumeClaimSize: 50Gi
  kibana:
    enabled: true

# 配置
config:
  log_level: INFO
  max_concurrent_tasks: 100
  task_timeout_seconds: 300
```

```bash
# Helm 部署命令
# 添加仓库
helm repo add gsd2 https://charts.gsd2.example.com
helm repo update

# 安装 gsd2
helm install gsd2 gsd2/gsd2 \
    --namespace gsd2 \
    --create-namespace \
    --values gsd2-chart/values.yaml \
    --set-file global.jwtSecret=secrets/jwt-secret.txt \
    --set global.imagePullSecrets[0].name=regcred

# 升级
helm upgrade gsd2 gsd2/gsd2 \
    --namespace gsd2 \
    --values gsd2-chart/values.yaml

# 回滚
helm rollback gsd2 1
```

### 2.4 资源规划

生产环境的资源规划需要综合考虑峰值负载、增长预期和成本预算。以下是 gsd2 的资源规划模板：

**容量规划表：**

| 服务 | 实例数 | CPU/实例 | 内存/实例 | GPU/实例 | 存储/实例 | 总 CPU | 总内存 | 总 GPU |
|------|--------|---------|-----------|---------|-----------|--------|--------|--------|
| Planning Service | 3 | 2 cores | 2 GB | - | - | 6 cores | 6 GB | - |
| Execution Service | 5 | 4 cores | 4 GB | - | - | 20 cores | 20 GB | - |
| Inference Worker | 5 | 8 cores | 32 GB | 1xA100 | 100 GB | 40 cores | 160 GB | 5xA100 |
| Memory Service | 2 | 2 cores | 16 GB | - | 50 GB | 4 cores | 32 GB | - |
| PostgreSQL Primary | 1 | 4 cores | 8 GB | - | 100 GB | 4 cores | 8 GB | - |
| PostgreSQL Replica | 2 | 2 cores | 4 GB | - | 100 GB | 4 cores | 8 GB | - |
| Redis Master | 1 | 2 cores | 4 GB | - | 10 GB | 2 cores | 4 GB | - |
| Redis Replica | 2 | 1 core | 2 GB | - | 10 GB | 2 cores | 4 GB | - |

**节点池规划：**

```yaml
# AWS EKS 节点组配置
nodeGroups:
  # CPU 密集型服务节点组
  - name: cpu-node-group
    instanceType: m6i.2xlarge
    desiredCapacity: 5
    minSize: 3
    maxSize: 10
    labels:
      node-type: cpu-optimized
    taints:
      - key: "node-type"
        value: "cpu"
        effect: NoSchedule

  # GPU 节点组
  - name: gpu-node-group
    instanceType: p4d.24xlarge  # 8xA100
    desiredCapacity: 1
    minSize: 0
    maxSize: 3
    labels:
      node-type: gpu
      gpu Manufacturer: nvidia
    taints:
      - key: "nvidia.com/gpu"
        value: "present"
        effect: NoSchedule
    autoscaling:
      - name: gpu-scaling-policy
        targetValue: 70

  # 内存密集型服务节点组
  - name: memory-node-group
    instanceType: r6i.2xlarge
    desiredCapacity: 3
    minSize: 2
    maxSize: 6
    labels:
      node-type: memory-optimized
```

## 3. 云原生架构

### 3.1 自动扩缩容配置

Kubernetes 提供了多种自动扩缩容机制，包括 HPA（Horizontal Pod Autoscaler）、VPA（Vertical Pod Autoscaler）和 CronHPA。以下是 gsd2 的完整自动扩缩容配置：

```yaml
# k8s/hpa-config.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: planning-service-hpa
  namespace: gsd2
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: planning-service
  minReplicas: 3
  maxReplicas: 20
  metrics:
    # CPU 利用率指标
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    # 内存利用率指标
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
    # 自定义指标 - 请求队列长度
    - type: Pods
      pods:
        metric:
          name: http_requests_queued
        target:
          type: AverageValue
          averageValue: "100"
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 10
          periodSeconds: 60
        - type: Pods
          value: 2
          periodSeconds: 60
      selectPolicy: Max
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 15
        - type: Pods
          value: 4
          periodSeconds: 15
      selectPolicy: Max
```

```yaml
# k8s/cron-hpa.yaml
# 基于时间的自动扩缩容，应对可预期的流量高峰
apiVersion: autoscaling.xiao8.com/v1
kind: CronHorizontalPodAutoscaler
metadata:
  name: inference-worker-cronhpa
  namespace: gsd2
spec:
  scaleTargetRef:
    kind: Deployment
    name: inference-worker
  heuristics:
    # 工作日早上 9 点扩容
    - name: weekday-morning
      cron: "0 9 * * 1-5"
      targetReplicas: 10
      runOnce: false
    # 工作日晚上 7 点缩容
    - name: weekday-evening
      cron: "0 19 * * 1-5"
      targetReplicas: 5
      runOnce: false
    # 周末保持最低负载
    - name: weekend
      cron: "0 0 * * 0,6"
      targetReplicas: 2
      runOnce: false
```

**GPU 扩缩容配置（基于 Prometheus 自定义指标）：**

```yaml
# k8s/gpu-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: inference-worker-gpu-hpa
  namespace: gsd2
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: inference-worker
  minReplicas: 2
  maxReplicas: 20
  metrics:
    - type: External
      external:
        metric:
          name: gpu_utilization_average
          selector:
            matchLabels:
              cluster: production
              namespace: gsd2
              deployment: inference-worker
        target:
          type: AverageValue
          averageValue: "80"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Pods
          value: 5
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 600
```

```python
# scripts/update_gpu_metrics.py
# Prometheus GPU 指标采集脚本
from prometheus_client import start_http_server, Gauge
import pynvml

# 初始化 NVML
pynvml.nvmlInit()

gpu_utilization = Gauge(
    'gpu_utilization_average',
    'Average GPU utilization across all inference workers',
    ['namespace', 'deployment']
)

def collect_gpu_metrics():
    """采集所有 GPU 的利用率指标"""
    device_count = pynvml.nvmlDeviceGetCount()
    total_util = 0
    
    for i in range(device_count):
        handle = pynvml.nvmlDeviceGetHandleByIndex(i)
        util = pynvml.nvmlDeviceGetUtilizationRates(handle)
        total_util += util.gpu
    
    avg_util = total_util / device_count if device_count > 0 else 0
    gpu_utilization.labels(
        namespace='gsd2',
        deployment='inference-worker'
    ).set(avg_util)

if __name__ == '__main__':
    start_http_server(9091)
    while True:
        collect_gpu_metrics()
        time.sleep(10)
```

### 3.2 负载均衡配置

```yaml
# k8s/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: planning-service-svc
  namespace: gsd2
  annotations:
    # AWS ALB 注解
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "http"
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "arn:aws:acm:..."
    # 连接耗尽时间（滚动更新时）
    service.beta.kubernetes.io/aws-load-balancer-connection-draining-timeout: "60"
spec:
  type: LoadBalancer
  selector:
    app: planning-service
  ports:
    - protocol: TCP
      port: 443
      targetPort: 8000
      name: https
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800
```

**Nginx Ingress 配置：**

```yaml
# k8s/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gsd2-ingress
  namespace: gsd2
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/limit-rps: "100"
    nginx.ingress.kubernetes.io/limit-connections: "50"
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
    nginx.ingress.kubernetes.io/upstream-hash-by: "$request_id"
    nginx.ingress.kubernetes.io/circuit-breaker: "true"
    nginx.ingress.kubernetes.io/connection-proxy-header: "keep-alive"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - "gsd2.example.com"
      secretName: gsd2-tls-secret
  rules:
    - host: "gsd2.example.com"
      http:
        paths:
          # 规划服务
          - path: /api/v1/planning
            pathType: Prefix
            backend:
              service:
                name: planning-service-svc
                port:
                  number: 8000
          # 执行服务
          - path: /api/v1/execute
            pathType: Prefix
            backend:
              service:
                name: execution-service-svc
                port:
                  number: 8000
          # 记忆服务
          - path: /api/v1/memory
            pathType: Prefix
            backend:
              service:
                name: memory-service-svc
                port:
                  number: 8000
          # 推理 Worker
          - path: /api/v1/inference
            pathType: Prefix
            backend:
              service:
                name: inference-worker-svc
                port:
                  number: 8000
```

### 3.3 多区域部署

对于全球化服务，多区域部署是保证低延迟和高可用的关键。gsd2 采用主动-被动（Active-Passive）或主动-主动（Active-Active）架构：

```mermaid
graph TB
    subgraph "Region: us-east-1 (Primary)"
        LB1["Global Accelerator"]
        subgraph "us-east-1 部署"
            GW1["API Gateway"]
            PL1["Planning x3"]
            EX1["Execution x5"]
            MM1["Memory x2"]
            W1["Workers x10"]
            PG1["PostgreSQL<br/>Primary"]
            RD1["Redis<br/>Cluster"]
        end
    end
    
    subgraph "Region: eu-west-1 (Secondary)"
        subgraph "eu-west-1 部署"
            GW2["API Gateway"]
            PL2["Planning x2"]
            EX2["Execution x3"]
            MM2["Memory x2"]
            W2["Workers x5"]
            PG2["PostgreSQL<br/>Standby"]
            RD2["Redis<br/>Replica"]
        end
    end
    
    subgraph "Region: ap-southeast-1 (Tertiary)"
        subgraph "ap-southeast-1 部署"
            GW3["API Gateway"]
            PL3["Planning x2"]
            EX3["Execution x3"]
            MM3["Memory x2"]
            W3["Workers x5"]
            PG3["PostgreSQL<br/>Standby"]
            RD3["Redis<br/>Replica"]
        end
    end
    
    LB1 --> GW1
    LB1 -.->|健康检查| GW2
    LB1 -.->|健康检查| GW3
    PG1 -.->|流复制| PG2
    PG1 -.->|流复制| PG3
    RD1 -.->|同步| RD2
    RD1 -.->|异步| RD3
```

**多区域数据库配置：**

```yaml
# AWS RDS Multi-AZ 配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: database-config
  namespace: gsd2
data:
  primary-endpoint: "gsd2-db.cluster-xxx.us-east-1.rds.amazonaws.com"
  secondary-endpoint: "gsd2-db.cluster-xxx.eu-west-1.rds.amazonaws.com"
  tertiary-endpoint: "gsd2-db.cluster-xxx.ap-southeast-1.rds.amazonaws.com"
---
# 应用程序数据库路由配置
# config/database_routing.py
import os
from enum import Enum
import random

class DatabaseRegion(Enum):
    PRIMARY = "us-east-1"
    SECONDARY = "eu-west-1"
    TERTIARY = "ap-southeast-1"

class DatabaseRouter:
    def __init__(self):
        self.current_region = os.getenv("DEPLOY_REGION", DatabaseRegion.PRIMARY.value)
        
    def get_read_endpoint(self) -> str:
        """根据负载和延迟选择读副本"""
        endpoints = {
            DatabaseRegion.PRIMARY.value: os.getenv("PRIMARY_ENDPOINT"),
            DatabaseRegion.SECONDARY.value: os.getenv("SECONDARY_ENDPOINT"),
            DatabaseRegion.TERTIARY.value: os.getenv("TERTIARY_ENDPOINT"),
        }
        # 优先读取本地副本
        local_endpoint = endpoints.get(self.current_region)
        if local_endpoint and random.random() > 0.1:  # 90% 读取本地
            return local_endpoint
        # 否则随机选择
        return random.choice(list(endpoints.values()))
    
    def get_write_endpoint(self) -> str:
        """写操作只能到主库"""
        return os.getenv("PRIMARY_ENDPOINT")
    
    def is_read_query(self, query: str) -> bool:
        """判断是否为只读查询"""
        read_keywords = ['SELECT', 'SHOW', 'DESCRIBE', 'EXPLAIN']
        return any(query.strip().upper().startswith(kw) for kw in read_keywords)
```

## 4. 成本优化

### 4.1 Spot Instance 与 Reserved Capacity

GPU 实例成本是 Code Agent 部署的主要开销。通过合理组合 Spot Instance、Reserved Instance 和 On-Demand Instance，可以将成本降低 60-70%。

**实例类型选择对照表：**

| 实例类型 | 可用性 | 成本折扣 | 适用场景 | 注意事项 |
|---------|-------|---------|---------|---------|
| On-Demand | 100% | 1x | 核心服务、无法中断的工作 | 基准价格 |
| Reserved 1yr | 100% | 0.6x | 稳定负载的核心服务 | 需预付 |
| Reserved 3yr | 100% | 0.4x | 长期稳定的服务 | 长期承诺 |
| Spot | 90-99% | 0.2-0.3x | 非关键 Worker、批处理 | 可能被中断 |
| Savings Plans | 100% | 0.5-0.7x | 可预测的工作负载 | 灵活实例类型 |

**成本优化架构：**

```mermaid
graph TB
    subgraph "基础服务 (Reserved/Savings Plans)"
        RS1["Reserved Instance<br/>Planning x3"]
        RS2["Reserved Instance<br/>Execution x5"]
        RS3["Reserved Instance<br/>Memory x2"]
        RS4["Reserved Instance<br/>PostgreSQL"]
        RS5["Reserved Instance<br/>Redis"]
    end
    
    subgraph "弹性 Worker (Spot + On-Demand)"
        SW1["Spot Worker Pool A<br/>10x A100"]
        SW2["Spot Worker Pool B<br/>5x A100"]
        OD1["On-Demand Workers<br/>2x A100"]
    end
    
    subgraph "扩缩容控制"
        SC["Spot Fleet Controller"]
        AS["Auto Scaling"]
    end
    
    AS --> RS1
    AS --> RS2
    AS --> RS3
    SC --> SW1
    SC --> SW2
    AS -.->|紧急扩容| OD1
```

**Spot Fleet 配置：**

```yaml
# aws-spot-fleet.yaml
SpotFleet:
  TargetCapacity: 20
  SpotMaintenanceStrategies:
    CapacityRebalance:
      ReplacementStrategy: launch
  LaunchSpecifications:
    - InstanceType: p4d.24xlarge
      ImageId: ami-0c55b159cbfafe1f0
      Subnet: subnet-xxxxx
      WeightedCapacity: 8
      SpotPrice: "2.5"
      Placement:
        AvailabilityZone: us-east-1a
    - InstanceType: p4d.24xlarge
      ImageId: ami-0c55b159cbfafe1f0
      Subnet: subnet-xxxxx
      WeightedCapacity: 8
      SpotPrice: "2.5"
      Placement:
        AvailabilityZone: us-east-1b
    - InstanceType: p3.16xlarge
      ImageId: ami-0c55b159cbfafe1f0
      Subnet: subnet-xxxxx
      WeightedCapacity: 4
      SpotPrice: "1.5"
  AllocationStrategy: lowestPrice
```

### 4.2 推理优化

推理成本优化是 Code Agent 部署的关键。以下是主要优化技术：

**模型量化（Quantization）：**

```python
# inference/quantization.py
from transformers import AutoModelForCausalLM, BitsAndBytesConfig
import torch

def load_quantized_model(model_name: str, quantization_config: dict):
    """
    加载量化模型以减少显存占用和推理延迟
    
    量化选项对比：
    - FP16: 原始精度，半精度浮点
    - INT8: 8位整数量化，~50% 显存 reduction
    - INT4: 4位整数量化，~75% 显存 reduction
    """
    quant_mode = quantization_config.get("mode", "fp16")
    
    if quant_mode == "int8":
        bnb_config = BitsAndBytesConfig(
            load_in_8bit=True,
            llm_int8_threshold=6.0,
            llm_int8_has_fp16_weight=False,
        )
    elif quant_mode == "int4":
        bnb_config = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_compute_dtype=torch.float16,
            bnb_4bit_use_double_quant=True,
        )
    else:
        bnb_config = None
    
    model = AutoModelForCausalLM.from_pretrained(
        model_name,
        quantization_config=bnb_config,
        device_map="auto",
        torch_dtype=torch.float16 if quant_mode == "fp16" else None,
    )
    return model
```

**推理服务配置（vLLM）：**

```python
# inference/vllm_server.py
from vllm import LLM, SamplingParams

# vLLM 推理配置
sampling_params = SamplingParams(
    temperature=0.7,
    top_p=0.95,
    max_tokens=2048,
    presence_penalty=0.0,
    frequency_penalty=0.0,
)

# 初始化 vLLM 推理引擎
llm = LLM(
    model="/models/code-agent-v1",
    tensor_parallel_size=2,  # 多 GPU 张量并行
    pipeline_parallel_size=1,
    gpu_memory_utilization=0.85,  # GPU 显存利用率
    max_num_batched_tokens=8192,
    max_num_seqs=256,
    trust_remote_code=True,
    enforce_eager=False,  # 使用 CUDA graph 优化
)

def inference(prompt: str) -> str:
    """执行推理"""
    outputs = llm.generate([prompt], sampling_params)
    return outputs[0].outputs[0].text
```

**批量推理优化：**

```python
# inference/batch_inference.py
import asyncio
from typing import List
from vllm import SamplingParams

class BatchInferenceEngine:
    def __init__(self, model_path: str, batch_size: int = 32):
        from vllm import LLM
        self.llm = LLM(model=model_path, tensor_parallel_size=2)
        self.batch_size = batch_size
        self.queue = asyncio.Queue()
        self.pending = []
        
    async def add_request(self, prompt: str, request_id: str):
        """添加推理请求"""
        future = asyncio.Future()
        await self.queue.put((request_id, prompt, future))
        return await future
    
    async def process_batch(self):
        """批处理推理"""
        batch = []
        futures = []
        
        # 收集最多 batch_size 个请求
        while len(batch) < self.batch_size and not self.queue.empty():
            request_id, prompt, future = await self.queue.get()
            batch.append(prompt)
            futures.append((request_id, future))
        
        if not batch:
            return
        
        # 批量推理
        sampling_params = SamplingParams(temperature=0.7, max_tokens=1024)
        outputs = self.llm.generate(batch, sampling_params)
        
        # 分发结果
        for (request_id, future), output in zip(futures, outputs):
            future.set_result(output.outputs[0].text)
    
    async def run(self):
        """启动批处理循环"""
        while True:
            await asyncio.gather(
                self.process_batch(),
                asyncio.sleep(0.1)  # 每 100ms 处理一批
            )
```

**显存优化技术对照表：**

| 技术 | 显存 reduction | 性能影响 | 适用场景 |
|------|---------------|---------|---------|
| FP16 推理 | 50% | 几乎无 | 通用场景 |
| INT8 量化 | 60% | <5% 精度损失 | 生产环境 |
| INT4 量化 | 75% | 5-10% 精度损失 | 成本敏感场景 |
| KV Cache 量化 | 30-40% | 几乎无 | 长上下文场景 |
| CUDA Graph | 0% | 10-20% 提升 | 所有 GPU 推理 |
| Flash Attention | 0% | 2-3x 提升 | 长序列场景 |
| speculative Decoding | 0% | 2-3x 提升 | 生成任务 |

## 5. 监控与可观测性

### 5.1 指标体系设计

生产环境的可观测性包含三个核心维度：指标（Metrics）、日志（Logs）和链路追踪（Traces）。以下是 gsd2 的完整可观测性架构：

```mermaid
graph TB
    subgraph "应用层"
        S1["Planning Service"]
        S2["Execution Service"]
        S3["Inference Worker"]
        S4["Memory Service"]
    end
    
    subgraph "指标采集"
        EM1["Exporters"]
        EM2["NodeExporter"]
        EM3["GPUExporter"]
    end
    
    subgraph "数据存储"
        PM["Prometheus"]
        ELK["Elasticsearch"]
        JA["Jaeger"]
    end
    
    subgraph "可视化"
        GF["Grafana"]
        KB["Kibana"]
        JG["Jaeger UI"]
    end
    
    subgraph "告警"
        AM["AlertManager"]
        AT["Alert Triage"]
    end
    
    S1 --> EM1
    S2 --> EM1
    S3 --> EM1
    S4 --> EM1
    EM2 --> PM
    EM3 --> PM
    EM1 --> PM
    PM --> GF
    PM --> AM
    
    S1 --> ELK
    S2 --> ELK
    S3 --> ELK
    S4 --> ELK
    ELK --> KB
    
    S1 --> JA
    S2 --> JA
    S3 --> JA
    S4 --> JA
    JA --> JG
```

**核心业务指标定义：**

```python
# monitoring/metrics.py
from prometheus_client import Counter, Histogram, Gauge, Info
import time
from contextlib import contextmanager

# 服务信息
SERVICE_INFO = Info(
    'gsd2_service',
    'gsd2 service information'
)

# 请求计数
REQUEST_COUNT = Counter(
    'gsd2_request_total',
    'Total number of requests',
    ['service', 'endpoint', 'method', 'status']
)

# 请求延迟
REQUEST_LATENCY = Histogram(
    'gsd2_request_latency_seconds',
    'Request latency in seconds',
    ['service', 'endpoint'],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
)

# 任务指标
TASK_COUNT = Counter(
    'gsd2_task_total',
    'Total number of tasks processed',
    ['service', 'task_type', 'status']
)

TASK_DURATION = Histogram(
    'gsd2_task_duration_seconds',
    'Task processing duration in seconds',
    ['service', 'task_type'],
    buckets=[0.1, 0.5, 1.0, 5.0, 10.0, 30.0, 60.0, 120.0, 300.0]
)

# 推理指标
INFERENCE_COUNT = Counter(
    'gsd2_inference_total',
    'Total number of inferences',
    ['model', 'status']
)

INFERENCE_LATENCY = Histogram(
    'gsd2_inference_latency_seconds',
    'Inference latency in seconds',
    ['model', 'batch_size'],
    buckets=[0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
)

GPU_UTILIZATION = Gauge(
    'gsd2_gpu_utilization_percent',
    'GPU utilization percentage',
    ['gpu_id', 'model']
)

GPU_MEMORY_USED = Gauge(
    'gsd2_gpu_memory_used_bytes',
    'GPU memory used in bytes',
    ['gpu_id', 'model']
)

# 队列指标
QUEUE_SIZE = Gauge(
    'gsd2_queue_size',
    'Current queue size',
    ['service', 'queue_name']
)

QUEUE_PUSH_TIME = Histogram(
    'gsd2_queue_push_latency_seconds',
    'Time spent pushing to queue',
    ['service', 'queue_name']
)

# 资源指标
ACTIVE_WORKERS = Gauge(
    'gsd2_active_workers',
    'Number of active workers',
    ['service']
)

CACHE_HIT_RATE = Gauge(
    'gsd2_cache_hit_rate',
    'Cache hit rate',
    ['service', 'cache_name']
)

@contextmanager
def track_request(service: str, endpoint: str, method: str):
    """请求追踪上下文管理器"""
    start_time = time.time()
    status = "success"
    try:
        yield
    except Exception:
        status = "error"
        raise
    finally:
        duration = time.time() - start_time
        REQUEST_COUNT.labels(
            service=service,
            endpoint=endpoint,
            method=method,
            status=status
        ).inc()
        REQUEST_LATENCY.labels(
            service=service,
            endpoint=endpoint
        ).observe(duration)

@contextmanager
def track_task(service: str, task_type: str):
    """任务追踪上下文管理器"""
    start_time = time.time()
    status = "success"
    try:
        yield
    except Exception as e:
        status = f"error_{type(e).__name__}"
        raise
    finally:
        duration = time.time() - start_time
        TASK_COUNT.labels(
            service=service,
            task_type=task_type,
            status=status
        ).inc()
        TASK_DURATION.labels(
            service=service,
            task_type=task_type
        ).observe(duration)
```

### 5.2 日志管理

```python
# logging/structured_logging.py
import logging
import json
import sys
from typing import Any, Dict
from datetime import datetime
import traceback

class StructuredFormatter(logging.Formatter):
    """结构化日志格式器"""
    
    def format(self, record: logging.LogRecord) -> str:
        log_data = {
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "level": record.levelname,
            "service": getattr(record, 'service_name', 'unknown'),
            "logger": record.name,
            "message": record.getMessage(),
            "module": record.module,
            "function": record.funcName,
            "line": record.lineno,
        }
        
        # 添加请求 ID
        if hasattr(record, 'request_id'):
            log_data['request_id'] = record.request_id
            
        # 添加用户 ID
        if hasattr(record, 'user_id'):
            log_data['user_id'] = record.user_id
            
        # 添加任务 ID
        if hasattr(record, 'task_id'):
            log_data['task_id'] = record.task_id
        
        # 添加额外字段
        if hasattr(record, 'extra_data'):
            log_data.update(record.extra_data)
        
        # 添加异常信息
        if record.exc_info:
            log_data['exception'] = {
                'type': record.exc_info[0].__name__ if record.exc_info[0] else None,
                'message': str(record.exc_info[1]) if record.exc_info[1] else None,
                'traceback': traceback.format_exception(*record.exc_info)
            }
        
        return json.dumps(log_data, ensure_ascii=False)

def setup_logging(service_name: str, log_level: str = "INFO"):
    """配置日志"""
    logger = logging.getLogger()
    logger.setLevel(getattr(logging, log_level.upper()))
    
    # Console handler
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(StructuredFormatter())
    logger.addHandler(console_handler)
    
    return logger

class LogContext:
    """日志上下文管理器"""
    _context = {}
    
    def __init__(self, **kwargs):
        self.context = kwargs
        
    def __enter__(self):
        for key, value in self.context.items():
            LogContext._context[key] = value
        return self
        
    def __exit__(self, exc_type, exc_val, exc_tb):
        for key in self.context.keys():
            LogContext._context.pop(key, None)
        return False
    
    @staticmethod
    def get_context() -> Dict[str, Any]:
        return LogContext._context.copy()
```

**Fluentd 日志采集配置：**

```yaml
# fluentd/fluentd-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluentd-config
  namespace: gsd2
data:
  fluent.conf: |
    # 读取容器日志
    <source>
      @type tail
      @id input-container-log
      path /var/log/containers/*.log
      pos_file /var/log/containers.log.pos
      tag kubernetes.*
      read_from_head true
      <parse>
        @type json
        time_key time
        time_format %Y-%m-%dT%H:%M:%S.%NZ
      </parse>
    </source>
    
    # 添加 Kubernetes 元数据
    <filter kubernetes.**>
      @type kubernetes_metadata
      @id kubernetes_metadata
      skip_labels false
      skip_container_metadata false
      skip_master_url true
    </filter>
    
    # 解析应用日志
    <filter kubernetes.var.log.containers.gsd2**.log>
      @type parser
      key_name log
      <parse>
        @type json
      </parse>
    </filter>
    
    # 输出到 Elasticsearch
    <match kubernetes.**>
      @type elasticsearch
      @id output-elasticsearch
      host elasticsearch.logging.svc.cluster.local
      port 9200
      logstash_format true
      logstash_prefix gsd2-prod
      include_tag_key true
      <buffer>
        @type file
        path /var/log/fluentd-buffers/elasticsearch.buffer
        flush_mode interval
        flush_interval 5s
        retry_type exponential_backoff
        retry_wait 10s
        retry_max_interval 30s
        retry_timeout 72h
      </buffer>
    </match>
```

### 5.3 链路追踪

```python
# tracing/tracing.py
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.jaeger.thrift import JaegerExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.propagate import inject, extract
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
import flask

def setup_tracing(service_name: str, jaeger_endpoint: str):
    """配置链路追踪"""
    # 创建 TracerProvider
    provider = TracerProvider()
    
    # 配置 Jaeger exporter
    jaeger_exporter = JaegerExporter(
        agent_host_name=jaeger_endpoint,
        agent_port=6831,
    )
    
    # 添加 span processor
    provider.add_span_processor(BatchSpanProcessor(jaeger_exporter))
    
    # 设置全局 tracer provider
    trace.set_tracer_provider(provider)
    
    return trace.get_tracer(service_name)

def trace_async(tracer, span_name: str, attributes: dict = None):
    """异步函数追踪装饰器"""
    def decorator(func):
        import functools
        @functools.wraps(func)
        async def wrapper(*args, **kwargs):
            with tracer.start_as_current_span(
                span_name,
                attributes=attributes
            ) as span:
                try:
                    result = await func(*args, **kwargs)
                    span.set_attribute("status", "success")
                    return result
                except Exception as e:
                    span.set_attribute("status", "error")
                    span.set_attribute("error.message", str(e))
                    span.record_exception(e)
                    raise
        return wrapper
    return decorator

class TracingContext:
    """链路追踪上下文"""
    _current_span = None
    
    @classmethod
    def inject_context(cls, carrier: dict):
        """注入上下文到 carrier"""
        TraceContextTextMapPropagator().inject(carrier)
        
    @classmethod
    def extract_context(cls, carrier: dict):
        """从 carrier 提取上下文"""
        return TraceContextTextMapPropagator().extract(carrier)
```

### 5.4 Grafana Dashboard 配置

```yaml
# grafana/dashboard-gsd2.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gsd2-grafana-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  gsd2-overview.json: |
    {
      "dashboard": {
        "title": "gsd2 生产环境概览",
        "uid": "gsd2-overview",
        "timezone": "browser",
        "panels": [
          {
            "title": "请求 QPS",
            "type": "graph",
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
            "targets": [
              {
                "expr": "sum(rate(gsd2_request_total{service=~\".+\"}[5m])) by (service)",
                "legendFormat": "{{service}}"
              }
            ]
          },
          {
            "title": "请求延迟 P99",
            "type": "graph",
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
            "targets": [
              {
                "expr": "histogram_quantile(0.99, sum(rate(gsd2_request_latency_seconds_bucket[5m])) by (le, service))",
                "legendFormat": "{{service}} P99"
              }
            ]
          },
          {
            "title": "GPU 利用率",
            "type": "graph",
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 8},
            "targets": [
              {
                "expr": "gsd2_gpu_utilization_percent",
                "legendFormat": "GPU {{gpu_id}}"
              }
            ]
          },
          {
            "title": "任务队列长度",
            "type": "graph",
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 8},
            "targets": [
              {
                "expr": "gsd2_queue_size",
                "legendFormat": "{{service}} - {{queue_name}}"
              }
            ]
          },
          {
            "title": "错误率",
            "type": "stat",
            "gridPos": {"h": 4, "w": 6, "x": 0, "y": 16},
            "targets": [
              {
                "expr": "sum(rate(gsd2_request_total{status=\"error\"}[5m])) / sum(rate(gsd2_request_total[5m])) * 100"
              }
            ],
            "options": {"colorMode": "value", "thresholds": {"steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 1}, {"color": "red", "value": 5}]}}
          },
          {
            "title": "活跃 Worker 数",
            "type": "stat",
            "gridPos": {"h": 4, "w": 6, "x": 6, "y": 16},
            "targets": [
              {
                "expr": "sum(gsd2_active_workers) by (service)"
              }
            ]
          },
          {
            "title": "推理延迟 P99",
            "type": "stat",
            "gridPos": {"h": 4, "w": 6, "x": 12, "y": 16},
            "targets": [
              {
                "expr": "histogram_quantile(0.99, sum(rate(gsd2_inference_latency_seconds_bucket[5m])) by (le))"
              }
            ]
          },
          {
            "title": "缓存命中率",
            "type": "stat",
            "gridPos": {"h": 4, "w": 6, "x": 18, "y": 16},
            "targets": [
              {
                "expr": "avg(gsd2_cache_hit_rate)"
              }
            ],
            "options": {"colorMode": "value", "thresholds": {"steps": [{"color": "red", "value": null}, {"color": "yellow", "value": 0.7}, {"color": "green", "value": 0.9}]}}
          }
        ]
      }
    }
```

### 5.5 Prometheus AlertManager 配置

```yaml
# monitoring/alert-rules.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-alert-rules
  namespace: monitoring
data:
  alerts.yaml: |
    groups:
      - name: gsd2-service-health
        rules:
          # 服务不可用告警
          - alert: ServiceDown
            expr: up{job="gsd2-services"} == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "服务 {{ $labels.service }} 不可用"
              description: "{{ $labels.service }} 已经宕机超过 1 分钟"
          
          # 高错误率告警
          - alert: HighErrorRate
            expr: sum(rate(gsd2_request_total{status="error"}[5m])) / sum(rate(gsd2_request_total[5m])) > 0.05
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "服务 {{ $labels.service }} 错误率过高"
              description: "错误率 {{ $value | humanizePercentage }} 超过 5%"
          
          # 高延迟告警
          - alert: HighLatency
            expr: histogram_quantile(0.99, sum(rate(gsd2_request_latency_seconds_bucket[5m])) by (le, service)) > 5
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "服务 {{ $labels.service }} 延迟过高"
              description: "P99 延迟 {{ $value }}s 超过 5s"
          
          # GPU 告警
          - alert: GPUOutOfMemory
            expr: (gsd2_gpu_memory_used_bytes / gpu_memory_total_bytes) > 0.95
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "GPU {{ $labels.gpu_id }} 显存即将耗尽"
          
          - alert: GPUUtilizationLow
            expr: gsd2_gpu_utilization_percent < 10
            for: 30m
            labels:
              severity: info
            annotations:
              summary: "GPU {{ $labels.gpu_id }} 利用率过低"
```

## 6. 高可用设计

### 6.1 多副本与故障转移

```mermaid
graph TB
    subgraph "正常状态"
        LB["负载均衡器"]
        P1["Planning Pod 1"]
        P2["Planning Pod 2"]
        P3["Planning Pod 3"]
        LB --> P1
        LB --> P2
        LB --> P3
    end
    
    subgraph "Pod 故障状态"
        LB2["负载均衡器"]
        P1A["Planning Pod 1<br/>✗ 已终止"]
        P2A["Planning Pod 2"]
        P3A["Planning Pod 3"]
        subgraph "Kubernetes 控制器"
            RC["Replication Controller"]
        end
        RC -.->|"检测到 Pod 1 终止<br/>创建新 Pod"| P4["Planning Pod 4"]
        LB2 --> P1A
        LB2 -.->|"移除故障 Pod"| P1A
        LB2 --> P2A
        LB2 --> P3A
        LB2 --> P4
    end
```

**PodDisruptionBudget 配置：**

```yaml
# k8s/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: planning-service-pdb
  namespace: gsd2
spec:
  minAvailable: 2  # 至少保持 2 个可用实例
  selector:
    matchLabels:
      app: planning-service
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: inference-worker-pdb
  namespace: gsd2
spec:
  maxUnavailable: 1  # 最多 1 个实例不可用
  selector:
    matchLabels:
      app: inference-worker
```

### 6.2 熔断器实现

```python
# resilience/circuit_breaker.py
import asyncio
import time
from enum import Enum
from typing import Callable, TypeVar, Optional
from dataclasses import dataclass
import logging

logger = logging.getLogger(__name__)

T = TypeVar('T')

class CircuitState(Enum):
    CLOSED = "closed"      # 正常关闭，所有请求通过
    OPEN = "open"          # 熔断开启，拒绝所有请求
    HALF_OPEN = "half_open"  # 半开状态，允许部分请求通过

@dataclass
class CircuitBreakerConfig:
    failure_threshold: int = 5      # 失败次数阈值
    success_threshold: int = 3       # 半开状态下成功次数阈值
    timeout: float = 30.0            # 熔断持续时间（秒）
    half_open_max_calls: int = 3    # 半开状态下的最大并发调用数

class CircuitBreaker:
    """
    熔断器实现
    
    状态转换：
    CLOSED -> OPEN: 失败次数达到阈值
    OPEN -> HALF_OPEN: 熔断超时
    HALF_OPEN -> CLOSED: 成功次数达到阈值
    HALF_OPEN -> OPEN: 再次失败
    """
    
    def __init__(self, name: str, config: CircuitBreakerConfig):
        self.name = name
        self.config = config
        self.state = CircuitState.CLOSED
        self.failure_count = 0
        self.success_count = 0
        self.last_failure_time: Optional[float] = None
        self._half_open_semaphore = asyncio.Semaphore(config.half_open_max_calls)
    
    async def call(self, func: Callable[..., T], *args, **kwargs) -> T:
        """执行带熔断保护的调用"""
        if not self._can_execute():
            raise CircuitOpenError(f"Circuit {self.name} is OPEN")
        
        async with self._half_open_semaphore:
            if self.state == CircuitState.HALF_OPEN:
                return await self._execute_half_open(func, *args, **kwargs)
            return await self._execute_normal(func, *args, **kwargs)
    
    def _can_execute(self) -> bool:
        """检查是否可以执行请求"""
        if self.state == CircuitState.CLOSED:
            return True
        
        if self.state == CircuitState.OPEN:
            # 检查超时
            if time.time() - self.last_failure_time >= self.config.timeout:
                self._transition_to_half_open()
                return True
            return False
        
        # HALF_OPEN 状态由信号量控制
        return True
    
    async def _execute_normal(self, func: Callable[..., T], *args, **kwargs) -> T:
        """正常状态执行"""
        try:
            result = await func(*args, **kwargs)
            self._on_success()
            return result
        except Exception as e:
            self._on_failure()
            raise
    
    async def _execute_half_open(self, func: Callable[..., T], *args, **kwargs) -> T:
        """半开状态执行"""
        try:
            result = await func(*args, **kwargs)
            self._on_success_in_half_open()
            return result
        except Exception as e:
            self._transition_to_open()
            raise
    
    def _on_success(self):
        """成功回调"""
        self.failure_count = 0
        if self.state != CircuitState.CLOSED:
            logger.info(f"Circuit {self.name}: Reset to CLOSED on success")
    
    def _on_failure(self):
        """失败回调"""
        self.failure_count += 1
        self.last_failure_time = time.time()
        
        if self.failure_count >= self.config.failure_threshold:
            self._transition_to_open()
        
        logger.warning(f"Circuit {self.name}: Failure {self.failure_count}/{self.config.failure_threshold}")
    
    def _on_success_in_half_open(self):
        """半开状态成功回调"""
        self.success_count += 1
        if self.success_count >= self.config.success_threshold:
            self._transition_to_closed()
            logger.info(f"Circuit {self.name}: Reset to CLOSED after {self.success_count} successes")
    
    def _transition_to_open(self):
        """转换到 OPEN 状态"""
        self.state = CircuitState.OPEN
        self.success_count = 0
        logger.warning(f"Circuit {self.name}: Transitioned to OPEN")
    
    def _transition_to_half_open(self):
        """转换到 HALF_OPEN 状态"""
        self.state = CircuitState.HALF_OPEN
        self.failure_count = 0
        logger.info(f"Circuit {self.name}: Transitioned to HALF_OPEN")
    
    def _transition_to_closed(self):
        """转换到 CLOSED 状态"""
        self.state = CircuitState.CLOSED
        self.failure_count = 0
        self.success_count = 0

class CircuitOpenError(Exception):
    """熔断器开启异常"""
    pass

# 全局熔断器注册表
_circuit_breakers: dict[str, CircuitBreaker] = {}

def get_circuit_breaker(name: str, config: Optional[CircuitBreakerConfig] = None) -> CircuitBreaker:
    """获取或创建熔断器"""
    if name not in _circuit_breakers:
        _circuit_breakers[name] = CircuitBreaker(name, config or CircuitBreakerConfig())
    return _circuit_breakers[name]
```

**熔断器使用示例：**

```python
# services/inference_client.py
import asyncio
from circuit_breaker import get_circuit_breaker, CircuitBreakerConfig, CircuitOpenError

# 配置熔断器
inference_circuit = get_circuit_breaker(
    "inference-service",
    CircuitBreakerConfig(
        failure_threshold=3,
        success_threshold=2,
        timeout=60.0
    )
)

class InferenceClient:
    def __init__(self, endpoint: str):
        self.endpoint = endpoint
        self.circuit = inference_circuit
    
    async def infer(self, prompt: str, model: str) -> str:
        """带熔断保护的推理调用"""
        async def _do_inference():
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{self.endpoint}/v1/completions",
                    json={"prompt": prompt, "model": model},
                    timeout=aiohttp.ClientTimeout(total=30)
                ) as resp:
                    return await resp.json()
        
        try:
            return await self.circuit.call(_do_inference)
        except CircuitOpenError:
            # 熔断开启，返回降级结果
            return {"error": "Service temporarily unavailable", "fallback": True}
        except Exception as e:
            logger.error(f"Inference failed: {e}")
            raise
```

### 6.3 限流器实现

```python
# resilience/rate_limiter.py
import asyncio
import time
from typing import Optional
from dataclasses import dataclass
from collections import deque
import logging

logger = logging.getLogger(__name__)

@dataclass
class RateLimitConfig:
    rate: float          # 每秒请求数
    burst: int           # 突发容量
    window: float = 1.0  # 时间窗口（秒）

class TokenBucketRateLimiter:
    """
    令牌桶限流器
    
    - rate: 稳定的令牌补充速率
    - burst: 桶的容量，允许突发
    """
    
    def __init__(self, config: RateLimitConfig):
        self.rate = config.rate
        self.burst = config.burst
        self.tokens = float(config.burst)
        self.last_update = time.time()
        self._lock = asyncio.Lock()
    
    async def acquire(self, tokens: int = 1) -> bool:
        """
        获取令牌
        
        Returns:
            True: 获取成功
            False: 被限流
        """
        async with self._lock:
            now = time.time()
            # 补充令牌
            elapsed = now - self.last_update
            self.tokens = min(self.burst, self.tokens + elapsed * self.rate)
            self.last_update = now
            
            if self.tokens >= tokens:
                self.tokens -= tokens
                return True
            return False
    
    async def wait_for_token(self, tokens: int = 1, timeout: Optional[float] = None):
        """等待获取令牌"""
        start_time = time.time()
        
        while True:
            if await self.acquire(tokens):
                return
            
            if timeout and (time.time() - start_time) >= timeout:
                raise TimeoutError(f"Rate limit timeout after {timeout}s")
            
            await asyncio.sleep(0.01)  # 避免 busy loop

class SlidingWindowRateLimiter:
    """
    滑动窗口限流器
    
    更精确的限流实现，基于时间窗口内的请求计数
    """
    
    def __init__(self, max_requests: int, window_seconds: float):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self.requests = deque()
        self._lock = asyncio.Lock()
    
    async def is_allowed(self) -> bool:
        """检查请求是否允许"""
        async with self._lock:
            now = time.time()
            cutoff = now - self.window_seconds
            
            # 清理过期的请求记录
            while self.requests and self.requests[0] < cutoff:
                self.requests.popleft()
            
            if len(self.requests) < self.max_requests:
                self.requests.append(now)
                return True
            return False
    
    async def acquire(self, timeout: Optional[float] = None) -> bool:
        """获取限流许可"""
        start_time = time.time()
        
        while True:
            if await self.is_allowed():
                return True
            
            if timeout and (time.time() - start_time) >= timeout:
                return False
            
            await asyncio.sleep(0.01)

# Kubernetes Ingress 限流注解
ingress_annotations = """
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    nginx.ingress.kubernetes.io/limit-rps: "100"        # 每秒 100 请求
    nginx.ingress.kubernetes.io/limit-connections: "50" # 最大 50 并发连接
    nginx.ingress.kubernetes.io/limit-burst-multiplier: "5"  # 突发乘数
"""
```

### 6.4 重试机制

```python
# resilience/retry.py
import asyncio
import functools
from typing import Callable, TypeVar, Optional, Tuple, Type
import logging

logger = logging.getLogger(__name__)

T = TypeVar('T')

class RetryConfig:
    def __init__(
        self,
        max_attempts: int = 3,
        initial_delay: float = 1.0,
        max_delay: float = 60.0,
        exponential_base: float = 2.0,
        retryable_exceptions: Optional[Tuple[Type[Exception], ...]] = None
    ):
        self.max_attempts = max_attempts
        self.initial_delay = initial_delay
        self.max_delay = max_delay
        self.exponential_base = exponential_base
        self.retryable_exceptions = retryable_exceptions or (Exception,)

def retry_async(config: Optional[RetryConfig] = None):
    """异步函数重试装饰器"""
    if config is None:
        config = RetryConfig()
    
    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        @functools.wraps(func)
        async def wrapper(*args, **kwargs) -> T:
            last_exception = None
            
            for attempt in range(1, config.max_attempts + 1):
                try:
                    return await func(*args, **kwargs)
                except config.retryable_exceptions as e:
                    last_exception = e
                    
                    if attempt == config.max_attempts:
                        logger.error(f"All {config.max_attempts} attempts failed for {func.__name__}")
                        raise
                    
                    delay = min(
                        config.initial_delay * (config.exponential_base ** (attempt - 1)),
                        config.max_delay
                    )
                    
                    logger.warning(
                        f"Attempt {attempt}/{config.max_attempts} failed for {func.__name__}: {e}. "
                        f"Retrying in {delay:.1f}s..."
                    )
                    await asyncio.sleep(delay)
            
            raise last_exception
        
        return wrapper
    return decorator

# 使用示例
class InferenceService:
    @retry_async(RetryConfig(
        max_attempts=5,
        initial_delay=2.0,
        max_delay=30.0,
        retryable_exceptions=(ConnectionError, TimeoutError, CircuitOpenError)
    ))
    async def complete(self, prompt: str) -> str:
        # 推理逻辑
        pass
```

## 7. 密钥与配置管理

### 7.1 Kubernetes Secret 管理

```yaml
# k8s/secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: gsd2-secrets
  namespace: gsd2
  labels:
    app: gsd2
  annotations:
    kubernetes.io/description: "gsd2 production secrets"
type: Opaque
stringData:
  # 数据库凭证
  database-username: "gsd2_prod"
  database-password: "actual-password-here"
  database-url: "postgresql://gsd2_prod:password@postgres:5432/gsd2_prod"
  
  # Redis 凭证
  redis-password: "redis-password-here"
  redis-url: "redis://:password@redis:6379/0"
  
  # JWT 密钥
  jwt-secret: "your-256-bit-secret-key-here"
  jwt-access-token-expire-minutes: "30"
  jwt-refresh-token-expire-days: "7"
  
  # 外部 API 密钥
  openai-api-key: "sk-xxxxx"
  huggingface-token: "hf_xxxxx"
  
  # S3 存储
  aws-access-key-id: "AKIAXXXXX"
  aws-secret-access-key: "xxxxx"
  s3-bucket-name: "gsd2-models-prod"
```

**External Secrets 集成 AWS Secrets Manager：**

```yaml
# k8s/external-secrets.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: gsd2-external-secrets
  namespace: gsd2
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: gsd2-secrets
    creationPolicy: Owner
  data:
    # 从 AWS Secrets Manager 获取数据库凭证
    - secretKey: database-password
      remoteRef:
        key: gsd2/prod/database
        property: password
    - secretKey: jwt-secret
      remoteRef:
        key: gsd2/prod/jwt
    # 环境变量引用
    - secretKey: openai-api-key
      remoteRef:
        key: gsd2/prod/external-apis
        property: openai_key
---
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
```

### 7.2 ConfigMap 管理

```yaml
# k8s/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gsd2-config
  namespace: gsd2
data:
  # 应用配置
  log_level: "INFO"
  log_format: "json"
  environment: "production"
  
  # 服务配置
  max_concurrent_tasks: "100"
  task_timeout_seconds: "300"
  worker_prefetch_count: "10"
  
  # 模型配置
  default_model: "code-agent-v1"
  max_tokens: "4096"
  temperature: "0.7"
  
  # 缓存配置
  cache_ttl_seconds: "3600"
  cache_max_size_mb: "1024"
  
  # 限流配置
  rate_limit_requests_per_second: "100"
  rate_limit_burst: "200"
---
# 环境特定配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: gsd2-config-override
  namespace: gsd2
data:
  log_level: "DEBUG"  # 覆盖默认配置
```

### 7.3 应用配置加载

```python
# config/settings.py
from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings
from typing import Optional
import os

class DatabaseSettings(BaseModel):
    host: str = Field(default="localhost")
    port: int = Field(default=5432)
    username: str
    password: str
    name: str
    pool_size: int = Field(default=20)
    max_overflow: int = Field(default=10)
    echo: bool = Field(default=False)
    
    @property
    def url(self) -> str:
        return f"postgresql://{self.username}:{self.password}@{self.host}:{self.port}/{self.name}"

class RedisSettings(BaseModel):
    host: str = Field(default="localhost")
    port: int = Field(default=6379)
    password: Optional[str] = None
    db: int = Field(default=0)
    pool_size: int = Field(default=50)
    
    @property
    def url(self) -> str:
        if self.password:
            return f"redis://:{self.password}@{self.host}:{self.port}/{self.db}"
        return f"redis://{self.host}:{self.port}/{self.db}"

class JWTSettings(BaseModel):
    secret_key: str
    algorithm: str = "HS256"
    access_token_expire_minutes: int = 30
    refresh_token_expire_days: int = 7

class ServiceSettings(BaseModel):
    log_level: str = Field(default="INFO")
    max_concurrent_tasks: int = Field(default=100)
    task_timeout_seconds: int = Field(default=300)
    rate_limit_rps: int = Field(default=100)

class Settings(BaseSettings):
    """应用配置"""
    environment: str = Field(default="development")
    
    # 从环境变量或 Secret 加载
    database: DatabaseSettings
    redis: RedisSettings
    jwt: JWTSettings
    service: ServiceSettings
    
    class Config:
        env_file = ".env"
        env_nested_delimiter = "__"
        secrets_dir = "/var/run/secrets"

def load_settings() -> Settings:
    """加载应用配置"""
    return Settings(
        database=DatabaseSettings(
            username=os.getenv("DB_USERNAME", "gsd2"),
            password=os.getenv("DB_PASSWORD", ""),
            name=os.getenv("DB_NAME", "gsd2"),
        ),
        redis=RedisSettings(
            host=os.getenv("REDIS_HOST", "localhost"),
            port=int(os.getenv("REDIS_PORT", "6379")),
            password=os.getenv("REDIS_PASSWORD"),
        ),
        jwt=JWTSettings(
            secret_key=os.getenv("JWT_SECRET", ""),
        ),
        service=ServiceSettings(
            log_level=os.getenv("LOG_LEVEL", "INFO"),
        )
    )
```

## 8. 升级与回滚策略

### 8.1 蓝绿部署

```mermaid
graph TB
    subgraph "部署前"
        LB1["负载均衡器"]
        subgraph "Blue 环境 (当前生产)"
            B1["Planning x3"]
            B2["Execution x5"]
            B3["Memory x2"]
        end
    end
    
    subgraph "部署中"
        LB2["负载均衡器"]
        subgraph "Blue 环境 (旧版本)"
            C1["Planning x3 v1.1.0"]
            C2["Execution x5 v1.1.0"]
            C3["Memory x2 v1.1.0"]
        end
        subgraph "Green 环境 (新版本)"
            D1["Planning x3 v1.2.0"]
            D2["Execution x5 v1.2.0"]
            D3["Memory x2 v1.2.0"]
        end
    end
    
    subgraph "部署后"
        LB3["负载均衡器"]
        subgraph "Blue 环境 (旧版本 - 待销毁)"
        end
        subgraph "Green 环境 (新生产)"
            E1["Planning x3 v1.2.0"]
            E2["Execution x5 v1.2.0"]
            E3["Memory x2 v1.2.0"]
        end
    end
```

**Argo Rollups 蓝绿部署配置：**

```yaml
# k8s/rollouts/bluegreen.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: planning-service-rollout
  namespace: gsd2
spec:
  replicas: 3
  strategy:
    blueGreen:
      # 活跃服务（接收流量）
      activeService: planning-service-active
      # 预览服务（用于验证）
      previewService: planning-service-preview
      # 自动切换前的等待时间
      autoPromotionEnabled: false
      # 预览副本数
      previewReplicaCount: 1
      # 切换后等待时间再销毁旧版本
      scaleDownDelaySeconds: 30
      # 流量探针
      prePromotionAnalysis:
        templates:
          - templateName: success-rate
        args:
          - name: service-name
            value: planning-service-preview
      postPromotionAnalysis:
        templates:
          - templateName: success-rate
        args:
          - name: service-name
            value: planning-service-active
  selector:
    matchLabels:
      app: planning-service
  template:
    metadata:
      labels:
        app: planning-service
    spec:
      containers:
        - name: planning-service
          image: gsd2/planning-service:v1.2.0
          ports:
            - containerPort: 8000
          readinessProbe:
            httpGet:
              path: /ready
              port: 8000
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 1m
      successCondition: result[0] >= 0.95
      failureLimit: 3
      provider:
        prometheus:
          address: http://prometheus:9090
          query: |
            sum(rate(gsd2_request_total{service="{{args.service-name}}",status="success"}[5m]))
            /
            sum(rate(gsd2_request_total{service="{{args.service-name}}"}[5m]))
```

### 8.2 金丝雀发布

```yaml
# k8s/rollouts/canary.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: inference-worker-rollout
  namespace: gsd2
spec:
  replicas: 10
  strategy:
    canary:
      # 步进式流量增加
      steps:
        - setWeight: 10    # 10%
        - pause: {duration: 5m}
        - setWeight: 30    # 30%
        - pause: {duration: 5m}
        - setWeight: 50    # 50%
        - pause: {duration: 10m}
        - setWeight: 100  # 100%
      
      # 流量分析
      canaryAnalysis:
        templates:
          - templateName: success-rate
          - templateName: latency
        interval: 2m
        maxWeight: 50
        maxIncrement: 10
        args:
          - name: service-name
            value: inference-worker-canary
      
      # 流量权重
      canaryMetadata:
        labels:
          version: canary
      stableMetadata:
        labels:
          version: stable
      
      # HPA 集成
      trafficRouting:
        nginx:
          stableIngress: inference-worker-stable
          additionalIngressAnnotations:
            canary-weight: "10"
      
      # Pod 标签
      podTemplate:
        metadata:
          labels:
            role: inference-worker
spec:
  selector:
    matchLabels:
      app: inference-worker
  template:
    metadata:
      labels:
        app: inference-worker
    spec:
      containers:
        - name: inference-worker
          image: gsd2/inference-worker:v1.2.0
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: latency
spec:
  args:
    - name: service-name
  metrics:
    - name: latency-p99
      interval: 1m
      successCondition: result[0] <= 2
      failureLimit: 3
      provider:
        prometheus:
          address: http://prometheus:9090
          query: |
            histogram_quantile(0.99,
              sum(rate(gsd2_inference_latency_seconds_bucket{service="{{args.service-name}}"}[5m])) by (le)
            )
```

### 8.3 滚动更新

```yaml
# k8s/deployment-rolling.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: memory-service
  namespace: gsd2
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # 最多超出期望副本数
      maxUnavailable: 0  # 滚动过程中所有实例保持可用
  minReadySeconds: 10    # 新 Pod 就绪后等待时间
  progressDeadlineSeconds: 600  # 部署超时时间
```

### 8.4 回滚策略

```bash
# kubectl 回滚命令
# 回滚到上一个版本
kubectl rollout undo deployment/planning-service -n gsd2

# 回滚到指定版本
kubectl rollout undo deployment/planning-service -n gsd2 --to-revision=2

# 查看部署历史
kubectl rollout history deployment/planning-service -n gsd2

# 暂停部署
kubectl rollout pause deployment/planning-service -n gsd2

# 恢复部署
kubectl rollout resume deployment/planning-service -n gsd2

# 等待部署完成
kubectl rollout status deployment/planning-service -n gsd2
```

**Helm 回滚：**

```bash
# Helm 回滚
helm rollback gsd2 1  # 回滚到版本 1

# 查看发布历史
helm history gsd2

# 回滚到指定版本
helm rollback gsd2 3 --wait
```

## 9. 团队协作与权限

### 9.1 多租户隔离

```mermaid
graph TB
    subgraph "Kubernetes 集群"
        subgraph "Tenant: team-alpha"
            NS1["namespace: gsd2-alpha"]
            RB1["RBAC: team-alpha"]
            Q1["ResourceQuota: team-alpha"]
        end
        
        subgraph "Tenant: team-beta"
            NS2["namespace: gsd2-beta"]
            RB2["RBAC: team-beta"]
            Q2["ResourceQuota: team-beta"]
        end
        
        subgraph "Tenant: team-gamma"
            NS3["namespace: gsd2-gamma"]
            RB3["RBAC: team-gamma"]
            Q3["ResourceQuota: team-gamma"]
        end
    end
```

**Namespace 隔离配置：**

```yaml
# k8s/tenant-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: gsd2-team-alpha
  labels:
    tenant: team-alpha
    environment: production
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-alpha-quota
  namespace: gsd2-team-alpha
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    pods: "50"
    services: "10"
    persistentvolumeclaims: "10"
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: team-alpha-network-policy
  namespace: gsd2-team-alpha
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # 只允许同命名空间的 Pod 和特定网关
    - from:
        - namespaceSelector:
            matchLabels:
              tenant: team-alpha
        - namespaceSelector:
            matchLabels:
              name: ingress-nginx
  egress:
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 53
        - protocol: UDP
          port: 53
```

### 9.2 RBAC 权限配置

```yaml
# k8s/rbac.yaml
# ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: planning-service-sa
  namespace: gsd2
---
# ClusterRole - 定义权限
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: planning-service-cr
rules:
  # 只读访问 ConfigMap
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
  # 读写 Endpoints
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch"]
  # 读写 Pod 日志
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get", "list"]
---
# RoleBinding - 将权限绑定到 ServiceAccount
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: planning-service-rb
  namespace: gsd2
subjects:
  - kind: ServiceAccount
    name: planning-service-sa
    namespace: gsd2
roleRef:
  kind: ClusterRole
  name: planning-service-cr
  apiGroup: rbac.authorization.k8s.io
---
# 团队级别的 Role
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: team-alpha-developer
  namespace: gsd2-team-alpha
rules:
  # 读写 Deployment
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "update", "patch"]
  # 读写 Pod（但不能删除）
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "update", "patch"]
  # 只读其他资源
  - apiGroups: [""]
    resources: ["services", "configmaps", "secrets"]
    verbs: ["get", "list", "watch"]
  # 读写 Ingress
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]
```

### 9.3 审计日志

```yaml
# k8s/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
metadata:
  name: gsd2-audit-policy
rules:
  # 不记录只读请求到某些端点
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services"]
  
  # 不记录来自 kube-system 的请求
  - level: None
    namespaces: ["kube-system"]
  
  # 不记录 /healthz 和 /version 的请求
  - level: None
    nonResourceURLs:
      - /healthz*
      - /version
      - /swagger*
  
  # Secret 操作记录元数据（不记录内容）
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
        verbs: ["create", "update", "patch", "delete"]
    omitStages:
      - RequestReceived
  
  # 认证相关操作记录
  - level: Metadata
    resources:
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]
      - group: "authorization.k8s.io"
        resources: ["subjectaccessreviews"]
  
  # 生产环境 Deployment 操作记录完整请求和响应
  - level: RequestResponse
    namespaces: ["gsd2", "gsd2-team-alpha", "gsd2-team-beta"]
    resources:
      - group: "apps"
        resources: ["deployments", "statefulsets", "daemonsets"]
      - group: ""
        resources: ["pods", "services", "configmaps", "secrets"]
    verbs: ["create", "update", "patch", "delete"]
  
  # 其他操作记录请求级别
  - level: Request
    resources:
      - group: ""
      - group: "apps"
      - group: "networking.k8s.io"
```

**审计日志查询示例：**

```sql
-- 查询敏感操作
SELECT 
    timestamp,
    user.username,
    objectRef.namespace,
    objectRef.name,
    objectRef.resource,
    verb,
    stage,
    requestObject
FROM audit_logs
WHERE 
    verb IN ('create', 'update', 'delete')
    AND (
        objectRef.resource = 'secrets'
        OR objectRef.resource = 'configmaps'
    )
    AND objectRef.namespace = 'gsd2'
ORDER BY timestamp DESC
LIMIT 100;

-- 查询失败的身份认证
SELECT
    timestamp,
    user.username,
    stage,
    responseStatus.code,
    responseStatus.message
FROM audit_logs
WHERE
    responseStatus.code != 200
    AND objectRef.apiGroup = 'authentication.k8s.io'
ORDER BY timestamp DESC;
```

## 10. gsd2 生产部署实践

### 10.1 完整架构设计

```mermaid
graph TB
    subgraph "用户接入层"
        CDN["CloudFront CDN"]
        WAF["AWS WAF"]
        LB["Global Accelerator + ALB"]
    end
    
    subgraph "Kubernetes 集群 (EKS)"
        subgraph "命名空间: gsd2"
            subgraph "Ingress (Nginx)"
                ING["Ingress Controller"]
            end
            
            subgraph "核心服务"
                GW["API Gateway<br/>(Kong)"]
                PL["Planning Service<br/>3 副本"]
                EX["Execution Service<br/>5 副本"]
                MM["Memory Service<br/>2 副本"]
            end
            
            subgraph "推理服务"
                WG["Worker Gateway"]
                W1["Worker Pool A<br/>10x A100"]
                W2["Worker Pool B<br/>5x A100 Spot"]
            end
        end
        
        subgraph "基础设施"
            MON["Prometheus<br/>Grafana"]
            TRACING["Jaeger"]
            LOGGING["Fluentd<br/>Elasticsearch<br/>Kibana"]
        end
    end
    
    subgraph "数据层"
        RDS["RDS PostgreSQL<br/>Multi-AZ"]
        DC["DocumentDB<br/>(Memory)"]
        RSC["ElastiCache Redis<br/>Cluster"]
        S3["S3<br/>(Models/Artifacts)"]
    end
    
    subgraph "外部服务"
        EXT["外部 API<br/>(OpenAI, HF)"]
    end
    
    CDN --> WAF
    WAF --> LB
    LB --> ING
    ING --> GW
    GW --> PL
    GW --> EX
    PL --> MM
    EX --> MM
    EX --> WG
    WG --> W1
    WG --> W2
    PL --> RDS
    MM --> RDS
    MM --> RSC
    MM --> DC
    PL --> S3
    EX --> S3
    W1 --> S3
    W2 --> S3
    RSC --> DC
```

### 10.2 EKS 集群部署配置

```yaml
# terraform/eks-cluster.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# EKS 集群
resource "aws_eks_cluster" "gsd2" {
  name     = "gsd2-prod"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.29"
  
  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = ["0.0.0.0/0"]
  }
  
  kubernetes_network_config {
    service_ipv4_cidr = "172.20.0.0/16"
  }
  
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

# Node Group - CPU 节点
resource "aws_eks_node_group" "cpu_nodes" {
  cluster_name    = aws_eks_cluster.gsd2.name
  node_group_name = "cpu-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids
  
  scaling_config {
    desired_size = 5
    max_size     = 15
    min_size     = 3
  }
  
  instance_types = ["m6i.2xlarge"]
  
  labels = {
    "node-type" = "cpu-optimized"
  }
  
  taint {
    key    = "node-type"
    value  = "cpu"
    effect = "NO_SCHEDULE"
  }
}

# Node Group - GPU 节点 (On-Demand)
resource "aws_eks_node_group" "gpu_nodes_ondemand" {
  cluster_name    = aws_eks_cluster.gsd2.name
  node_group_name = "gpu-nodes-ondemand"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids
  
  scaling_config {
    desired_size = 2
    max_size     = 5
    min_size     = 1
  }
  
  instance_types = ["p4d.24xlarge"]
  
  labels = {
    "node-type" = "gpu"
    "capacity" = "ondemand"
  }
  
  taint {
    key    = "nvidia.com/gpu"
    value  = "present"
    effect = "NO_SCHEDULE"
  }
}

# Node Group - GPU 节点 (Spot)
resource "aws_eks_node_group" "gpu_nodes_spot" {
  cluster_name    = aws_eks_cluster.gsd2.name
  node_group_name = "gpu-nodes-spot"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids
  
  scaling_config {
    desired_size = 5
    max_size     = 20
    min_size     = 0
  }
  
  instance_types = ["p4d.24xlarge", "p3.16xlarge"]
  
  labels = {
    "node-type" = "gpu"
    "capacity"  = "spot"
  }
  
  taint {
    key    = "nvidia.com/gpu"
    value  = "present"
    effect = "NO_SCHEDULE"
  }
  
  # Spot 实例分配策略
  capacity_type = "SPOT"
}
```

### 10.3 监控配置详情

```yaml
# monitoring/prometheus-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-server-conf
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
      external_labels:
        cluster: 'gsd2-production'
        environment: 'prod'
    
    alerting:
      alertmanagers:
        - static_configs:
            - targets: ['alertmanager.monitoring.svc.cluster.local:9093']
    
    rule_files:
      - '/etc/prometheus/rules/*.yaml'
    
    scrape_configs:
      # Kubernetes API Server
      - job_name: 'kubernetes-apiservers'
        kubernetes_sd_configs:
          - role: endpoints
        scheme: https
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        relabel_configs:
          - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
            action: keep
            regex: default;kubernetes;https
      
      # Kubernetes Pods
      - job_name: 'kubernetes-pods'
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: true
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
            action: replace
            target_label: __metrics_path__
            regex: (.+)
          - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
            action: replace
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: $1:$2
            target_label: __address__
          - action: labelmap
            regex: __meta_kubernetes_pod_label_(.+)
      
      # gsd2 服务
      - job_name: 'gsd2-services'
        kubernetes_sd_configs:
          - role: service
        namespace: gsd2
        relabel_configs:
          - source_labels: [__meta_kubernetes_service_label_app]
            action: keep
            regex: gsd2-.+
      
      # GPU 指标 (DCGM Exporter)
      - job_name: 'gpu-metrics'
        kubernetes_sd_configs:
          - role: endpoints
        namespace: monitoring
        relabel_configs:
          - source_labels: [__meta_kubernetes_endpoint_address_target_name]
            action: replace
            target_label: gpu_id
```

### 10.4 成本控制实践

**月度成本分配表：**

| 类别 | 组件 | 实例类型 | 数量 | 单价/月 | 小计/月 | 占比 |
|------|------|---------|------|---------|---------|------|
| 计算 | Planning Service | m6i.2xlarge | 3 | $280 | $840 | 8% |
| 计算 | Execution Service | m6i.4xlarge | 5 | $560 | $2,800 | 27% |
| GPU | GPU Workers (OD) | p4d.24xlarge | 2 | $25,000 | $50,000 | 30% |
| GPU | GPU Workers (Spot) | p4d.24xlarge | 5 | $7,500 | $37,500 | 22% |
| 数据库 | PostgreSQL Primary | r6i.2xlarge | 1 | $500 | $500 | 5% |
| 数据库 | PostgreSQL Replica | r6i.xlarge | 2 | $250 | $500 | 5% |
| 缓存 | Redis Cluster | r6g.large | 3 | $120 | $360 | 2% |
| 存储 | S3 + EBS | - | - | - | $500 | 1% |
| **合计** | | | | | **$93,000** | 100% |

**成本优化措施：**

1. **GPU Spot 实例节省 70%**：使用 Spot Fleet 管理 GPU 实例池，配合中断处理和自动恢复
2. **预留实例节省 40%**：核心服务使用 1 年期 Reserved Instance
3. **Auto Scaling 节省 30%**：根据实际负载动态调整实例数量
4. **模型量化节省 50%**：使用 INT8 量化模型，减少 GPU 显存占用和推理时间
5. **多区域流量调度**：非高峰期只保留主区域实例

**成本监控仪表板查询：**

```promql
# AWS Cost Explorer 集成查询
# 日均成本
sum(rate(aws_cost_usage_total[1d])) by (service)

# GPU 利用率 vs 成本效率
gsd2_gpu_utilization_percent / aws_cost_per_gpu_hour

# 请求成本
sum(rate(gsd2_request_total[1h])) * aws_cost_per_request

# 存储成本趋势
sum(aws_storage_cost{service="gsd2"}) by (storage_type)
```

### 10.5 部署检查清单

```markdown
## gsd2 生产部署检查清单

### 部署前
- [ ] 所有单元测试通过 (>95% 覆盖率)
- [ ] 集成测试通过 (数据库、Redis、外部 API)
- [ ] 性能测试达标 (P99 < 2s, QPS > 1000)
- [ ] 安全扫描通过 (无高危漏洞)
- [ ] 代码审查完成 (至少 2 人 Approve)
- [ ] 回滚计划已制定

### 基础设施
- [ ] Kubernetes 集群健康 (所有节点 Ready)
- [ ] 数据库主从同步正常
- [ ] Redis Cluster 健康
- [ ] S3 连接正常
- [ ] 外部 API 凭证有效

### 监控告警
- [ ] Prometheus 指标采集正常
- [ ] Grafana Dashboard 可访问
- [ ] AlertManager 告警通道正常
- [ ] 日志采集正常 (Elasticsearch)
- [ ] 链路追踪正常 (Jaeger)

### 配置验证
- [ ] ConfigMap 配置正确
- [ ] Secret 已正确配置
- [ ] 环境变量正确
- [ ] 资源限制设置合理

### 部署执行
- [ ] 通知相关团队
- [ ] 开启部署窗口
- [ ] 执行蓝绿/金丝雀部署
- [ ] 监控指标和日志
- [ ] 执行烟雾测试
- [ ] 验证流量正常

### 部署后
- [ ] 确认所有 Pod 运行正常
- [ ] 确认无告警触发
- [ ] 验证业务功能正常
- [ ] 监控系统性能指标
- [ ] 记录部署结果
- [ ] 通知团队部署完成
```

---

## 总结

本文深入探讨了 Code Agent 生产环境部署的各个关键维度：

1. **架构设计**：根据业务规模选择单体或微服务架构，gsd2 采用分层微服务架构实现良好的扩展性和可维护性

2. **容器化**：通过多阶段 Docker 构建和 Helm Chart 管理，实现一致的部署流程

3. **云原生特性**：利用 Kubernetes 的自动扩缩容、负载均衡和多区域部署能力，保证服务的高可用和低延迟

4. **成本优化**：通过 Spot Instance、Reserved Capacity 和推理优化，将 GPU 成本降低 60-70%

5. **可观测性**：建立完整的指标、日志和链路追踪体系，配合 Grafana 实现全面的监控能力

6. **高可用设计**：通过多副本、熔断器、限流器和重试机制，保证服务的稳定性和韧性

7. **密钥管理**：使用 External Secrets 集成 AWS Secrets Manager，实现安全的配置管理

8. **部署策略**：根据风险级别选择蓝绿、金丝雀或滚动更新策略，配合回滚机制保证部署安全

9. **团队协作**：通过 RBAC 和 Namespace 隔离实现多租户管理，配合审计日志保证合规性

生产环境部署是一个持续优化的过程，需要根据实际运行情况不断调整和完善。gsd2 项目的部署实践为 Code Agent 类应用的生产部署提供了可参考的模板。
