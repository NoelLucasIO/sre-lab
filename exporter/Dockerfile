# Nightscout SLI exporter (ADR 0008). Standard library only, so the image is the pinned base
# plus one file. Built and pushed by .github/workflows/exporter.yml; deployed pinned by digest.
FROM docker.io/library/python:3.15.2-slim-trixie@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928

LABEL org.opencontainers.image.source="https://github.com/NoelLucasIO/sre-lab" \
      org.opencontainers.image.description="Nightscout SLI exporter for sre-lab" \
      org.opencontainers.image.licenses="MIT"

COPY ns_exporter.py /app/ns_exporter.py

# nobody: no shell login, no home, satisfies Pod Security "restricted".
USER 65534:65534
EXPOSE 9101
ENTRYPOINT ["python3", "-u", "/app/ns_exporter.py"]
