# Helmet Corp Rewards Workshop — Activities

Track progress with the checkboxes below **or on this coordinator page** (expand
**Lab activities** when your instructor tells you; keep this browser tab open
alongside the OpenShift terminal).

When every box is checked, your `rewards-workshop` installer should match the
instructor **`rewards-demo`** reference in the same pod.

Reference (do not edit during the lab): `../rewards-demo/installer/`

Your pod terminal opens in `rewards-workshop` — no directory change needed.

**Rebuild cycle:**

| You changed | Then run |
|-------------|----------|
| Anything under `installer/` (charts, `values.yaml.tpl`, `helmet.yaml`, …) | `make build` |
| A bundle `config.yaml` (product properties) | `make build` **and** `./rewards-workshop config --create --force` |
| Ready to check ordering | `./rewards-workshop topology` |
| Ready to roll out | `./rewards-workshop deploy` |

First `config --create` comes after your first bundle config edit (Activity 2). Use `--force` whenever you change a bundle `config.yaml` again. `values.yaml.tpl` changes only need `make build`. In the workshop pod, `config --create` and `template` default the installer namespace from `$WORKSHOP_NAMESPACE` (via `WithNamespace`) — no `-n` / `--namespace` needed.

---

## Phase 0 — Watch the instructor demo

See the finished rewards system before you build it: manager portal → queue →
store portal, and how Helmet topology/deploy looks when the installer is
complete.

- [ ] Manager portal submits thank-you orders
- [ ] Store portal fulfills orders
- [ ] Instructor shows `rewards-demo` topology and deploy output

---

## Activity 1 — Register products in `helmet.yaml`

Declare which composable bundles belong in this installer. Without
`helmet.yaml`, Helmet has no product blueprint and the binary will not build.

Create `installer/helmet.yaml` listing all three bundles.

- [ ] File exists at `installer/helmet.yaml`
- [ ] `name:` is `rewards-workshop`
- [ ] `products` includes `local://data`, `local://producer`, `local://consumer`
- [ ] `make build` produces `./rewards-workshop`

<details>
<summary>Hint</summary>

Copy the structure from `../rewards-demo/installer/helmet.yaml` and change
`name` to `rewards-workshop`. Until `installer/helmet.yaml` exists, `make build`
fails with a clear message.
</details>

---

## Activity 2 — Data product config

Set the Order Data product properties (queue and database names) that all
bundles must agree on. Writing them into the cluster ConfigMap is how
downstream charts learn those values at template time.

Edit `installer/bundles/data/config.yaml`.

- [ ] Product `name` is `Order Data`
- [ ] `queueName` is **`orders`** (not `order`)
- [ ] `databaseName` is `orders`
- [ ] `make build`
- [ ] `./rewards-workshop config --create` (first time — merges bundle configs into the cluster; namespace defaults from `$WORKSHOP_NAMESPACE`)
- [ ] `oc get cm rewards-workshop-config -o yaml` — verify the merged config (Order Data properties, `queueName: orders`)
- [ ] `./rewards-workshop topology` — charts list with empty Depends-On (no errors; RabbitMQ may be missing until Activity 4)

<details>
<summary>Hint</summary>

Open [`installer/bundles/data/config.yaml`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/data/config.yaml)
with `vi`. The starter file uses `queueName: order` on purpose — change it to
`orders`. All bundles must share the same queue name.
</details>

---

## Activity 3 — Data bundle values template

Map ConfigMap product properties into Helm chart values. This is the glue that
turns installer config into the Postgres instance list and RabbitMQ settings the
data charts actually deploy.

Complete `installer/bundles/data/values.yaml.tpl`.

- [ ] `pgsqlService.instances` enables the `orders` Postgres instance in your namespace
- [ ] `rabbitmq.enabled` is `true`
- [ ] RabbitMQ `namespace` and `queueName` come from the Order Data product
- [ ] `make build`
- [ ] `./rewards-workshop template --show-manifests=false bundles/data/charts/order-postgres` — confirm Postgres values from `bundles/data/values.yaml.tpl` (`enabled`, `dbname: orders`, namespace)
- [ ] `./rewards-workshop template --show-manifests=false bundles/data/charts/order-rabbitmq` — confirm RabbitMQ values from the same `bundles/data/values.yaml.tpl` (`enabled`, `queueName: orders`)

<details>
<summary>Hint</summary>

