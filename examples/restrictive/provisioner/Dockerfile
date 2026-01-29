# syntax=docker/dockerfile:1.7
FROM ruby:3.2-alpine

RUN apk add --no-cache build-base ca-certificates

WORKDIR /provisioner

# Copy entire context (includes zscaler.pem if present)
COPY . /tmp/build_context

# Conditionally copy and trust Zscaler certificate if it exists
RUN if [ -f /tmp/build_context/examples/restrictive/zscaler.pem ]; then \
        cp /tmp/build_context/examples/restrictive/zscaler.pem /usr/local/share/ca-certificates/zscaler.crt && \
        update-ca-certificates; \
    fi && \
    rm -rf /tmp/build_context

# Copy the library code
COPY . /jetstream_bridge

# Copy provisioner script
COPY examples/restrictive/provisioner/Gemfile /provisioner/
COPY examples/restrictive/provisioner/provision.rb /provisioner/

# Install dependencies with isolated, locked caches to avoid bundle cache corruption
ENV BUNDLE_JOBS=4 BUNDLE_RETRY=3
RUN bundle config set path /usr/local/bundle
RUN --mount=type=cache,target=/usr/local/bundle/cache,id=restrictive-provisioner-bundle,sharing=locked \
    --mount=type=cache,target=/root/.bundle/cache,id=restrictive-provisioner-bundle-root,sharing=locked \
    bundle install

# Make script executable
RUN chmod +x provision.rb

# Add small startup delay to ensure DNS is fully resolved
CMD ["sh", "-c", "sleep 3 && ruby provision.rb"]
