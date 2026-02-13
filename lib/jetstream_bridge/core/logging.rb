# frozen_string_literal: true

require 'uri'
require 'logger'

module JetstreamBridge
  # Logging helpers that route to the configured logger when available,
  # falling back to Rails.logger or STDOUT.
  module Logging
    module_function

    # Returns the active logger instance.
    #
    # Resolution order: configured logger, Rails.logger, STDOUT fallback.
    #
    # @return [Logger] Active logger
    def logger
      JetstreamBridge.config.logger ||
        (defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger) ||
        default_logger
    end

    # Returns a default STDOUT logger, memoized for reuse.
    #
    # @return [Logger]
    def default_logger
      @default_logger ||= Logger.new($stdout)
    end

    # Log a message at the given level with an optional tag prefix.
    #
    # @param level [Symbol] Log level (:debug, :info, :warn, :error)
    # @param msg [String] Message to log
    # @param tag [String, nil] Optional prefix (e.g. "JetstreamBridge::Consumer")
    # @return [void]
    def log(level, msg, tag: nil)
      message = tag ? "[#{tag}] #{msg}" : msg
      logger.public_send(level, message)
    end

    # @param msg [String] Message to log
    # @param tag [String, nil] Optional prefix
    # @return [void]
    def debug(msg, tag: nil)
      log(:debug, msg, tag: tag)
    end

    # @param msg [String] Message to log
    # @param tag [String, nil] Optional prefix
    # @return [void]
    def info(msg, tag: nil)
      log(:info, msg, tag: tag)
    end

    # @param msg [String] Message to log
    # @param tag [String, nil] Optional prefix
    # @return [void]
    def warn(msg, tag: nil)
      log(:warn, msg, tag: tag)
    end

    # @param msg [String] Message to log
    # @param tag [String, nil] Optional prefix
    # @return [void]
    def error(msg, tag: nil)
      log(:error, msg, tag: tag)
    end

    def sanitize_url(url)
      uri = URI.parse(url)
      return url unless uri.user || uri.password

      userinfo =
        if uri.password # user:pass → keep user, mask pass
          "#{uri.user}:***"
        else            # token-only userinfo → mask entirely
          '***'
        end

      host = uri.host || ''
      port = uri.port ? ":#{uri.port}" : ''
      path = uri.path.to_s # omit query on purpose to avoid leaking tokens
      frag = uri.fragment ? "##{uri.fragment}" : ''

      "#{uri.scheme}://#{userinfo}@#{host}#{port}#{path}#{frag}"
    rescue URI::InvalidURIError
      # Fallback: redact any userinfo before the '@'
      url.gsub(%r{(nats|tls)://([^@/]+)@}i) do
        scheme = Regexp.last_match(1)
        creds  = Regexp.last_match(2)
        masked = creds&.include?(':') ? "#{creds&.split(':', 2)&.first}:***" : '***'
        "#{scheme}://#{masked}@"
      end
    end
  end
end
