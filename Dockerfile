FROM docker.io/kong/kong-gateway:3.9.1.2-ubuntu

USER root
RUN apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/*

COPY kong/ /plugins/kong
COPY kong-plugin-oidc-1.5.0-1.rockspec /plugins/

WORKDIR /plugins
RUN luarocks make kong-plugin-oidc-1.5.0-1.rockspec

USER kong