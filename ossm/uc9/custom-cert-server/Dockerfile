FROM registry.access.redhat.com/ubi9/ubi:9.4

RUN dnf -y install openssl \
  && dnf clean all \
  && rm -rf /var/cache/dnf

COPY run.sh /usr/local/bin/run-custom-cert-server.sh
RUN chmod 0755 /usr/local/bin/run-custom-cert-server.sh

ENTRYPOINT ["/usr/local/bin/run-custom-cert-server.sh"]

