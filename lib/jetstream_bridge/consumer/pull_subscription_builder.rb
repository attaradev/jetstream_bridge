# frozen_string_literal: true

require 'json'
require_relative '../core/logging'
require_relative '../errors'

module JetstreamBridge
  # Builds and shims pull subscriptions without requiring JetStream API permissions.
  class PullSubscriptionBuilder
    def initialize(jts, durable, stream_name, filter_subject)
      @jts = jts
      @durable = durable
      @stream_name = stream_name
      @filter_subject = filter_subject
    end

    def build(nats_client)
      prefix = @jts.instance_variable_get(:@prefix) || '$JS.API'
      deliver = nats_client.new_inbox
      sub = nats_client.subscribe(deliver)
      sub.instance_variable_set(:@_jsb_nc, nats_client)
      sub.instance_variable_set(:@_jsb_deliver, deliver)
      sub.instance_variable_set(:@_jsb_next_subject, "#{prefix}.CONSUMER.MSG.NEXT.#{@stream_name}.#{@durable}")

      extend_pull_subscription(sub)
      attach_jsi(sub)

      Logging.info(
        "Created pull subscription without verification for consumer #{@durable} " \
        "(stream=#{@stream_name}, filter=#{@filter_subject})",
        tag: 'JetstreamBridge::Consumer'
      )

      sub
    end

    private

    def extend_pull_subscription(sub)
      pull_mod = begin
        NATS::JetStream.const_get(:PullSubscription)
      rescue NameError
        nil
      end

      sub.extend(pull_mod) if pull_mod
      shim_fetch(sub) unless pull_mod
    end

    def shim_fetch(sub)
      Logging.warn(
        'PullSubscription mixin unavailable; using shim fetch implementation',
        tag: 'JetstreamBridge::Consumer'
      )

      sub.define_singleton_method(:fetch) do |batch_size, timeout: nil|
        nc_handle = instance_variable_get(:@_jsb_nc)
        deliver_subject = instance_variable_get(:@_jsb_deliver)
        next_subject = instance_variable_get(:@_jsb_next_subject)
        unless nc_handle && deliver_subject && next_subject
          raise JetstreamBridge::ConnectionError, 'Missing NATS handles for fetch'
        end

        expires_ns = ((timeout || 5).to_f * 1_000_000_000).to_i
        payload = { batch: batch_size, expires: expires_ns }.to_json

        nc_handle.publish(next_subject, payload, deliver_subject)
        nc_handle.flush

        messages = []
        batch_size.times do
          msg = next_msg(timeout || 5)
          messages << msg if msg
        rescue NATS::IO::Timeout, NATS::Timeout
          break
        end
        messages
      end
    end

    def attach_jsi(sub)
      js_sub_class = begin
        NATS::JetStream.const_get(:JS).const_get(:Sub)
      rescue NameError
        Struct.new(:js, :stream, :consumer, :nms, keyword_init: true)
      end

      sub.jsi = js_sub_class.new(
        js: @jts,
        stream: @stream_name,
        consumer: @durable,
        nms: sub.instance_variable_get(:@_jsb_next_subject)
      )
    end
  end
end
