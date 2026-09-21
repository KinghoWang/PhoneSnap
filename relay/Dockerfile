FROM node:22-bookworm-slim
WORKDIR /app
COPY --chown=65532:65532 server.mjs /app/server.mjs
USER 65532:65532
ENV PHONESNAP_RELAY_HOST=0.0.0.0
ENV PHONESNAP_RELAY_CONFIG=/config/channels.json
EXPOSE 8787
CMD ["node", "/app/server.mjs"]
