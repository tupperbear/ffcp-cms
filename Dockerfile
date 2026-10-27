# Directus with extensions baked in, so containers need no extensions volume
# and no Marketplace installs at runtime.
ARG DIRECTUS_VERSION=11.17.4
FROM directus/directus:${DIRECTUS_VERSION}

USER root
RUN corepack enable
USER node

RUN pnpm install \
	@directus-labs/super-header-interface@1.2.0 \
	@directus-labs/video-player-interface@1.0.1 \
	directus-extension-image-upload-resizer@2.3.0