Open [`installer/bundles/data/values.yaml.tpl`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/data/values.yaml.tpl)
with `vi`.

**Composition glue:** the chart declares what it needs; the bundle ConfigMap
holds product properties; `values.yaml.tpl` maps one into the other.

1. Look at
   [`installer/bundles/data/charts/order-postgres/templates/postgres/pgsql-service.yaml`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/data/charts/order-postgres/templates/postgres/pgsql-service.yaml) —
   it `range`s over instances and expects fields like `name`, `enabled`,
   `namespace`, and `dbname`.
2. Look at
   [`installer/bundles/data/charts/order-postgres/values.yaml`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/data/charts/order-postgres/values.yaml) —
   `pgsqlService.instances` starts as `[]`. It should not stay empty given what
   the `pgsql-service` template expects above.
3. Fill those fields from the Order Data product in the ConfigMap via
   `.Installer.Products.Order_Data` (use `required` / `default`). Do the same
   for RabbitMQ from
   [`order-rabbitmq/values.yaml`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/data/charts/order-rabbitmq/values.yaml)
   /
   [`templates/rabbitmq.yaml`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/data/charts/order-rabbitmq/templates/rabbitmq.yaml).

Product names in the ConfigMap (e.g. `Order Data`) become template keys with
spaces replaced by underscores (`Order_Data`). Template variables
(`.Installer`, helpers like `required` / `default`): see Helmet
[templating.md](https://github.com/redhat-appstudio/helmet/blob/main/docs/templating.md).

Stuck? Compare with `../rewards-demo/installer/bundles/data/values.yaml.tpl`.

Both `template` calls use the same [`bundles/data/values.yaml.tpl`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/data/values.yaml.tpl)
with `--show-manifests=false` so you see rendered values only — look for your
namespace, `dbname: orders`, and `queueName: orders`. Chart templates are
fixed later.
</details>

---

## Activity 4 — Chart dependency inside the data bundle

Tell Helmet that Postgres depends on RabbitMQ within the data bundle so
topology installs messaging before the database (secrets and ordering stay
correct).

Open `installer/bundles/data/charts/order-postgres/Chart.yaml`.

- [ ] Add annotation `helmet.redhat-appstudio.github.com/depends-on-bundle-charts: order-rabbitmq` to the PostgreSQL `Chart.yaml` (`installer/bundles/data/charts/order-postgres/Chart.yaml`)
- [ ] `make build`
- [ ] `./rewards-workshop topology` — **rabbitmq before postgres** within the data bundle

<details>
<summary>Hint</summary>

Open [`installer/bundles/data/charts/order-postgres/Chart.yaml`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/data/charts/order-postgres/Chart.yaml)
with `vi` and add the annotation under the existing `annotations:` block (same
file as `product-name: Order Data`).
</details>

<details>
<summary>Why</summary>

RabbitMQ must exist before Postgres in the topology so secrets and ordering are
correct within the data bundle.
</details>

---

## Activity 5 — Producer bundle config and values

Configure the manager rewards portal: align its queue name with Order Data,
enable the chart, and point it at the DB/RabbitMQ Secrets and OpenShift Route
hostname the data charts will create.

- [ ] `installer/bundles/producer/config.yaml` — set `queueName: orders`
- [ ] `make build`
- [ ] `./rewards-workshop config --create --force`
- [ ] `oc get cm rewards-workshop-config -o yaml` — verify Order Producer has `queueName: orders`
- [ ] `installer/bundles/producer/values.yaml.tpl` — enable `orderProducer`
- [ ] Wire DB/RabbitMQ secret names and manager route hostname in the same file
- [ ] `make build`
- [ ] `./rewards-workshop template --show-manifests=false bundles/producer/charts/order-producer` — confirm rendered values (`enabled`, `queueName: orders`, secret names, manager route hostname)

<details>
<summary>Hint</summary>

Open [`installer/bundles/producer/config.yaml`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/producer/config.yaml)
(set `queueName: orders`) and
[`installer/bundles/producer/values.yaml.tpl`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/producer/values.yaml.tpl)
(enable the app and wire secrets/route).

Route host pattern: `rewards-managers-{{ $ns }}.{{ ingress }}`.

`$ingress` comes from `.OpenShift.Ingress.Domain` — Helmet fills `.OpenShift.*`
by reading the cluster at template time (not the ConfigMap). Properties you can
use in any `values.yaml.tpl`:

| Template path | Source |
|---------------|--------|
| `.OpenShift.Ingress.Domain` | IngressController default domain |
| `.OpenShift.Ingress.RouterCA` | Router CA cert (base64) |
| `.OpenShift.Version` | ClusterVersion |
| `.OpenShift.MinorVersion` | e.g. `4.18` from `4.18.2` |

Empty on plain Kubernetes. Demo uses Domain to build the Route hostname.
[Full list and examples (Template Context — `.Installer` and `.OpenShift`)](https://github.com/redhat-appstudio/helmet/blob/main/docs/templating.md)

`databaseName` stays on Order Data — the producer only references the existing
`orders-pgsql-user` secret.

Secret names like `orders-pgsql-user` / `orders-rabbitmq-user` are **created**
by the data charts, not by the producer chart. In `values.yaml.tpl` you only
point at those names so the Deployment can mount them (`secretKeyRef`). Look at
where the Secrets are rendered:
- [`installer/bundles/data/charts/order-postgres/templates/postgres/pgsql-service.yaml`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/data/charts/order-postgres/templates/postgres/pgsql-service.yaml)
- [`installer/bundles/data/charts/order-rabbitmq/templates/rabbitmq.yaml`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/data/charts/order-rabbitmq/templates/rabbitmq.yaml)

**Out of time on the glue?** Spend a few minutes sketching
`values.yaml.tpl` first. When the instructor says so, cheat — copy from the
demo and walk through it together:
- `../rewards-demo/installer/bundles/producer/values.yaml.tpl`
</details>

---

## Activity 6 — Consumer bundle config and values

Configure the store fulfillment portal the same way: shared queue name, enable
the chart, wire Secrets, and set both Route hostnames (store UI and a link back
to the manager portal).

- [ ] `installer/bundles/consumer/config.yaml` — set `queueName: orders`
- [ ] `make build`
- [ ] `./rewards-workshop config --create --force`
- [ ] `oc get cm rewards-workshop-config -o yaml` — verify Order Consumer has `queueName: orders`
- [ ] `installer/bundles/consumer/values.yaml.tpl` — enable `orderConsumer`
- [ ] Wire DB/RabbitMQ secret names in the same file
- [ ] Wire **both** route hostnames (store + manager portal link)
- [ ] `make build`
- [ ] `./rewards-workshop template --show-manifests=false bundles/consumer/charts/order-consumer` — confirm rendered values (`enabled`, `queueName: orders`, secret names, store + manager hostnames)

<details>
<summary>Hint</summary>

Open [`installer/bundles/consumer/config.yaml`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/consumer/config.yaml)
(set `queueName: orders`) and
[`installer/bundles/consumer/values.yaml.tpl`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/consumer/values.yaml.tpl)
(enable the app and wire secrets/routes).

Route host patterns:
- store: `rewards-store-{{ $ns }}.{{ ingress }}`
- manager portal link: `rewards-managers-{{ $ns }}.{{ ingress }}`

`$ingress` is `.OpenShift.Ingress.Domain` (same Helmet cluster introspection as
Activity 5 — not from the ConfigMap).
[Full list of `.OpenShift` / `.Installer` template variables (Template Context)](https://github.com/redhat-appstudio/helmet/blob/main/docs/templating.md)

`databaseName` stays on Order Data — the consumer only references the existing
`orders-pgsql-user` secret.

Secret names like `orders-pgsql-user` / `orders-rabbitmq-user` are **created**
by the data charts, not by the consumer chart. In `values.yaml.tpl` you only
point at those names so the Deployment can mount them (`secretKeyRef`). Look at
where the Secrets are rendered:
- [`installer/bundles/data/charts/order-postgres/templates/postgres/pgsql-service.yaml`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/data/charts/order-postgres/templates/postgres/pgsql-service.yaml)
- [`installer/bundles/data/charts/order-rabbitmq/templates/rabbitmq.yaml`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/data/charts/order-rabbitmq/templates/rabbitmq.yaml)

**Out of time on the glue?** Spend a few minutes sketching
`values.yaml.tpl` first. When the instructor says so, cheat — copy from the
demo and walk through it together:
- `../rewards-demo/installer/bundles/consumer/values.yaml.tpl`
</details>

---

## Activity 7 — Cross-bundle dependencies

Make producer and consumer wait on the entire data bundle so apps never deploy
before Postgres and RabbitMQ exist. After this, topology should show the full
install order end to end.

Edit producer and consumer chart metadata.

- [ ] `installer/bundles/producer/charts/order-producer/Chart.yaml` — add `helmet.redhat-appstudio.github.com/depends-on-bundles: data`
- [ ] `installer/bundles/consumer/charts/order-consumer/Chart.yaml` — add `helmet.redhat-appstudio.github.com/depends-on-bundles: data`
- [ ] `make build`
- [ ] `./rewards-workshop topology` shows: rabbitmq → postgres → producer → consumer (no errors)

<details>
<summary>Expected topology</summary>

```
 1  order-rabbitmq
 2  order-postgres   (Order Data)
 3  order-producer   (Order Producer)
 4  order-consumer   (Order Consumer)
```

</details>

---

## Activity 8 — First deploy attempt

Run a real deploy with a clean topology so you see how Helmet fails early on a
broken chart template — and stops before later charts are touched.

With topology clean, try a full rollout.

- [ ] `./rewards-workshop deploy` — fails on **order-rabbitmq** (template render error)
- [ ] Note the error (`rabbitmq.queueName is empty — check spelling…`) before fixing in Activity 9

<details>
<summary>Why it fails</summary>

The starter RabbitMQ chart has a deliberate typo (`queuName`). Helm treats
missing keys as empty, and `required` turns that into a hard render failure.
Helmet stops the rollout on the first failing chart — producer and consumer
are not reached yet.
</details>

---

## Activity 9 — Fix RabbitMQ chart bug

Repair the deliberate typo in the RabbitMQ chart so values render and the chart’s
Helm test can pass. You also see the next failure (Postgres Secret key) gating
the install.

- [ ] Open `installer/bundles/data/charts/order-rabbitmq/templates/rabbitmq.yaml`
- [ ] Fix typo **`queuName` → `queueName`** (two places)
- [ ] `make build`
- [ ] `./rewards-workshop deploy` — **order-rabbitmq** install + Helm test pass; **order-postgres** install then **Helm test fails** (Secret key mismatch)

<details>
<summary>Hint</summary>

Helmet runs `helm test` after each chart. RabbitMQ’s test checks the `queue`
Secret key and AMQP port. After the typo fix in
[`templates/rabbitmq.yaml`](https://github.com/redhat-appstudio/helmet-workshop/blob/main/rewards-workshop/installer/bundles/data/charts/order-rabbitmq/templates/rabbitmq.yaml),
RabbitMQ goes green; Postgres is next and its test Pod cannot start until the
Secret key matches `dbname`.
</details>

---

## Activity 10 — Fix PostgreSQL chart secret keys

Align the Postgres Secret key with what the container and Helm test expect so
the data layer goes green and producer/consumer can install next.

Deploy stops on the **order-postgres** Helm test until the Secret keys match.

- [ ] Inspect the failed test/pod (`oc get pods`, `oc describe pod -l job-name` / test pod, or the deploy error) — missing Secret key `dbname`
- [ ] Open `installer/bundles/data/charts/order-postgres/templates/postgres/pgsql-service.yaml`
- [ ] Secret `stringData` key must be **`dbname`** (not `database`) to match the container env **and** the chart test
- [ ] `make build`
- [ ] `./rewards-workshop deploy` — Postgres Helm test passes; producer/consumer install next (their tests wait on `/health`)

<details>
<summary>Hint</summary>

Compare with `../rewards-demo/installer/bundles/data/charts/order-postgres/templates/postgres/pgsql-service.yaml` around the Secret
`stringData` block. The chart test mounts `key: dbname` the same way the
Postgres container does — that is what gates the install.
</details>

---

## Activity 11 — Full deploy and verify rewards

Finish the rollout and prove the system works end to end: all charts + Helm
tests pass, and you can submit and fulfill a thank-you order like the instructor
demo.

- [ ] `./rewards-workshop deploy` completes all four charts (each chart’s Helm test passes)
- [ ] Manager portal URL works (submit a test order)
- [ ] Store portal URL works (fulfill the order)
- [ ] `./rewards-workshop topology` matches the instructor demo

---

## Done?

Compare your installer tree with the reference:

```bash
diff -ru ../rewards-demo/installer/bundles rewards-workshop/installer/bundles
# helmet.yaml name differs; bundle contents should otherwise align
```

You built the same Helmet Corp rewards system the instructor demoed — from
composable bundles, config, values templates, topology annotations, and chart
fixes.
