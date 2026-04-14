FROM docker.io/hashicorp/terraform:1.12.1

# Required by modules/infra local-exec health gate.
RUN apk add --no-cache curl
