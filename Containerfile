FROM registry.access.redhat.com/ubi10/ubi-minimal

# One image, three roles. Telegraf, InfluxDB 2.x and Grafana all come from their
# upstream RPM repositories; each container runs exactly one of them, chosen by
# the first argument to /usr/local/bin/tig. No systemd, no RHSM.

# Minor-version globs. The weekly rebuild picks up patch releases; a minor or
# major bump is a deliberate edit here, because provisioned dashboards, alert
# rules and the Flux rollup task are consumers of these interfaces.
#
# Telegraf was an exact pin from RT#1567 until RT#1598. telegraf >= 1.39 parses
# NetworkSettings.Networks.<net>.Gateway through netip.ParseAddr and fails the
# WHOLE container list on one bad value, and podman 5.8.2's Docker-compat
# /containers/json renders a gatewayless network's gateway as the literal
# four-character string "<nil>" -- Go's net.IP(nil).String(). Gloval had five
# such networks, so every container on the box lost metrics while the collector
# still reported healthy. RT#1598 gave those networks explicit gateways, which
# removes the bad value at its source; the compat response now carries zero
# "<nil>". Verified against gloval's own socket, because CI cannot reproduce it:
# a GitHub runner has no gatewayless network, so every telegraf version passes
# here. Upstream: containers/podman#30149.
ARG TELEGRAF_VERSION=1.40.*
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
