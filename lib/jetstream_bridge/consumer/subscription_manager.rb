# frozen_string_literal: true

require 'json'
require_relative '../core/logging'
require_relative '../core/duration'
require_relative '../errors'
require_relative 'pull_subscription_builder'

module JetstreamBridge
  # Encapsulates durable ensure + subscribe for a pull consumer.
  class SubscriptionManager
    def initialize(jts, durable, cfg = JetstreamBridge.config)
      @jts     = jts
      @durable = durable
      @cfg     = cfg
      @desired_cfg = build_consumer_config(@durable, filter_subject)
    end

    def stream_name
      @cfg.stream_name
    end

    def filter_subject
      @cfg.destination_subject
    end

    def desired_consumer_cfg
      @desired_cfg
    end

    # Ensure consumer exists, auto-creating if missing.
    #
    # @param force [Boolean] Kept for backward compatibility but no longer used.
    #   Consumers are always auto-created regardless of this parameter.
    def ensure_consumer!(**_options)
      # Always auto-create consumer if it doesn't exist, regardless of auto_provision setting.
      # auto_provision only controls stream topology creation, not consumer creation.
      create_consumer_if_missing!
    end

    # Check if stream exists.
    #
    # @return [Boolean] true if stream exists, false otherwise
    def stream_exists?
      @jts.stream_info(stream_name)
      true
    rescue StandardError => e
      msg = e.message.to_s.downcase
      return false if msg.include?('not found') || msg.include?('does not exist') || msg.include?('no responders')

      # Re-raise unexpected errors
      raise unless msg.include?('stream')

      false
    end

    # Check if consumer exists in the stream.
    #
    # @return [Boolean] true if consumer exists, false otherwise
    def consumer_exists?
      @jts.consumer_info(stream_name, @durable)
      true
    rescue StandardError => e
      msg = e.message.to_s.downcase
      return false if msg.include?('not found') || msg.include?('does not exist') || msg.include?('no responders')

      # Re-raise unexpected errors
      raise unless msg.include?('consumer')

      false
    end

    # Create consumer only if it doesn't already exist.
    #
    # Fails if the stream doesn't exist - streams must be provisioned separately.
    #
    # This is a safer alternative to create_consumer! that won't fail
    # if the consumer was already created by another process.
    #
    # @raise [StreamNotFoundError] if the stream doesn't exist
    def create_consumer_if_missing!
      # In restricted environments (push + auto_provision=false), we still want fail-fast semantics.
      # Attempt creation and raise a clear error so operators know the consumer must be pre-provisioned
      # or the account must allow the minimal $JS.API consumer permissions.
      if skip_consumer_management?
        raise JetstreamBridge::ConsumerProvisioningError,
              "Consumer '#{@durable}' not ensured because auto_provision=false and push mode is enabled. " \
              'Provision the consumer with admin credentials or grant minimal consumer create/info permissions.'
      end

      # First, verify stream exists - fail fast with clear error if not
      unless stream_exists?
        raise StreamNotFoundError,
              "Stream '#{stream_name}' does not exist. " \
              'Streams must be provisioned separately ' \
              '(use auto_provision=true or run provisioning with admin credentials).'
      end

      if consumer_exists?
        Logging.info(
          "Consumer #{@durable} already exists (stream=#{stream_name})",
          tag: 'JetstreamBridge::Consumer'
        )
        return
      end

      Logging.info(
        "Consumer #{@durable} not found, auto-creating on stream #{stream_name}...",
        tag: 'JetstreamBridge::Consumer'
      )
      create_consumer!
    rescue StreamNotFoundError
      raise
    rescue StandardError => e
      raise ConsumerProvisioningError, permission_error_message(e) if permission_denied?(e)

      # If creation fails due to consumer already existing (race condition), that's OK
      msg = e.message.to_s.downcase
      if msg.include?('already') || msg.include?('exists')
        Logging.info(
          "Consumer #{@durable} was created by another process",
          tag: 'JetstreamBridge::Consumer'
        )
        return
      end

      Logging.error(
        "Failed to auto-create consumer #{@durable}: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::Consumer'
      )
      raise
    end

    # Bind a subscriber to the existing durable consumer.
    def subscribe!
      if @cfg.push_consumer?
        subscribe_push_with_fallback
      else
        subscribe_pull_with_fallback
      end
    end

    def subscribe_without_verification!
      # Manually create a pull subscription without calling consumer_info
      # This bypasses the permission check in nats-pure's pull_subscribe
      create_subscription_with_fallback(
        description: "pull subscription for consumer #{@durable} (stream=#{stream_name})",
        primary_check: ->(nc) { nc.respond_to?(:new_inbox) && nc.respond_to?(:subscribe) },
        primary_action: ->(nc) { build_pull_subscription(nc) },
        fallback_name: :pull_subscribe,
        fallback_available: -> { @jts.respond_to?(:pull_subscribe) },
        fallback_action: -> { @jts.pull_subscribe(filter_subject, @durable, stream: stream_name) }
      )
    end

    def subscribe_push!
      # Push consumers deliver messages directly to a subscription subject
      # No JetStream API calls needed - just subscribe to the delivery subject
      delivery_subject = @cfg.push_delivery_subject
      queue_group = @cfg.push_consumer_group_name

      create_subscription_with_fallback(
        description: "push subscription for consumer #{@durable} " \
                     "(stream=#{stream_name}, delivery=#{delivery_subject}, queue=#{queue_group})",
        primary_check: ->(nc) { nc.respond_to?(:subscribe) },
        primary_action: lambda do |nc|
          sub = nc.subscribe(delivery_subject, queue: queue_group)
          Logging.info(
            "Created push subscription for consumer #{@durable} " \
            "(stream=#{stream_name}, delivery=#{delivery_subject}, queue=#{queue_group})",
            tag: 'JetstreamBridge::Consumer'
          )
          sub
        end,
        fallback_name: :subscribe,
        fallback_available: -> { @jts.respond_to?(:subscribe) },
        fallback_action: -> { @jts.subscribe(delivery_subject, queue: queue_group) }
      )
    end

    def subscribe_push_with_fallback
      subscribe_push!
    rescue JetstreamBridge::ConnectionError, StandardError => e
      Logging.warn(
        "Push subscription failed (#{e.class}: #{e.message}); falling back to pull subscription for #{@durable}",
        tag: 'JetstreamBridge::Consumer'
      )
      subscribe_without_verification!
    end

    def subscribe_pull_with_fallback
      subscribe_without_verification!
    rescue JetstreamBridge::ConnectionError, StandardError => e
      Logging.warn(
        "Pull subscription failed (#{e.class}: #{e.message}); falling back to push subscription for #{@durable}",
        tag: 'JetstreamBridge::Consumer'
      )
      subscribe_push!
    end

    private

    def build_consumer_config(durable, filter_subject)
      config = {
        durable_name: durable,
        filter_subject: filter_subject,
        ack_policy: 'explicit',
        deliver_policy: 'all',
        max_deliver: JetstreamBridge.config.max_deliver,
        # JetStream expects seconds (the client multiplies by nanoseconds).
        ack_wait: Duration.to_seconds(JetstreamBridge.config.ack_wait),
        backoff: Duration.normalize_list_to_seconds(JetstreamBridge.config.backoff)
      }

      # Add deliver_subject and deliver_group for push consumers
      if @cfg.push_consumer?
        config[:deliver_subject] = @cfg.push_delivery_subject
        config[:deliver_group] = @cfg.push_consumer_group_name
      end

      config
    end

    def skip_consumer_management?
      @cfg.push_consumer? && !@cfg.auto_provision
    end

    def permission_denied?(error)
      msg = error.message.to_s.downcase
      msg.include?('permission') || msg.include?('permissions violation')
    end

    def permission_error_message(error)
      "Consumer '#{@durable}' could not be ensured due to permissions: #{error.message}. " \
        'Grant $JS.API.STREAM.INFO/$JS.API.CONSUMER.INFO/$JS.API.CONSUMER.CREATE for the stream, ' \
        'or pre-provision the consumer with an admin account.'
    end

    def create_consumer!
      @jts.add_consumer(stream_name, **desired_consumer_cfg)
      Logging.info(
        "Created consumer #{@durable} (filter=#{filter_subject})",
        tag: 'JetstreamBridge::Consumer'
      )
    end

    def resolve_nc
      return @jts.nc if @jts.respond_to?(:nc)
      return @jts.instance_variable_get(:@nc) if @jts.instance_variable_defined?(:@nc)

      return @cfg.mock_nats_client if @cfg.respond_to?(:mock_nats_client) && @cfg.mock_nats_client

      nil
    end

    def build_pull_subscription(nats_client)
      builder = PullSubscriptionBuilder.new(@jts, @durable, stream_name, filter_subject)
      builder.build(nats_client)
    end

    def create_subscription_with_fallback(description:, primary_check:, primary_action:, fallback_name:,
                                          fallback_available:, fallback_action:)
      nc = resolve_nc

      return primary_action.call(nc) if nc && primary_check.call(nc)

      if fallback_available.call
        Logging.info(
          "Using #{fallback_name} fallback for #{description}",
          tag: 'JetstreamBridge::Consumer'
        )
        return fallback_action.call
      end

      raise JetstreamBridge::ConnectionError,
            "Unable to create #{description}: NATS client not available"
    end
  end
end
