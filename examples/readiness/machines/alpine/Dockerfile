FROM alpine:3.20

LABEL org.opencontainers.image.title="Dory readiness Linux machine"
LABEL org.opencontainers.image.description="Small machine-style image used by Dory readiness examples"

RUN apk add --no-cache bash sudo shadow iproute2 ca-certificates openssh netcat-openbsd curl

CMD ["tail", "-f", "/dev/null"]
