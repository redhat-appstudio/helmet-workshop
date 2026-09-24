# Helmet composable bundles — DevConf workshop

Hands-on: **22 isolated namespaces** (20 participants + 2 instructors), each with a **workshop pod** (oc, helm, go, Node, Helmet @ `composable_bundles`).

| Directory | Audience | Purpose |
|-----------|----------|---------|
| **`rewards-demo`** | Instructor (default pod cwd for demo) | Complete reference installer — demo the end state first |
| **`rewards-workshop`** | Participants (default pod cwd) | Stripped installer; checklist on **coordinator page → Lab activities** |

Three composable bundles in both projects:

| Bundle | Purpose |
|--------|---------|
| **data** | PostgreSQL + RabbitMQ |
| **producer** | Manager rewards portal (publishes orders) |
| **consumer** | Store fulfillment portal (processes orders) |

## Repository layout

```text
helmet-workshop/
├── apps/                 # Node.js producer & consumer (reference impl)
├── coordinator/          # FIFO web app: hands out console credentials
├── container/            # Workshop pod + coordinator image builds
├── docs/
│   ├── workshop-activities.md   # Pointer → rewards-workshop/workshop-activities.md
│   ├── workshop-guide.md
│   └── architecture.md
├── hack/                 # setup-workshop.sh, cleanup-workshop.sh
├── rewards-demo/         # Full solution (instructor reference)
└── rewards-workshop/     # Participant lab + workshop-activities.md
```

## Before the session (instructors)

Copy and edit env once, then source it for **build** and **setup**:

```bash
cp hack/workshop.env.example hack/workshop.env   # gitignored
# edit hack/workshop.env
set -a && source hack/workshop.env && set +a
```

Example `hack/workshop.env`:

```bash
export WORKSHOP_IMAGE=quay.io/tsscdavp/helmet-workshop:dev
export PLATFORM=linux/amd64
export PARTICIPANT_COUNT=20
export INSTRUCTOR_COUNT=2
```

1. **Build & push** both images (requires `podman login quay.io`):

   ```bash
   ./container/build.sh
   ```

2. **Provision namespaces** (requires `oc login` as cluster-admin):

   ```bash
   ./hack/setup-workshop.sh
   ```

   Setup writes **`out/coordinator-links.txt`**: OpenShift Route URL, optional **TinyURL** short link, and QR image URL. Custom slug: `WORKSHOP_SHORTURL_SLUG` + `TINYURL_API_TOKEN` in `hack/workshop.env`.

3. **Capacity test** (optional — parallel build/config/deploy in all workshop pods):

   ```bash
   ./hack/capacity-test.sh                  # all participants, max parallel
   ./hack/capacity-test.sh --parallel 5     # throttle concurrency
   ```

   Uses `rewards-demo` inside each pod. Logs + before/after worker CPU/mem snapshots under `out/capacity-test-*`.

4. **Teardown**: `./hack/cleanup-workshop.sh`

## Session flow

1. **Instructor demo** from the instructor pod (default cwd: `rewards-demo`).
2. **Participants** open the coordinator page, log in to the console, then expand **Lab activities** when instructed (pod terminal already in `rewards-workshop`).

Instructor demo:

```bash
# instructor pod — already in rewards-demo
export KUBECONFIG=""
make build
./rewards-demo config --create
./rewards-demo topology
./rewards-demo deploy
```

After the demo, instructors `cd ../rewards-workshop` to follow along with participants.

## Local development (outside the cluster)

Helmet is a normal Go module (pinned in `rewards-*/go.mod` to a commit on
[`main`](https://github.com/redhat-appstudio/helmet/commits/main/)). No sibling
Helmet checkout is required:

```bash
cd rewards-demo && make deps && make build
./container/build.sh --no-push
```

To bump Helmet: `cd rewards-demo && go get github.com/redhat-appstudio/helmet@main && go mod tidy`
(and the same in `rewards-workshop`).

Validate that completing all activities yields the same bundles as `rewards-demo`:

```bash
./hack/validate-activities.sh
```

Architecture details: [docs/architecture.md](docs/architecture.md).
