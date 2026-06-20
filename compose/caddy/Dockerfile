# Build a Caddy binary with a DNS-provider plugin compiled in, so ACME
# certificates can be issued via the DNS-01 challenge (no inbound ports needed).
# The plugin module is a build arg (default caddy-dns/azure); switch it together
# with CADDY_DNS_PROVIDER in .env to use a different caddy-dns/* provider.
ARG CADDY_VERSION=2

FROM caddy:${CADDY_VERSION}-builder AS builder
ARG CADDY_DNS_MODULE=github.com/caddy-dns/azure
RUN xcaddy build --with ${CADDY_DNS_MODULE}

FROM caddy:${CADDY_VERSION}-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
