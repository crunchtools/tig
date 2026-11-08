FROM registry.access.redhat.com/ubi10/ubi-minimal

# One image, three roles. Telegraf, InfluxDB 2.x and Grafana all come from their
# upstream RPM repositories; each container runs exactly one of them, chosen by
# the first argument to /usr/local/bin/tig. No systemd, no RHSM.

# Minor-version globs. The weekly rebuild picks up patch releases; a minor or
# major bump is a deliberate edit here, because provisioned dashboards, alert
# rules and the Flux rollup task are consumers of these interfaces.
#
# Telegraf is the exception and is pinned EXACTLY, not globbed. telegraf >= 1.39
# cannot list containers at all on gloval:
#
#     E! [inputs.docker] Error in plugin: listing containers failed:
#     ParseAddr("<nil>"): unable to parse IP
#
# Root cause: podman 5.8.2's Docker-compat /containers/json emits the literal
# four-character string "<nil>" as NetworkSettings.Networks.<net>.Gateway for
# any network that has no gateway -- Go's net.IP(nil).String(). gloval has five
# such networks (crunchtools-rt, crunchtools-wiki, crunchtools-kagemusha,
# crunchtools-nagios, crunchtools-josui-sites; each internal=true with no
# gateway), which puts ten "<nil>" values in a single response. telegraf >= 1.39
# parses Gateway strictly through netip.ParseAddr and fails the WHOLE list call,
# so NO container's metrics are collected while the collector still reports
# healthy. 1.38.4 does not parse that field and collects all 61 series.
# Measured on gloval: 1.38.4 good; 1.39.0, 1.39.3, 1.40.0, 1.40.1, 1.40.2 and
# 1.40.3 all dead. RT#1567.
#
# It is NOT about --network host, which was the first theory and is wrong: a
# host-network container's blank IPAddress is handled fine by 1.40.3.
#
# This is also why CI cannot catch it. A GitHub runner has no gatewayless
# network, so every telegraf version passes there. The version assertion in
# tests/test-image.sh guards the pin; nothing in CI guards the bug.
#
# To lift the pin: build with a glob on a branch, then run that image's
# `telegraf --test` with inputs.docker against gloval's real socket. Green there
# is the only evidence that counts. The durable alternative is to give those
# five networks a gateway, which removes the bad value at the source and frees
# the telegraf version -- at the cost of recreating the networks and restarting
# every container attached to them.
ARG TELEGRAF_VERSION=1.38.4
ARG INFLUXDB_VERSION=2.9.*
ARG INFLUX_CLI_VERSION=2.8.*
ARG GRAFANA_VERSION=13.2.*

COPY rootfs/etc/yum.repos.d/ /etc/yum.repos.d/

# Fixed service accounts, created BEFORE the RPMs so their scriptlets reuse
# them instead of allocating the next free system ID.
#
# These containers run without user namespaces, so in-container IDs land
# directly on the host and own the files under /srv/<service>/data. A
# dynamically allocated 997/998 collides with the web servers on the deploy
# host. 1501 and 1502 are unused there and in every running container.
RUN microdnf install -y shadow-utils && \
    groupadd -g 1501 influxdb && useradd -u 1501 -g 1501 -d /var/lib/influxdb2 -s /sbin/nologin influxdb && \
    groupadd -g 1502 grafana && useradd -u 1502 -g 1502 -d /usr/share/grafana -s /sbin/nologin grafana && \
    microdnf clean all

# python3 runs the Telegraf exec inputs; procps-ng and iproute are there for
# debugging a collector that has the host PID and network namespaces.
RUN microdnf install -y \
    "telegraf-${TELEGRAF_VERSION}" \
    "influxdb2-${INFLUXDB_VERSION}" \
    "influxdb2-cli-${INFLUX_CLI_VERSION}" \
    "grafana-${GRAFANA_VERSION}" \
    python3 \
    procps-ng \
    iproute \
    && microdnf clean all

COPY rootfs/usr/ /usr/

# Scripts are tracked 100644 in git, so COPY lands them non-executable and this
# chmod is load-bearing. Glob so a new script cannot be forgotten.
RUN chmod +x /usr/local/bin/* /usr/local/libexec/telegraf/*

EXPOSE 3000 8086

LABEL maintainer="fatherlinux <scott.mccarty@crunchtools.com>"
LABEL description="Telegraf, InfluxDB 2.x and Grafana on UBI 10, one role per container"
LABEL org.opencontainers.image.source=https://github.com/crunchtools/tig
LABEL org.opencontainers.image.description="Telegraf, InfluxDB 2.x and Grafana on UBI 10, one role per container"
LABEL org.opencontainers.image.licenses=AGPL-3.0-or-later

ENTRYPOINT ["/usr/local/bin/tig"]
