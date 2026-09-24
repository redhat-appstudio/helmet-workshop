# Solution reference (instructor)

Documents the **completed** `rewards-demo` installer used as the workshop answer key.

## Quick run (in pod)

```bash
cd "$REWARDS_DEMO_HOME"
export KUBECONFIG=""
make build
./rewards-demo config --create
./rewards-demo topology
./rewards-demo deploy
```

Expected topology:

```text
 1  order-rabbitmq
 2  order-postgres   (Order Data)
 3  order-producer   (Order Producer)
 4  order-consumer   (Order Consumer)
```

## Layout

- Installer: `rewards-demo/installer/bundles/{data,producer,consumer}/`
- Participant starting point: `rewards-workshop/` (checklist on coordinator page; source `rewards-workshop/workshop-activities.md`)

After participants finish all activities, their bundle trees should match `rewards-demo/installer/bundles/` (only `helmet.yaml` name differs).
