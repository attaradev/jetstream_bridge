# frozen_string_literal: true

require 'nats/io/client'
require 'singleton'
require_relative 'duration'
require_relative 'logging'

module JetstreamBridge
  # Singleton for managing a single NATS JetStream connection per process.
  class Connection
    include Singleton

    DEFAULT_CONN_OPTS = {
      reconnect: true,
      reconnect_time_wait: 2,
      max_reconnect_attempts: 10,
      connect_timeout: 5
    }.freeze

    # @return [NATS::JetStream::Client]
    def self.connect!
      instance.connect!
    end

    # @return [NATS::JetStream::Client]
    def connect!
      return @jts if @jts&.connected?

      servers = JetstreamBridge.config.nats_urls.to_s.split(',').map(&:strip).reject(&:empty?)
      raise 'No NATS URLs configured' if servers.empty?

      @nc = NATS::IO::Client.new
      @nc.connect({ servers: servers }.merge(DEFAULT_CONN_OPTS))
      @jts = @nc.jetstream

      Logging.info("Connected to NATS: #{servers.join(',')}", tag: 'JetstreamBridge::Connection')
      ensure_topology!
      @jts
    end

    # @return [Boolean]
    def connected?
      @jts&.connected?
    end

    private

    def ensure_topology!
      ensure_stream!(@jts, JetstreamBridge.config.stream_name, ['data.sync.>'])
      ensure_dlq!(@jts) if JetstreamBridge.config.use_dlq
    end

    def ensure_stream!(jts, name, subjects)
      jts.stream_info(name)
      Logging.info("Stream #{name} exists.", tag: 'JetstreamBridge::Connection')
    rescue NATS::JetStream::Error
      jts.add_stream(name: name, subjects: subjects, retention: 'interest', storage: 'file')
      Logging.info("Created stream #{name} subjects=#{subjects.inspect}", tag: 'JetstreamBridge::Connection')
    end

    def ensure_dlq!(jts)
      name = JetstreamBridge.config.stream_name
      info = jts.stream_info(name)
      subs = Array(info.config.subjects || [])
      dlq  = JetstreamBridge.config.dlq_subject
      return if subject_covered?(subs, dlq)

      jts.update_stream(name: name, subjects: (subs + [dlq]).uniq)
      Logging.info("Added DLQ subject #{dlq} to stream #{name}", tag: 'JetstreamBridge::Connection')
    end

    def subject_covered?(patterns, subject)
      patterns.any? { |pat| pattern_matches?(pat, subject) }
    end

    def pattern_matches?(pattern, subject)
      pattern_parts = pattern.split('.')
      subject_parts = subject.split('.')

      return true if pattern_parts.include?('>')
      return false if pattern_parts.size != subject_parts.size

      pattern_parts.each_with_index.all? do |part, i|
        part == '*' || part == subject_parts[i]
      end
    end
  end
end
