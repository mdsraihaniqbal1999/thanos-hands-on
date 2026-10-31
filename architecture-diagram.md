# Thanos Hands-On

A hands-on learning repo for [Thanos](https://thanos.io) — highly available Prometheus setup with long-term storage.

## Thanos Architecture

```mermaid
flowchart TB
    subgraph clients["Clients"]
        GF["Grafana /<br/>Query Clients"]
    end

    subgraph query_layer["Query Layer (stateless, horizontally scalable)"]
        QF["Thanos Query Frontend<br/>(optional caching/sharding)"]
        Q["Thanos Query<br/>(fan-out PromQL + dedup)"]
    end

    subgraph write_path["Write Path"]
        RCV["Thanos Receive<br/>(remote write / long-term TSDB)"]
    end

    subgraph collection["Data Collection"]
        P1["Prometheus #1<br/>(K8s/EC2)"]
        P2["Prometheus #2<br/>(other cluster)"]
        S1["Thanos Sidecar<br/>(StoreAPI + block upload)"]
        S2["Thanos Sidecar<br/>(StoreAPI + block upload)"]
        RUL["Thanos Ruler<br/>(recording/alerting rules)"]
    end

    subgraph storage["Object Storage Layer"]
        OS[("Object Store<br/>S3 / GCS / Azure / MinIO")]
        CMP["Thanos Compactor<br/>(compact • downsample<br/>• dedup • retention)"]
        SGW["Thanos Store Gateway<br/>(StoreAPI over object store)"]
    end

    %% Query layer wiring
    GF --> QF --> Q

    %% Read path
    Q -->|StoreAPI| S1
    Q -->|StoreAPI| S2
    Q -->|StoreAPI| SGW
    Q -->|StoreAPI| RCV
    Q -->|StoreAPI| RUL

    %% Write / collection path
    P1 --> S1
    P2 --> S2
    S1 -->|upload blocks| OS
    S2 -->|upload blocks| OS
    RCV -->|remote write| P1
    RUL -->|remote write results| RCV

    %% Object storage processing
    OS <--> CMP
    OS --> SGW

    %% Hierarchy (optional)
    Q -.->|federated Query| Q2["Remote Thanos Query"]
```

### Component Overview

| Component | Role |
|---|---|
| **Sidecar** | Runs beside Prometheus, exposes local TSDB via StoreAPI and uploads blocks to object storage. |
| **Store Gateway** | Serves historical blocks from object storage via StoreAPI (scalable read path). |
| **Query** | Stateless query engine that fans out PromQL to all StoreAPI sources and deduplicates series. |
| **Query Frontend** | Optional caching and sharding layer in front of Query. |
| **Receive** | Accepts Prometheus `remote_write`, stores it in a long-term TSDB, serves StoreAPI (multi-tenant write path). |
| **Compactor** | Global singleton: compacts, downsamples (5m → 1h), applies retention, deduplicates HA pairs. |
| **Ruler** | Evaluates recording/alerting rules against stored data and pushes results via `remote_write`. |

### Data Flow (short)

1. Prometheus scrapes metrics and writes to its local TSDB.
2. **Sidecar** uploads TSDB blocks to object storage and exposes StoreAPI.
3. **Receive** optionally accepts `remote_write` for a centralized write path.
4. **Compactor** compacts/downsamples blocks in object storage.
5. **Query** fans out PromQL across Sidecars, Store Gateway, Receive, and Ruler — deduplicating along the way.
6. **Grafana** queries the single Query endpoint like a normal Prometheus.

## Getting Started

```bash
# Clone the repo
git clone <repo-url>
cd thanos-hands-on
```

_Coming soon: docker-compose setup with Prometheus, Thanos Sidecar, Store Gateway, Query, and MinIO._
