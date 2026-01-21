# frozen_string_literal: true

require 'uri'
require_relative 'logging'

module JetstreamBridge
  # Validates NATS server URLs
  #
  # Responsible for:
  # - URL format validation
  # - Scheme validation (nats, nats+tls)
  # - Host/port validation
  class ConnectionValidator
    VALID_NATS_SCHEMES = %w[nats nats+tls].freeze

    # Validates and returns array of server URLs
    #
    # @param urls [String] Comma-separated NATS URLs
    # @return [Array<String>] Validated server URLs
    # @raise [ConnectionError] If validation fails
    def validate_servers!(urls)
      servers = parse_urls(urls)
      validate_not_empty!(servers)

      servers.each { |url| validate_url!(url) }

      Logging.info(
        'All NATS URLs validated successfully',
        tag: 'JetstreamBridge::ConnectionValidator'
      )

      servers
    end

    private

    def parse_urls(urls)
      urls.to_s
          .split(',')
          .map(&:strip)
          .reject(&:empty?)
    end

    def validate_not_empty!(servers)
      return unless servers.empty?

      raise ConnectionError, 'No NATS URLs configured'
    end

    def validate_url!(url)
      validate_format!(url)

      uri = URI.parse(url)
      validate_scheme!(uri, url)
      validate_host!(uri, url)
      validate_port!(uri, url)

      Logging.debug(
        "URL validated: #{Logging.sanitize_url(url)}",
        tag: 'JetstreamBridge::ConnectionValidator'
      )
    rescue URI::InvalidURIError => e
      Logging.error(
        "Malformed URL: #{url} (#{e.message})",
        tag: 'JetstreamBridge::ConnectionValidator'
      )
      raise ConnectionError, "Invalid NATS URL format: #{url} (#{e.message})"
    end

    def validate_format!(url)
      return if url.include?('://')

      Logging.error(
        "Invalid URL format (missing scheme): #{url}",
        tag: 'JetstreamBridge::ConnectionValidator'
      )
      raise ConnectionError, "Invalid NATS URL format: #{url}. Expected format: nats://host:port"
    end

    def validate_scheme!(uri, url)
      scheme = uri.scheme&.downcase
      return if VALID_NATS_SCHEMES.include?(scheme)

      Logging.error(
        "Invalid URL scheme '#{uri.scheme}': #{Logging.sanitize_url(url)}",
        tag: 'JetstreamBridge::ConnectionValidator'
      )
      raise ConnectionError, "Invalid NATS URL scheme '#{uri.scheme}' in: #{url}. Expected 'nats' or 'nats+tls'"
    end

    def validate_host!(uri, url)
      return unless uri.host.nil? || uri.host.empty?

      Logging.error(
        "Missing host in URL: #{Logging.sanitize_url(url)}",
        tag: 'JetstreamBridge::ConnectionValidator'
      )
      raise ConnectionError, "Invalid NATS URL - missing host: #{url}"
    end

    def validate_port!(uri, url)
      return unless uri.port && (uri.port < 1 || uri.port > 65_535)

      Logging.error(
        "Invalid port #{uri.port} in URL: #{Logging.sanitize_url(url)}",
        tag: 'JetstreamBridge::ConnectionValidator'
      )
      raise ConnectionError, "Invalid NATS URL - port must be 1-65535: #{url}"
    end
  end
end
