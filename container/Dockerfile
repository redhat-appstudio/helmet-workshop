# syntax=docker/dockerfile:1.4
# Workshop pod image: helmet-workshop build context only.
# Helmet is a normal Go module dependency (pinned in rewards-*/go.mod).
#
#   ./container/build.sh
#
ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi:latest
FROM ${BASE_IMAGE}

ARG HELM_VERSION=v3.16.3

RUN dnf install -y \
    git \
    golang \
    jq \
    make \
    nodejs \
    npm \
    && dnf clean all

# Helm is not packaged in UBI AppStream; install the upstream binary.
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) HELM_ARCH=amd64 ;; \
      arm64) HELM_ARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -sSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${HELM_ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin --strip-components=1 "linux-${HELM_ARCH}/helm"; \
    helm version --short

RUN curl -sSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz" \
    | tar -xz -C /usr/local/bin oc kubectl

# OpenShift runs containers with an arbitrary UID (group 0). Own content as 1001:0 with g+rwX.
RUN useradd -u 1001 -g 0 -m -d /home/workshop -s /bin/bash workshop

COPY . /home/workshop/helmet-workshop
RUN mkdir -p /home/workshop/.bashrc.d && \
    cp /home/workshop/helmet-workshop/container/workshop-bashrc.sh /home/workshop/.bashrc.d/workshop.sh && \
    grep -q 'bashrc.d' /home/workshop/.bashrc 2>/dev/null || \
    printf '\n# Workshop banner\nfor rc in ~/.bashrc.d/*; do [ -f "$rc" ] && . "$rc"; done\n' >> /home/workshop/.bashrc
# OpenShift assigns a random UID; g+rwX alone fails if the process is not in group 0.
# Workshop content is non-secret lab material — world read/write is OK in an isolated namespace.
RUN mkdir -p /home/workshop/.cache/go-mod /home/workshop/.cache/go-build && \
    chown -R 1001:0 /home/workshop && \
    chmod -R a+rwX /home/workshop

USER 1001

ENV HOME=/home/workshop
ENV REWARDS_DEMO_HOME=/home/workshop/helmet-workshop/rewards-demo
ENV REWARDS_WORKSHOP_HOME=/home/workshop/helmet-workshop/rewards-workshop
ENV PATH="/home/workshop/go/bin:${PATH}"
ENV GOMODCACHE=/home/workshop/.cache/go-mod
ENV GOCACHE=/home/workshop/.cache/go-build

WORKDIR /home/workshop/helmet-workshop/rewards-workshop
RUN go mod download -C /home/workshop/helmet-workshop/rewards-demo
RUN go mod download -C /home/workshop/helmet-workshop/rewards-workshop

# Seed GOCACHE so the first in-pod `make build` is mostly incremental (seconds, not ~30s).
# rewards-workshop has no helmet.yaml until Activity 1 — borrow demo's for a one-shot compile, then remove.
# Re-chmod after seed: OpenShift uses an arbitrary UID; files created here must stay a+rwX or
# in-pod `make` cannot rewrite installer/installer.tar (Permission denied).
RUN make -C /home/workshop/helmet-workshop/rewards-demo build && \
    cp /home/workshop/helmet-workshop/rewards-demo/installer/helmet.yaml \
       /home/workshop/helmet-workshop/rewards-workshop/installer/helmet.yaml && \
    sed -i 's/^name: rewards-demo$/name: rewards-workshop/' \
       /home/workshop/helmet-workshop/rewards-workshop/installer/helmet.yaml && \
    make -C /home/workshop/helmet-workshop/rewards-workshop build && \
    rm -f /home/workshop/helmet-workshop/rewards-workshop/rewards-workshop \
          /home/workshop/helmet-workshop/rewards-workshop/installer/helmet.yaml \
          /home/workshop/helmet-workshop/rewards-workshop/installer/installer.tar && \
    chmod -R a+rwX /home/workshop

CMD ["sleep", "infinity"]
