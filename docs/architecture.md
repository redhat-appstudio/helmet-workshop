# Workshop architecture

DevConf hands-on: build a **Helmet composable-bundles installer** for the **Helmet Corp rewards** demo on a shared OpenShift cluster.

## Runtime picture (per participant)

```text
Namespace: workshop-p01 … workshop-p22
├── User: workshop-p01 (HTPasswd / cluster IdP) — console login, namespace-scoped edit
├── Deployment/workshop-pod — oc, helm, go, node, two installer projects + Helmet source
└── After rewards-demo / rewards-workshop deploy:
    ├── RabbitMQ + PostgreSQL  (data bundle)
    ├── order-producer         (manager portal → queue)
    └── order-consumer         (store portal ← queue)
```

Each participant works **only in their namespace**. The workshop pod is the shell: **OpenShift Console → Pod → Terminal**.

### Credential handout (coordinator)

After setup, a small Node.js app runs in **`workshop-coordinator`**:

1. Reads `credentials.csv` (mounted from a Secret — never baked into workshop images).
2. A **`coordinator,<room-code>,NA`** row supplies the room code; participant rows (`workshop-p*`) are the FIFO queue.
3. Serves a public Route; visitors enter the room code **before** a slot is dequeued (wrong codes do not consume slots).
4. Persists assignment state on a PVC so slots are not handed out twice.
5. Refreshing the page returns the **same** credentials (signed session cookie).

## Helmet installer (three bundles)

| Bundle | Role | Charts |
|--------|------|--------|
| **data** | Messaging + persistence | `order-rabbitmq`, `order-postgres` |
| **producer** | Manager rewards portal | `order-producer` |
| **consumer** | Store fulfillment portal | `order-consumer` |

Each bundle owns `config.yaml`, `values.yaml.tpl`, and `charts/` with Helmet annotations.

## Two projects in the workshop image

| Path | Audience | Contents |
|------|----------|----------|
| `rewards-demo/` | Instructor pod (default cwd) | Complete installer — demo end state |
| `rewards-workshop/` | Participant pod (default cwd) | Skeleton configs, no `helmet.yaml`, no dependency annotations, deliberate chart bugs |

Participants use the **coordinator page → Lab activities** (source: `rewards-workshop/workshop-activities.md`).

## Workshop pod image

Built from `container/Dockerfile`:

- `oc`, `helm`, `go`, `node`, `git`, `make`
- Copies `helmet-workshop` at image build; Helmet comes from the Go module pin in `rewards-*/go.mod`
- Env: `REWARDS_DEMO_HOME`, `REWARDS_WORKSHOP_HOME`
- Default cwd: `rewards-workshop` (participants); instructor deployments override to `rewards-demo`

## Cluster provisioning

| Script | Purpose |
|--------|---------|
| `hack/setup-workshop.sh` | Namespaces, RBAC, workshop Deployments, coordinator Route |
| `hack/cleanup-workshop.sh` | Remove workshop resources |

Requires **cluster-admin** once per cluster before the session.
