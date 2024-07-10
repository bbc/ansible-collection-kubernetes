# syntax=docker/dockerfile:1.4

FROM python:3.10 AS ansible-runner

RUN pip install ansible

ADD . /ansible-collection-kubernetes

# Can override these variables on the commandline to use different repo or branch
# For example:
#     docker build --build-arg REPO_COLLECTION_CONTAINERS=git+https://github.com/my-repo/my-collection.git,my-branch
#
ARG REPO_COLLECTION_CONTAINERS=git+https://github.com/vexxhost/ansible-collection-containers.git
ARG REPO_COLLECTION_KUBERNETES=git+file:///ansible-collection-kubernetes

RUN ansible-galaxy collection install $REPO_COLLECTION_CONTAINERS
RUN ansible-galaxy collection install $REPO_COLLECTION_KUBERNETES

RUN ansible-playbook -i localhost, vexxhost.kubernetes.image_manifest -e ansible_connection=local \
      -e manifest_dest=/tmp/image_manifest.yaml \
      -e download_artifact_http_proxy=$HTTP_PROXY \
      -e download_artifact_https_proxy=$HTTP_PROXY \
      -e download_artifact_no_proxy=$NO_PROXY
# Result in /tmp/image_manifest.yaml

FROM alpine:3.17 AS registry-base

RUN apk add --no-cache docker-registry
ADD registry/config.yml /etc/docker-registry/config.yml

FROM registry-base AS registry-loader

COPY --from=gcr.io/go-containerregistry/crane /ko-app/crane /usr/local/bin/crane
RUN apk add --no-cache git gcc linux-headers musl-dev netcat-openbsd py3-pip python3-dev

# Can override this variable on the commandline to use different repo or branch
# For example:
#     docker build --build-arg REPO_MAGNUM_CLUSTER_API="-b my-branch https://github.com/my-repo/my-fork.git"
#
ARG REPO_MAGNUM_CLUSTER_API=https://github.com/vexxhost/magnum-cluster-api.git

RUN git clone $REPO_MAGNUM_CLUSTER_API /magnum-cluster-api
RUN pip install /magnum-cluster-api

COPY --from=ansible-runner /tmp/image_manifest.yaml /etc/docker-registry/image_manifest.yaml

RUN <<EOF
  docker-registry serve /etc/docker-registry/config.yml &

  while ! nc -z localhost 5000; do
    sleep 0.1
  done

  magnum-cluster-api-image-loader --manifest /etc/docker-registry/image_manifest.yaml --insecure --repository localhost:5000
EOF
# Result in /var/lib/registry/*

FROM registry-base AS registry
COPY --from=registry-loader --link /var/lib/registry /var/lib/registry
EXPOSE 5000
ENTRYPOINT ["docker-registry", "serve", "/etc/docker-registry/config.yml"]
