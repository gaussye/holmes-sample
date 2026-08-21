FROM robustadev/holmes:0.39.0@sha256:035bb9f788c8a5df851b023d6b3be21384bff75b4496299a547fbf52b0fb67d8

COPY bin/holmes /usr/local/bin/holmes
RUN sed -i 's/\r$//' /usr/local/bin/holmes \
    && chmod 0755 /usr/local/bin/holmes
