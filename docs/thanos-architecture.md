# Thanos Architecture

Reference: [Official Thanos Design doc](https://thanos.io/tip/thanos/design.md/), [Quick Tutorial](https://thanos.io/tip/thanos/quick-tutorial.md/) and [Components](https://thanos.io/tip/thanos/getting-started.md/).

## Official architecture diagrams

Straight from the [official Thanos README](https://github.com/thanos-io/thanos#architecture-overview) and [Quick Tutorial](https://thanos.io/tip/thanos/quick-tutorial.md/):

### Deployment with Sidecar (for Kubernetes)

![Thanos Sidecar deployment architecture](https://docs.google.com/drawings/d/e/2PACX-1vSJd32gPh8-MC5Ko0-P-v1KQ0Xnxa0qmsVXowtkwVGlczGfVW-Vd415Y6F129zvh3y0vHLBZcJeZEoz/pub?w=960&h=720)

*Source: [thanos-io/thanos README](https://github.com/thanos-io/thanos/blob/main/README.md) — original drawing [here](https://docs.google.com/drawings/d/1AiMc1qAjASMbtqL6PNs0r9-ynGoZ9LIAtf0b9PjILxw/edit?usp=sharing).*

### Deployment with Receive (scale-out / remote-write sources)

![Thanos Receive deployment architecture](https://docs.google.com/drawings/d/e/2PACX-1vRdYP__uDuygGR5ym1dxBzU6LEx5v7Rs1cAUKPsl5BZrRGVl5YIj5lsD_FOljeIVOGWatdAI9pazbCP/pub?w=960&h=720)

*Source: [thanos-io/thanos README](https://github.com/thanos-io/thanos/blob/main/README.md) — original drawing [here](https://docs.google.com/drawings/d/1iimTbcicKXqz0FYtSfz04JmmVFLVO9BjAjEzBm5538w/edit?usp=sharing).*

> **Note:** This lab follows the **Sidecar** deployment pattern (Prometheus + Sidecar → Thanos Query), but without object storage — see the "Production considerations" section of the [README](../README.md).

The official docs group Thanos components into three categories — **metric sources**, **stores**, and **queriers** — plus the write path (**Receive**) and the **Compactor** (a singleton that works directly on object storage and does not join the Thanos cluster).

```mermaid
flowchart TB
    subgraph clients["Clients"]
        GF["Grafana /<br/>Query Clients"]
    end

    subgraph query_layer["Query Layer (Querier — stateless, horizontally scalable)"]
        QF["Query Frontend<br/>(optional caching/sharding)"]
        Q["Thanos Query<br/>(fan-out PromQL + dedup)"]
    end

    subgraph sources["Metric Sources (Store API)"]
        P1["Prometheus #1<br/>(east cluster)"]
        P2["Prometheus #2<br/>(west cluster)"]
        S1["Sidecar #1<br/>(serves + uploads blocks)"]
        S2["Sidecar #2<br/>(serves + uploads blocks)"]
        RUL["Ruler<br/>(recording/alerting rules)"]
    end

    subgraph write_path["Write Path"]
        RCV["Receive<br/>(remote_write / long-term TSDB)"]
    end

    subgraph stores["Stores (Store API over object storage)"]
        OS[("Object Store<br/>S3 / GCS / Azure / MinIO")]
        SGW["Store Gateway"]
    end

    CMP["Compactor<br/>(singleton: compact • downsample<br/>• dedup • retention)"]

    %% Query layer wiring
    GF --> QF --> Q

    %% Read path: everything exposes Store API to Query
    Q -->|StoreAPI| S1
    Q -->|StoreAPI| S2
    Q -->|StoreAPI| SGW
    Q -->|StoreAPI| RCV
    Q -.->|"StoreAPI — rules eval"| RUL

    %% Collection / write path
    P1 --> S1
    P2 --> S2
    S1 -->|upload blocks| OS
    S2 -->|upload blocks| OS
    P1 -.->|remote_write| RCV
    RUL -.->|remote_write results| RCV

    %% Object storage processing
    OS -->|blocks| SGW
    OS <-->|blocks| CMP

    %% Hierarchy (optional)
    Q -.->|federated Query| Q2["Remote Thanos Query"]
```

### Component roles

| Component | Official category | Role |
|---|---|---|
| **Sidecar** | Metric source | Runs beside Prometheus, exposes the local TSDB via StoreAPI and uploads blocks to object storage. |
| **Store Gateway** | Store | Gateway to historical blocks in object storage; implements the same StoreAPI as sources. |
| **Query (Querier)** | Query layer | Stateless, horizontally scalable PromQL engine; fans out to all StoreAPI nodes and deduplicates. |
| **Query Frontend** | Query layer | Optional caching and query-sharding layer in front of Query. |
| **Receive** | Write path | Accepts Prometheus `remote_write`, stores it in a long-term TSDB, exposes StoreAPI. |
| **Ruler** | Metric source | Evaluates recording/alerting rules (discovering Query nodes), pushes results via `remote_write`. |
| **Compactor** | (standalone) | Singleton pointed at the bucket; compacts, downsamples, deduplicates, applies retention. Not part of the cluster. |

### Data flow (short)

1. Prometheus scrapes metrics into its local TSDB.
2. The **Sidecar** uploads TSDB blocks to object storage and serves StoreAPI for recent data.
3. The **Store Gateway** serves historical blocks from object storage via StoreAPI.
4. **Receive** optionally accepts `remote_write` for a centralized, push-based write path.
5. The **Compactor** compacts/downsamples blocks in object storage (single instance per bucket).
6. **Query** fans out PromQL across Sidecars, Store Gateway, Receive, and Ruler — deduplicating HA pairs along the way.
7. **Grafana** (or any PromQL client) queries the single Query endpoint like a normal Prometheus.
