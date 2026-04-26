ARG KONG_VERSION=3.11.0.9-ubuntu
FROM docker.io/kong/kong-gateway:${KONG_VERSION}

USER root
RUN apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/*

COPY kong/ /plugins/kong
COPY kong-plugin-oidc-1.7.1-1.rockspec /plugins/

WORKDIR /plugins
RUN luarocks make kong-plugin-oidc-1.7.1-1.rockspec

USER kong