# frozen_string_literal: true

# JetstreamBridge
#
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
  end
end
