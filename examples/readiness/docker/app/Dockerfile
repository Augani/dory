FROM alpine:3.20

LABEL org.opencontainers.image.title="Dory readiness app"
LABEL org.opencontainers.image.description="Small HTTP/worker image used by Dory readiness examples"

WORKDIR /app

COPY entrypoint.sh server.sh worker.sh ./
RUN apk add --no-cache busybox-extras \
    && chmod +x /app/entrypoint.sh /app/server.sh /app/worker.sh \
    && mkdir -p /www /data

EXPOSE 8080
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["server"]
