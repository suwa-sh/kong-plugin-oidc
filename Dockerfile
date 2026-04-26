ARG KONG_VERSION=3.12.0.5-ubuntu
FROM docker.io/kong/kong-gateway:${KONG_VERSION}

USER root
RUN apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/*

COPY kong/ /plugins/kong
COPY kong-plugin-oidc-1.8.0-1.rockspec /plugins/

WORKDIR /plugins
RUN luarocks make kong-plugin-oidc-1.8.0-1.rockspec

USER kong