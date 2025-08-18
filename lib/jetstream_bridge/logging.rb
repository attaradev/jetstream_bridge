# frozen_string_literal: true

require 'uri'

module JetstreamBridge
  # Logging helpers that route to Rails.logger when available,
  # falling back to STDOUT.
  module Logging
    module_function

    def log(level, msg, tag: nil)
      message = tag ? "[#{tag}] #{msg}" : msg
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.public_send(level, message)
      else
        puts "[#{level.to_s.upcase}] #{message}"
      end
    end

    def info(msg, tag: nil)
      log(:info, msg, tag: tag)
    end

    def warn(msg, tag: nil)
      log(:warn, msg, tag: tag)
    end

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
