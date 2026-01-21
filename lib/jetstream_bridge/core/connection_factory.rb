# frozen_string_literal: true

require_relative 'connection'
require_relative '../errors'

module JetstreamBridge
  module Core
    # Factory for creating and managing NATS connections
    class ConnectionFactory
      # Connection options builder
      class ConnectionOptions
        DEFAULT_OPTS = {
          reconnect: true,
          reconnect_time_wait: 2,
          max_reconnect_attempts: 10,
          connect_timeout: 5
        }.freeze

        attr_accessor :servers, :reconnect, :reconnect_time_wait,
                      :max_reconnect_attempts, :connect_timeout,
                      :name, :user, :pass, :token, :inbox_prefix
        attr_reader :additional_opts

        def initialize(servers: nil, **opts)
          @servers = normalize_servers(servers) if servers
          @additional_opts = {}

          DEFAULT_OPTS.merge(opts).each do |key, value|
            if respond_to?(:"#{key}=")
              send(:"#{key}=", value)
            else
              @additional_opts[key] = value
            end
          end
        end

        def self.build(opts = {})
          new(**opts)
        end

        def to_h
          base = {
            reconnect: @reconnect,
            reconnect_time_wait: @reconnect_time_wait,
            max_reconnect_attempts: @max_reconnect_attempts,
            connect_timeout: @connect_timeout
          }

          base[:servers] = @servers if @servers
          base[:name] = @name if @name
          base[:user] = @user if @user
          base[:pass] = @pass if @pass
          base[:token] = @token if @token
          base[:inbox_prefix] = @inbox_prefix unless @inbox_prefix.to_s.empty?

          base.merge(@additional_opts)
        end

        private

        def normalize_servers(servers)
          Array(servers)
            .flat_map { |s| s.to_s.split(',') }
            .map(&:strip)
            .reject(&:empty?)
        end
      end

      class << self
        # Create connection options from config
        def build_options(config = JetstreamBridge.config)
          servers = config.nats_urls
          raise ConnectionNotEstablishedError, 'No NATS URLs configured' if servers.to_s.strip.empty?

          ConnectionOptions.new(
            servers: servers,
            name: "#{config.app_name}-#{config.env}",
            inbox_prefix: config.inbox_prefix
          )
        end

        # Create a new NATS client
        def create_client(options = nil)
          opts = options || build_options
          client = NATS::IO::Client.new
          client.connect(opts.to_h)
          client
        end

        # Create JetStream context with health monitoring
        def create_jetstream(client)
          jts = client.jetstream

          # Ensure JetStream responds to #nc
          jts.define_singleton_method(:nc) { client } unless jts.respond_to?(:nc)

          jts
        end
      end
    end
  end
end
